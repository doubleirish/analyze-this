import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_core/shared_core.dart';

import 'app_state.dart';
import 'db.dart';

/// One mix entry and the physical file chosen for phone export.
class MixtapeSelection {
  const MixtapeSelection(this.original, this.file);
  final Song original;
  final Song file;

  bool get substituted => original.path != file.path;
  bool get healthyNative => !file.damaged && androidPlayable(file.path) && File(file.path).existsSync();
}

/// Builds mixtape package sources from the analyze-this database and files.
class MixtapeExport {
  MixtapeExport(this.state);
  final AppState state;

  MusicDb get db => state.db;

  /// Working area for packages so unchanged songs aren't recopied.
  static Future<Directory> cacheDir() async => Directory(
      p.join((await getApplicationSupportDirectory()).path, 'mixtape_out'));

  /// ffmpeg from the saved setting, PATH, or a `tools/ffmpeg*/bin` folder
  /// near the app or working directory.
  Future<String?> detectFfmpeg() async {
    final saved = await db.setting('ffmpeg_path');
    final extra = <String>[?saved];
    var dir = Directory.current;
    for (var i = 0; i < 6; i++) {
      final tools = Directory(p.join(dir.path, 'tools'));
      if (tools.existsSync()) {
        for (final e in tools.listSync()) {
          final exe = File(p.join(e.path, 'bin', Platform.isWindows ? 'ffmpeg.exe' : 'ffmpeg'));
          if (exe.existsSync()) extra.add(exe.path);
        }
      }
      if (dir.parent.path == dir.path) break;
      dir = dir.parent;
    }
    return PackageWriter.findFfmpeg(extra);
  }

  /// Records each packaged copy's sha256 → library path so phone plays and
  /// ratings can be matched back (see `PathResolver`).
  static Future<void> recordSent(MusicDb db, MixtapeManifest m) => db.recordSentTracks([
        for (final t in m.tracks)
          if (t.origPath case final p?) (sha256: t.sha256, path: p)
      ]);

  /// Selects files without changing the mix, its ordering or its saved entries.
  /// Preflight uses the same selection as [sources].
  Future<List<MixtapeSelection>> selections() async {
    final originals = List<Song>.of(state.mixer.mix);
    final keys = originals.map((s) => s.dupKey ?? '').where((k) => k.isNotEmpty).toSet();
    final found = await db.songsByDupKey(keys);
    final paths = <String>[];
    for (final path in found.values.expand((v) => v).map((s) => s.path).toSet()) {
      if (!androidPlayable(path) || !await File(path).exists()) continue;
      paths.add(path);
    }
    final candidates = (await db.songsAt(paths)).values.where((s) => !s.damaged).toList();
    return [for (final original in originals) MixtapeSelection(original, _selectFile(original, candidates))];
  }

  static Song _selectFile(Song original, List<Song> candidates) {
    if (original.dupKey == null || original.dupKey!.isEmpty) return original;
    final groups = groupDuplicates([
      original,
      for (final candidate in candidates)
        if (candidate.path != original.path &&
            candidate.isExplicit == original.isExplicit &&
            _safeTimeline(original, candidate)) candidate,
    ], forAndroid: true);
    final copies = groups.firstWhere((g) => g.songs.any((s) => identical(s, original)));
    final usable = copies.songs
        .where((s) => !s.damaged && androidPlayable(s.path) && File(s.path).existsSync())
        .toList()
      ..sort((a, b) => compareSongQuality(a, b, forAndroid: true));
    if (usable.isEmpty) return original;
    if (usable.any((s) => identical(s, original)) &&
        compareSongQuality(usable.first, original, forAndroid: true) >= 0) {
      return original;
    }
    return usable.first;
  }

  static bool _safeTimeline(Song original, Song candidate) {
    final a = original.duration, b = candidate.duration;
    if (a == null || b == null || !a.isFinite || !b.isFinite || a <= 0 || b <= 0 || (a - b).abs() > 2) {
      return false;
    }
    final start = original.trimStart ?? 0;
    final end = original.trimEnd ?? (a < b ? a : b);
    return start.isFinite && end.isFinite && start >= 0 && start < end && end <= a && end <= b;
  }

  Future<List<MixtapeSource>> sources() async {
    final selected = await selections();
    final out = <MixtapeSource>[];
    for (var i = 0; i < selected.length; i++) {
      final s = selected[i].original;
      final file = selected[i].file;
      final segs = await db.segmentsOf(file.path);
      TrackTags? tags;
      try {
        tags = await readTags(file.path);
      } catch (_) {}
      var art = tags?.picture;
      if (art == null || art.isEmpty) {
        final f = await EnrichService.localArt(file.path, album: file.album);
        if (f != null) art = await f.readAsBytes();
      }
      var lyrics = s.hasLyrics ? s.lyrics : null;
      if (lyrics == null) {
        final dot = file.path.lastIndexOf('.');
        for (final f in [
          EnrichService.lyricsFile(file.path),
          if (dot > 0) File('${file.path.substring(0, dot)}.lrc')
        ]) {
          if (await f.exists()) {
            lyrics = await f.readAsString();
            break;
          }
        }
      }
      lyrics ??= tags?.lyrics;
      final part = state.mixer.partAt(i);
      final step = part?.name;
      final plan = part == null ? null : state.mixer.planAt(i)!.toJson();
      final partNotes = [
        if (part != null && part.execution.trim().isNotEmpty) part.execution.trim(),
        if (part != null && part.trainerNote.trim().isNotEmpty) '💬 ${part.trainerNote.trim()}',
      ].join('\n');
      if (plan != null && partNotes.isNotEmpty) plan['notes'] = _clip(partNotes, 900);
      out.add(MixtapeSource(
        path: file.path,
        libraryPath: s.path,
        title: s.title,
        artist: s.artist,
        album: s.album,
        year: s.year,
        genre: s.genre,
        trackNo: s.trackNo,
        trackTotal: s.trackTotal,
        discNo: s.discNo,
        discTotal: s.discTotal,
        duration: file.duration,
        start: s.trimStart,
        end: s.trimEnd,
        loudness: file.loudness,
        note: switch (state.mixer.songNotes[s.path]) { final n? => _clip(n, 900), null => null },
        rating: s.rating,
        fav: s.fav,
        explicit: s.isExplicit,
        tags: s.userTags,
        lyrics: lyrics,
        art: art,
        step: step,
        plan: plan,
        damaged: file.damaged
            ? _clip(state.mixer.damagedReasons[file.path] ?? 'damaged audio')
            : null,
        bpm: file.avgBpm == null && segs.isEmpty
            ? null
            : {
                'avg': file.avgBpm,
                'median': file.medianBpm,
                'min': file.minBpm,
                'max': file.maxBpm,
                'stddev': file.bpmStddev,
                'segments': [
                  for (final g in segs) {'start': g.start, 'end': g.end, 'bpm': g.bpm}
                ],
              },
      ));
    }
    return out;
  }
}

String _clip(String s, [int max = 200]) => s.length <= max ? s : '${s.substring(0, max - 3)}...';
