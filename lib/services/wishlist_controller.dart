import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_core/shared_core.dart' show PoliteHttp;

import 'db.dart';
import 'track_origin.dart';
import 'wishlist_match.dart';
import 'wishlist_parse.dart';

class WishlistController extends ChangeNotifier {
  WishlistController(this.db, this.net);
  final MusicDb db;
  final PoliteHttp net;
  String text = '';
  List<WishResult> results = [];
  List<Song> library = [];
  Map<String, SongHealth> health = {};
  final Map<int, OriginAlbum?> origins = {};
  final Map<int, String> lookupErrors = {};
  bool checking = false;
  bool lookingUp = false;
  int done = 0;
  int total = 0;
  String? error;
  bool _cancelled = false;
  bool _disposed = false;
  TrackOrigin? _origin;

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  void setText(String value) {
    if (text == value) return;
    text = value;
    _cancelled = true;
    results = [];
    origins.clear();
    lookupErrors.clear();
    error = null;
    _changed();
  }

  Future<void> check() async {
    if (checking || lookingUp) return;
    checking = true;
    error = null;
    _changed();
    final input = text;
    try {
      final songs = await db.allSongs();
      final matched = matchWishlist(parseWishlist(input), songs);
      final checks = await db.healthOf(
        matched.expand((r) => r.songs.map((s) => s.path)),
      );
      if (text != input || _disposed) return;
      library = songs;
      results = matched;
      health = checks;
      origins.clear();
      lookupErrors.clear();
    } catch (e) {
      error = 'Library check failed: $e';
    } finally {
      checking = false;
      _changed();
    }
  }

  void cancel() {
    _cancelled = true;
  }

  Future<void> findAlbums() async {
    if (checking || lookingUp) return;
    final targets = [
      for (var i = 0; i < results.length; i++)
        if (results[i].status == WishStatus.missing &&
            results[i].entry.artist != null &&
            (origins[i] == null || lookupErrors.containsKey(i)))
          i,
    ];
    if (targets.isEmpty) return;
    lookingUp = true;
    _cancelled = false;
    done = 0;
    total = targets.length;
    error = null;
    _changed();
    try {
      final dir = await getApplicationSupportDirectory();
      _origin ??= TrackOrigin(
        File('${dir.path}${Platform.pathSeparator}wishlist_origins.json'),
        net: net,
      );
      var failures = 0;
      for (final i in targets) {
        if (_cancelled || _disposed) break;
        try {
          final album = await _origin!.lookup(
            results[i].entry,
            cancelled: () => _cancelled || _disposed,
            retryMissing: origins.containsKey(i) && origins[i] == null,
          );
          if (_cancelled || _disposed) break;
          origins[i] = album;
          lookupErrors.remove(i);
          failures = 0;
        } catch (e) {
          if (_cancelled || _disposed) break;
          lookupErrors[i] = 'Lookup failed: $e';
          if (++failures >= 3) {
            error = 'Album lookup stopped after three errors. Retry when the service is available.';
            done++;
            _changed();
            break;
          }
        }
        done++;
        _changed();
      }
    } catch (e) {
      error = 'Album lookup failed: $e';
    } finally {
      lookingUp = false;
      _changed();
    }
  }

  String summary() => [
    for (var i = 0; i < results.length; i++)
      [
        '${results[i].entry.line} — ${statusLabel(results[i].status)}',
        for (final song in results[i].songs)
          '  ${song.path} — ${song.damaged ? 'damaged: ${health[song.path]?.reason ?? 'tagged damaged'}' : 'not marked damaged'}',
        if (origins[i] case final album?)
          '  Possible album: ${album.title}${album.date == null ? '' : ' (${album.date})'}'
              ' — ${results[i].entry.artist != null && album.inLibrary(results[i].entry.artist!, library) ? 'matching album in library' : 'no matching album in library'}',
        if (origins.containsKey(i) && origins[i] == null)
          '  No album found on Deezer',
        if (lookupErrors[i] != null) '  ${lookupErrors[i]}',
      ].join('\n'),
  ].join('\n');

  String csv() {
    String cell(Object? value) {
      var s = '${value ?? ''}';
      if (RegExp(r'^[\s]*[=+\-@]').hasMatch(s)) s = "'$s";
      return '"${s.replaceAll('"', '""')}"';
    }

    final rows = <List<Object?>>[
      [
        'Input',
        'Artist',
        'Title',
        'Status',
        'Copies',
        'Damage reasons',
        'Possible original album',
        'Release date',
        'Album in library',
        'Lookup error',
      ],
      for (var i = 0; i < results.length; i++)
        [
          results[i].entry.line,
          results[i].entry.artist,
          results[i].entry.title,
          statusLabel(results[i].status),
          results[i].songs
              .map((s) => '${s.path}${s.damaged ? ' (damaged)' : ''}')
              .join(' | '),
          results[i].songs
              .where((s) => s.damaged)
              .map(
                (s) =>
                    '${s.path}: ${health[s.path]?.reason ?? 'tagged damaged'}',
              )
              .join(' | '),
          origins[i]?.title,
          origins[i]?.date,
          if (origins[i] != null && results[i].entry.artist != null)
            origins[i]!.inLibrary(results[i].entry.artist!, library)
                ? 'Yes'
                : 'No matching album'
          else
            '',
          lookupErrors[i],
        ],
    ];
    return rows.map((row) => row.map(cell).join(',')).join('\r\n');
  }

  @override
  void dispose() {
    _cancelled = true;
    _disposed = true;
    super.dispose();
  }
}

String statusLabel(WishStatus status) => switch (status) {
  WishStatus.owned => 'Owned',
  WishStatus.damaged => 'Damaged',
  WishStatus.missing => 'Not found',
  WishStatus.ambiguous => 'Review match',
};
