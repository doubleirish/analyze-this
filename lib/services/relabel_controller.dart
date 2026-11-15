import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_core/shared_core.dart' show writeMp3Tags;

import 'album_health.dart' show albumArtist, groupAlbums;
import 'db.dart';
import 'musicbrainz.dart';
import 'relabel.dart';

typedef TagWriter = Future<bool> Function(String path, {String? title, String? artist, String? album});

class RelabelResult {
  const RelabelResult({this.songs = 0, this.filesWritten = 0, this.dbOnly = 0, this.errors = const []});
  final int songs;
  final int filesWritten;

  /// Songs changed in the library only (not an MP3, or its tag can't be edited safely).
  final int dbOnly;
  final List<String> errors;
}

/// Finds mislabelled albums by comparing them with MusicBrainz releases, and
/// applies reviewed fixes to the library and (for MP3s) the file tags.
class RelabelController extends ChangeNotifier {
  RelabelController(this.db, this.mb, {TagWriter? writer}) : _writer = writer ?? writeMp3Tags;

  final MusicDb db;
  final MusicBrainz mb;
  final TagWriter _writer;

  /// Releases fetched in full per album, best text matches first.
  static const candidatesPerAlbum = 3;

  List<RelabelSuggestion> suggestions = [];
  bool running = false;
  bool cancelled = false;
  (int, int)? progress;

  /// Albums already matching their release.
  int upToDate = 0;

  /// Albums with no usable match, by group key; the user can search them by hand.
  final Map<String, List<Song>> unmatchedAlbums = {};
  String? error;

  void cancel() {
    cancelled = true;
    notifyListeners();
  }

  /// Checks the albums in [songs] (one at a time: MusicBrainz allows ~1 request/s),
  /// only those whose album or artist contains [filter] when it is given.
  Future<void> scan(List<Song> songs, {String filter = ''}) async {
    if (running) return;
    final f = filter.trim().toLowerCase();
    final albums = [
      for (final e in groupAlbums(songs).entries)
        if (f.isEmpty ||
            (e.value.first.album ?? '').toLowerCase().contains(f) ||
            albumArtist(e.value).toLowerCase().contains(f))
          e
    ];
    running = true;
    cancelled = false;
    error = null;
    suggestions = [];
    upToDate = 0;
    unmatchedAlbums.clear();
    progress = (0, albums.length);
    notifyListeners();
    try {
      for (var i = 0; i < albums.length && !cancelled; i++) {
        final e = albums[i];
        final s = await suggestFor(e.key, e.value);
        if (s != null) suggestions = [...suggestions, s];
        progress = (i + 1, albums.length);
        notifyListeners();
      }
    } catch (e) {
      error = '$e';
    } finally {
      running = false;
      notifyListeners();
    }
  }

  /// Searches again for an album with a corrected [artist]/[album] query, for
  /// when the library's own tags are the wrong part.
  Future<void> research(String key, List<Song> songs, {required String artist, required String album}) async {
    if (running) return;
    running = true;
    error = null;
    notifyListeners();
    try {
      final s = await suggestFor(key, songs, artist: artist, album: album);
      if (s != null) suggestions = [...suggestions.where((x) => x.key != key), s];
    } catch (e) {
      error = '$e';
    } finally {
      running = false;
      notifyListeners();
    }
  }

  /// Looks up one album. Returns null (and files the album under
  /// [unmatchedAlbums], or counts it as up to date) when there is nothing to suggest.
  Future<RelabelSuggestion?> suggestFor(String key, List<Song> songs, {String? artist, String? album}) async {
    final qArtist = artist ?? albumArtist(songs);
    final qAlbum = album ?? (songs.first.album ?? '');
    var found = await _best(key, songs, qArtist, qAlbum);
    if (found.suggestion == null && !found.matched && qArtist.isNotEmpty && artist == null) {
      // the artist tag may be the wrong part: retry on the album title alone
      found = await _best(key, songs, '', qAlbum);
    }
    if (found.suggestion != null) {
      unmatchedAlbums.remove(key);
      return found.suggestion;
    }
    if (found.matched) {
      unmatchedAlbums.remove(key);
      upToDate++;
    } else {
      unmatchedAlbums[key] = songs;
    }
    return null;
  }

