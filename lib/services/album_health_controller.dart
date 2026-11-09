import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_core/shared_core.dart';

import 'album_health.dart';
import 'db.dart';
import 'discography.dart';

/// Album health checks (damaged, duplicate or missing tracks) and the
/// per-song lookup behind the album badges.
class AlbumHealthController extends ChangeNotifier {
  AlbumHealthController(this.db,
      {required this.libraryVersion, required this.isScanning, required this.discography});

  final MusicDb db;

  /// The library's current version; [ensureHealth] re-checks when it changes.
  final int Function() libraryVersion;

  /// [ensureHealth] waits while a scan is changing the library.
  final bool Function() isScanning;

  /// Deezer discography, for the online track counts.
  final Future<Discography> Function() discography;

  List<AlbumHealth> albumHealth = [];
  final Map<String, AlbumHealth> _healthByPath = {};
  bool healthRunning = false;
  bool healthCancelled = false;

  /// (done, total) while a check runs.
  (int, int)? healthProgress;
  int _healthVersion = -1;
  final Map<String, (int, int, Mp3Probe?)> _probeCache = {};
  final Map<String, int?> _onlineCounts = {};

  /// The health report of the album holding [path]; null if it looks fine or
  /// hasn't been checked yet.
  AlbumHealth? healthFor(String path) => _healthByPath[path];

  /// Runs the offline check once per library change (used for album badges).
  Future<void> ensureHealth() async {
    if (healthRunning || isScanning() || _healthVersion == libraryVersion()) return;
    await checkHealth();
  }

  /// Checks every album. [online] also asks Deezer how many tracks each album
  /// has (slow: one polite request per album, cached for a month).
  Future<void> checkHealth({bool online = false}) async {
    if (healthRunning) return;
    healthRunning = true;
    healthCancelled = false;
    healthProgress = null;
    notifyListeners();
    try {
      final version = libraryVersion();
      final songs = await db.allSongs();
      final mp3s = [for (final s in songs) if (isMp3Path(s.path)) s];
      final probes = <String, Mp3Probe?>{};
      final todo = <Song>[];
      for (final s in mp3s) {
        final c = _probeCache[s.path];
        if (c != null && c.$1 == s.size && c.$2 == s.mtime) {
          probes[s.path] = c.$3;
        } else {
          todo.add(s);
        }
      }
      var done = 0;
      final total = todo.length;
      for (var i = 0; i < todo.length && !healthCancelled; i += 16) {
        final batch = todo.sublist(i, min(i + 16, todo.length));
        final res = await Future.wait([for (final s in batch) probeMp3File(s.path, s.size)]);
        for (var j = 0; j < batch.length; j++) {
          final s = batch[j];
          // a file that can't be read is the Missing tab's business, not corruption
          if (res[j] == null && !await File(s.path).exists()) continue;
          _probeCache[s.path] = (s.size, s.mtime, res[j]);
          probes[s.path] = res[j];
        }
        done += batch.length;
        healthProgress = (done, total);
        notifyListeners();
      }

      if (online && !healthCancelled) {
        final disco = await discography();
        final groups = groupAlbums(songs);
        var n = 0, failures = 0;
        for (final e in groups.entries) {
          if (healthCancelled || failures >= 3) break;
          healthProgress = (n++, groups.length);
          final artist = _singleArtist(e.value);
          if (artist == null || _onlineCounts.containsKey(e.key)) continue;
          try {
            _onlineCounts[e.key] = await disco.trackCount(artist, e.value.first.album!);
            failures = 0;
          } catch (_) {
            failures++;
          }
          if (n % 5 == 0) notifyListeners();
        }
      }

      albumHealth = checkAlbums(songs, probes: probes, onlineTracks: _onlineCounts);
      _healthByPath
        ..clear()
        ..addEntries([
          for (final a in albumHealth)
            for (final s in a.songs) MapEntry(s.path, a)
        ]);
      _healthVersion = version;
    } finally {
      healthRunning = false;
      healthProgress = null;
      notifyListeners();
    }
  }

  void cancelHealth() => healthCancelled = true;

  /// The album's artist when all (named) tracks share one; null otherwise.
  static String? _singleArtist(List<Song> songs) {
    final names = {
      for (final s in songs)
        if ((s.artist ?? '').trim().isNotEmpty) s.artist!.trim()
    };
    return names.length == 1 ? names.first : null;
  }
}
