import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_core/shared_core.dart';

import 'app_state.dart';
import 'db.dart';

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

  Future<List<MixtapeSource>> sources() async {
    final out = <MixtapeSource>[];
    for (var i = 0; i < state.mixer.mix.length; i++) {
      final s = state.mixer.mix[i];
      final segs = await db.segmentsOf(s.path);
      TrackTags? tags;
      try {
        tags = await readTags(s.path);
      } catch (_) {}
      var art = tags?.picture;
      if (art == null || art.isEmpty) {
        final f = await EnrichService.localArt(s.path, album: s.album);
        if (f != null) art = await f.readAsBytes();
      }
      var lyrics = s.hasLyrics ? s.lyrics : null;
      if (lyrics == null) {
        final dot = s.path.lastIndexOf('.');
        for (final f in [
          EnrichService.lyricsFile(s.path),
          if (dot > 0) File('${s.path.substring(0, dot)}.lrc')
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
      if (plan != null && part!.execution.trim().isNotEmpty) plan['notes'] = _clip(part.execution.trim(), 900);
      out.add(MixtapeSource(
        path: s.path,
        title: s.title,
        artist: s.artist,
        album: s.album,
        year: s.year,
        genre: s.genre,
        trackNo: s.trackNo,
        trackTotal: s.trackTotal,
        discNo: s.discNo,
        discTotal: s.discTotal,
        duration: s.duration,
        start: s.trimStart,
        end: s.trimEnd,
        loudness: s.loudness,
        note: switch (state.mixer.songNotes[s.path]) { final n? => _clip(n, 900), null => null },
        rating: s.rating,
        fav: s.fav,
        explicit: s.isExplicit,
        tags: s.userTags,
        lyrics: lyrics,
        art: art,
        step: step,
        plan: plan,
        damaged: s.damaged
            ? _clip(state.mixer.damagedReasons[s.path] ?? 'damaged audio')
            : null,
        bpm: s.avgBpm == null && segs.isEmpty
            ? null
            : {
                'avg': s.avgBpm,
                'median': s.medianBpm,
                'min': s.minBpm,
                'max': s.maxBpm,
                'stddev': s.bpmStddev,
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
