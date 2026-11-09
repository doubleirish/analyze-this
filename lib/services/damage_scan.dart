import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_core/shared_core.dart';

import 'db.dart';

/// Library-wide damaged-audio scans (quick structure check or a full ffmpeg
/// decode) and the list of songs tagged [corruptTag].
class DamageScanController extends ChangeNotifier {
  DamageScanController(this.db, {required this.findFfmpeg, required this.onChanged});

  final MusicDb db;

  /// ffmpeg for the deep scan, or null when it isn't installed.
  final Future<String?> Function() findFfmpeg;

  /// Called after the damaged set may have changed (refreshes lists and the mix).
  final Future<void> Function() onChanged;

  List<(Song, SongHealth?)> damaged = [];
  bool running = false;
  bool _cancelled = false;

  /// (done, total) while a scan runs.
  (int, int)? progress;

  /// Summary of the last scan, e.g. "Checked 1,204 songs: 3 damaged".
  String? lastResult;

  Future<void> load() async {
    damaged = await db.damagedSongs();
    notifyListeners();
  }

  void cancel() => _cancelled = true;

  /// Checks every library song. [deep] decodes each file with ffmpeg (slow;
  /// throws [StateError] if ffmpeg can't be found). Files already checked at
  /// this depth and unchanged since are skipped unless [recheck].
  Future<void> scan({bool deep = false, bool recheck = false}) async {
    if (running) return;
    final ffmpeg = deep ? await findFfmpeg() : null;
    if (deep && ffmpeg == null) {
      throw StateError('ffmpeg was not found. Set its path in Send to phone, or install it.');
    }
    running = true;
    _cancelled = false;
    progress = null;
    lastResult = null;
    notifyListeners();
    final depth = deep ? 'deep' : 'quick';
    var checked = 0, found = 0, unreadable = 0;
    try {
      final songs = await db.allSongs();
      final seen = recheck ? const <String, (int?, int?)>{} : await db.healthChecked(depth: depth);
      final todo = [
        for (final s in songs)
          if (seen[s.path] != (s.size, s.mtime)) s
      ];
      progress = (0, todo.length);
      notifyListeners();
      var next = 0, done = 0;
      Future<void> worker() async {
        while (!_cancelled && next < todo.length) {
          final s = todo[next++];
          try {
            final st = await File(s.path).stat();
            if (st.type == FileSystemEntityType.notFound) {
              unreadable++;
            } else {
              final r = deep ? await deepCheckFile(s.path, ffmpeg!) : await quickCheckFile(s.path);
              if (await db.recordHealth(s.path,
                  damaged: r.damaged,
                  reason: r.reason,
                  depth: depth,
                  size: st.size,
                  mtime: st.modified.millisecondsSinceEpoch)) {
                if (r.damaged) found++;
              }
              checked++;
            }
          } on FileSystemException {
            unreadable++;
          } on ProcessException {
            unreadable++;
          }
          done++;
          progress = (done, todo.length);
          if (done % 10 == 0 || done == todo.length) notifyListeners();
        }
      }

      final workers = deep ? max(1, min(6, Platform.numberOfProcessors ~/ 2)) : 4;
      await Future.wait([for (var i = 0; i < workers; i++) worker()]);
      final skipped = songs.length - todo.length;
      lastResult = [
        '${_cancelled ? 'Stopped after' : 'Checked'} $checked song${checked == 1 ? '' : 's'}'
            '${deep ? ' (deep)' : ''}: $found damaged',
        if (skipped > 0) '$skipped unchanged skipped',
        if (unreadable > 0) '$unreadable missing or unreadable',
      ].join(' · ');
    } finally {
      running = false;
      progress = null;
      damaged = await db.damagedSongs();
      notifyListeners();
      await onChanged();
    }
  }

  /// The user says [path] plays fine: untag it and don't flag it again
  /// unless the file changes.
  Future<void> markOk(String path) async {
    await db.removeTag(path, corruptTag);
    await load();
    await onChanged();
  }
}
