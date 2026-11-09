// Headless exporter behind tools\export-saved-mixes.ps1: writes every saved
// mix of the analyze-this library as a .beatsmix file. Run through
// `flutter test` (see the script); it does nothing unless BEATSMIX_OUT is set.
import 'dart:io';

import 'package:analyze_this/services/app_state.dart';
import 'package:analyze_this/services/db.dart';
import 'package:analyze_this/services/mixtape_export.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_core/shared_core.dart';

String _safe(String n) => n.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_').trim();

RegExp _glob(String g) =>
    RegExp('^${g.split('*').map(RegExp.escape).join('.*')}\$', caseSensitive: false);

void main() {
  final env = Platform.environment;
  final outDir = env['BEATSMIX_OUT'];

  test('export saved mixes', () async {
    final out = Directory(outDir!)..createSync(recursive: true);
    final pattern = _glob(env['BEATSMIX_NAME'] ?? '*');
    final dbFile = env['BEATSMIX_DB'] ??
        p.join(env['APPDATA']!, 'com.example', 'analyze_this', 'analyze_this.db');
    // Work on a copy so the running app's database is never touched.
    final snap = p.join(Directory.systemTemp.path, 'export_saved_mixes_snapshot.db');
    File(dbFile).copySync(snap);
    final db = await MusicDb.open(snap);
    final st = AppState(db);
    final cache = Directory(p.join(Directory.systemTemp.path, 'beatsmix_export_cache'));
    final ff = await MixtapeExport(st).detectFfmpeg();
    final writer = PackageWriter(ffmpegPath: ff ?? 'ffmpeg');
    final log = <String>[];
    var done = 0, failed = 0;
    try {
      final mixes = (await db.mixes()).where((m) => pattern.hasMatch(m.name)).toList();
      stdout.writeln('Exporting ${mixes.length} saved mix(es) to ${out.path}');
      for (final m in mixes) {
        try {
          await st.mixer.loadMix(m);
          st.mixer.mixNameAuto = false;
          final src = await MixtapeExport(st).sources();
          if (src.isEmpty) {
            log.add('SKIP   ${m.name}: no songs found on this PC');
            continue;
          }
          final dest = File(p.join(out.path, '${_safe(m.name)}.beatsmix'));
          await ZipTransport.export(writer,
              id: st.mixer.mixKey,
              name: m.name,
              sources: src,
              zipFile: dest,
              cache: cache,
              programName: st.mixer.program.name,
              icon: await db.mixIcon(m.id),
              sourceName: Platform.localHostname);
          done++;
          log.add('OK     ${m.name} (${src.length} songs) -> ${dest.path}');
        } catch (e) {
          failed++;
          log.add('FAILED ${m.name}: $e');
        }
        stdout.writeln(log.last);
      }
    } finally {
      await Future<void>.delayed(const Duration(seconds: 2));
      await db.close();
      try {
        await cache.delete(recursive: true);
        File(snap).deleteSync();
      } catch (_) {}
    }
    stdout.writeln('Exported $done, failed $failed.');
    expect(failed, 0);
  }, skip: outDir == null ? 'set BEATSMIX_OUT (use tools\\export-saved-mixes.ps1)' : false,
      timeout: Timeout.none);
}