  Future<({RelabelSuggestion? suggestion, bool matched})> _best(
      String key, List<Song> songs, String artist, String album) async {
    final cands = (await mb.searchReleases(artist: artist, album: album)).take(candidatesPerAlbum);
    RelabelSuggestion? best;
    var matchedExactly = false;
    for (final c in cands) {
      final full = await mb.release(c.id);
      if (full == null) continue;
      final s = planRelabel(key, songs, full, searchScore: c.score);
      if (s == null) continue;
      if (s.changes.isEmpty) {
        // a good fit with nothing to change means the album is already right
        matchedExactly = true;
        continue;
      }
      if (best == null || s.confidence > best.confidence) best = s;
    }
    return (suggestion: best, matched: matchedExactly);
  }

  /// Applies [changes]: file tags first (MP3s, when [writeFiles]), then the
  /// library with overrides that survive rescans. Every change is logged as one
  /// batch for [undoLast].
  Future<RelabelResult> apply(Iterable<TrackChange> changes, {bool writeFiles = true}) async {
    final byPath = <String, List<TrackChange>>{};
    for (final c in changes) {
      byPath.putIfAbsent(c.path, () => []).add(c);
    }
    if (byPath.isEmpty) return const RelabelResult();
    final batch = await db.nextRelabelBatch();
    var written = 0, dbOnly = 0;
    final errors = <String>[];
    for (final e in byPath.entries) {
      final path = e.key;
      String? v(String f) => e.value.where((c) => c.field == f).map((c) => c.to).firstOrNull;
      var fileDone = false;
      if (writeFiles) {
        try {
          fileDone = await _writer(path, title: v('title'), artist: v('artist'), album: v('album'));
        } on FileSystemException catch (ex) {
          errors.add('${_name(path)}: ${ex.message}');
        } catch (ex) {
          errors.add('${_name(path)}: $ex');
        }
      }
      fileDone ? written++ : dbOnly++;
      await db.setOverrides([path], title: v('title'), artist: v('artist'), album: v('album'));
      for (final c in e.value) {
        await db.logRelabel(batch, path, c.field, c.from, c.to, fileWritten: fileDone);
      }
    }
    final applied = byPath.keys.toSet();
    suggestions = [
      for (final s in suggestions)
        if (!s.changes.every((c) => applied.contains(c.path))) s
    ];
    notifyListeners();
    return RelabelResult(songs: byPath.length, filesWritten: written, dbOnly: dbOnly, errors: errors);
  }

  /// Number of songs in the most recent batch, 0 when there is nothing to undo.
  Future<int> undoableCount() async {
    final b = await db.lastRelabelBatch();
    if (b == null) return 0;
    return {for (final r in await db.relabelBatch(b)) r['path']}.length;
  }

  /// Puts back the previous values of the last batch, in files too where they were written.
  Future<RelabelResult> undoLast() async {
    final b = await db.lastRelabelBatch();
    if (b == null) return const RelabelResult();
    final byPath = <String, List<Map<String, Object?>>>{};
    for (final r in await db.relabelBatch(b)) {
      byPath.putIfAbsent(r['path'] as String, () => []).add(r);
    }
    var written = 0, dbOnly = 0;
    final errors = <String>[];
    for (final e in byPath.entries) {
      String? old(String f) =>
          e.value.where((r) => r['field'] == f).map((r) => r['old_value'] as String?).firstOrNull;
      final inFile = e.value.any((r) => r['file_written'] == 1);
      var fileDone = false;
      if (inFile) {
        try {
          fileDone = await _writer(e.key, title: old('title'), artist: old('artist'), album: old('album'));
        } catch (ex) {
          errors.add('${_name(e.key)}: $ex');
        }
      }
      fileDone ? written++ : dbOnly++;
      await db.setOverrides([e.key], title: old('title'), artist: old('artist'), album: old('album'));
    }
    await db.deleteRelabelBatch(b);
    notifyListeners();
    return RelabelResult(songs: byPath.length, filesWritten: written, dbOnly: dbOnly, errors: errors);
  }

  static String _name(String path) => path.split(RegExp(r'[\\/]')).last;
}
