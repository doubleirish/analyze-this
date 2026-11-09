// Headless builder behind tools\build-top-mixes.ps1: one 60-minute mixtape for
// each of the most common genres and artists in the library, every one in a
// different class style, written as .beatsmix files. Runs through `flutter test`;
// does nothing unless TOPMIX_OUT is set.
import 'dart:io';
import 'dart:math';

import 'package:analyze_this/services/app_state.dart';
import 'package:analyze_this/services/db.dart';
import 'package:analyze_this/services/mixtape_export.dart';
import 'package:analyze_this/services/planner.dart';
import 'package:analyze_this/services/program_generator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_core/shared_core.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

String _safe(String n) => n.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_').trim();

/// Stable id per mix name so a rebuilt mix updates in place on the phone.
String _idFor(String name) {
  var h = 0xcbf29ce484222325;
  for (final c in name.codeUnits) {
    h = ((h ^ c) * 0x100000001b3) & 0x7fffffffffffffff;
  }
  return h.toRadixString(16).padLeft(16, '0');
}

void main() {
  final env = Platform.environment;
  final outDir = env['TOPMIX_OUT'];
  final count = int.tryParse(env['TOPMIX_COUNT'] ?? '') ?? 10;
  const skipGenres = {'Unknown', 'Audiobook', 'Podcast', 'Spoken Word', 'Comedy', 'Soundtrack'};

  test('build top genre and artist mixes', () async {
    final out = Directory(outDir!)..createSync(recursive: true);
    final dbFile = env['TOPMIX_DB'] ??
        p.join(env['APPDATA']!, 'com.example', 'analyze_this', 'analyze_this.db');
    final snap = p.join(Directory.systemTemp.path, 'top_mixes_snapshot.db');
    File(dbFile).copySync(snap);

    sqfliteFfiInit();
    final raw = await databaseFactoryFfi.openDatabase(snap, options: OpenDatabaseOptions(readOnly: true));
    final genres = [
      for (final r in await raw.rawQuery(
          'SELECT genre g FROM songs WHERE median_bpm IS NOT NULL AND genre IS NOT NULL '
          "AND genre != '' GROUP BY genre ORDER BY COUNT(*) DESC LIMIT 40"))
        r['g'] as String
    ].where((g) => !skipGenres.contains(g)).toList();
    final artists = [
      for (final r in await raw.rawQuery(
          'SELECT artist a FROM songs WHERE median_bpm IS NOT NULL AND artist IS NOT NULL '
          "AND artist != '' AND artist NOT LIKE '(%' AND lower(artist) NOT LIKE 'various%' "
          'GROUP BY artist ORDER BY COUNT(*) DESC LIMIT 40'))
        r['a'] as String
    ];
    await raw.close();

    final db = await MusicDb.open(snap);
    final st = AppState(db, random: Random(7));
    final mx = st.mixer;
    final cache = Directory(p.join(Directory.systemTemp.path, 'top_mixes_cache'));
    final ff = await MixtapeExport(st).detectFfmpeg();
    final writer = PackageWriter(ffmpegPath: ff ?? 'ffmpeg');
    final styles = ClassStyle.values;
    var built = 0, failed = 0;    final usage = <ClassStyle, int>{for (final s in ClassStyle.values) s: 0};

    // Different class styles for different mixes: the least-used style that
    // fills this filter completely, has at least 3 kinds of activity and
    // never puts similar ones together.
    Future<void> run(String kind, List<String> candidates) async {
      for (final c in candidates.take(count)) {
        final order = [...styles]..sort((a, b) => usage[a]!.compareTo(usage[b]!));
        var ok = false;
        for (final s in order) {
          for (var seed = 0; seed < 3 && !ok; seed++) {
            final prog = generateProgram(minutes: 60, style: s, random: Random(c.hashCode + seed));
            final acts = [for (final x in prog.parts) if (isActivity(x)) x];
            final families = {for (final x in acts) activityFamily(x.kind)};
            if (hasRepeatedNeighbour(acts) || families.length < 3) continue;
            mx.clearMix();
            await mx.setMixFilter(kind == 'genre' ? MixFilter(genre: c) : MixFilter(artist: c));
            final unfilled = await mx.fillProgram(prog);
            final secs = mx.mix.fold<double>(0, (a, x) => a + (x.duration ?? 240));
            if (unfilled > 0 || secs < 52 * 60 || mx.mix.length < 8) continue;
            final label = '$c · ${s.label} · 60 min';
            try {
              mx.mixNameAuto = false;
              mx.mixName = label;
              mx.mixKey = _idFor(label);
              final src = await MixtapeExport(st).sources();
              final dest = File(p.join(out.path, '${_safe(label)}.beatsmix'));
              await ZipTransport.export(writer,
                  id: mx.mixKey,
                  name: label,
                  sources: src,
                  zipFile: dest,
                  cache: cache,
                  programName: mx.program.name,
                  sourceName: Platform.localHostname);
              ok = true;
              built++;
              usage[s] = usage[s]! + 1;
              stdout.writeln('OK     $label: ${src.length} songs, ${(secs / 60).round()} min, '
                  '${acts.length} activities, ${families.length} kinds -> ${dest.path}');
            } catch (e) {
              failed++;
              stdout.writeln('FAILED $label: $e');
              ok = true;
            }
          }
          if (ok) break;
        }
        if (!ok) stdout.writeln('SKIP   $c: no style fills it');
      }
    }

    try {
      await run('genre', genres);
      await run('artist', artists);
    } finally {
      await Future<void>.delayed(const Duration(seconds: 2));
      await db.close();
      try {
        await cache.delete(recursive: true);
        File(snap).deleteSync();
      } catch (_) {}
    }
    stdout.writeln('Built $built, failed $failed.');
    expect(failed, 0);
  }, skip: outDir == null ? 'set TOPMIX_OUT (use tools\\build-top-mixes.ps1)' : false,
      timeout: Timeout.none);
}
