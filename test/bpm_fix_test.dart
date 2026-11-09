import 'dart:io';

import 'package:analyze_this/services/db.dart';
import 'package:analyze_this/services/scanner.dart';
import 'package:analyze_this/services/tap_tempo.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_core/shared_core.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tmp;
  late MusicDb db;
  late String mp3;
  const noNet = ScanOptions(analyzeBpm: false, fetchLyrics: false, lookupMusicBrainz: false);

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('bpm_fix_');
    db = await MusicDb.open(':memory:');
    mp3 = '${tmp.path}${Platform.pathSeparator}A - Slow.mp3';
    await File(mp3).writeAsBytes(List.filled(100, 1));
    await BpmStore.save(
        mp3,
        TempoResults(durationSec: 200, byAlgo: {
          baselineId: TempoMap(durationSec: 200, segments: const [
            TempoSegment(0, 100, 60),
            TempoSegment(100, 200, 70),
          ])
        }));
    await Scanner(db).processLocal(mp3, noNet);
  });

  tearDown(() async {
    await db.close();
    await tmp.delete(recursive: true);
  });

  Future<List<double>> segBpms() async => [for (final s in await db.segmentsOf(mp3)) s.bpm];

  test('scale fix updates stats, segments, overrides and sidecar; clear restores', () async {
    await db.setOverrides([mp3], genre: 'Rock');
    await db.setBpmFix(mp3, scale: 2);
    var s = (await db.song(mp3))!;
    expect(s.avgBpm, closeTo(130, 0.01));
    expect(s.minBpm, 120);
    expect(s.maxBpm, 140);
    expect(s.bpmStddev, closeTo(10, 0.01));
    expect(await segBpms(), [120, 140]);
    final ov = (await db.override(mp3))!;
    expect(ov['bpm_scale'], 2);
    expect(ov['genre'], 'Rock', reason: 'other overrides are kept');
    expect((await BpmStore.load(mp3))!.manual, const ManualBpm(scale: 2));

    await db.setBpmFix(mp3);
    s = (await db.song(mp3))!;
    expect(s.avgBpm, closeTo(65, 0.01));
    expect(await segBpms(), [60, 70]);
    expect(await db.bpmFix(mp3), isNull);
    expect((await BpmStore.load(mp3))!.manual, isNull);
  });

  test('constant bpm fix gives one segment', () async {
    await db.setBpmFix(mp3, bpm: 128);
    final s = (await db.song(mp3))!;
    expect(s.medianBpm, 128);
    expect(s.bpmStddev, 0);
    expect(await segBpms(), [128]);
  });

  test('rescan keeps the fix even if the sidecar lost it', () async {
    await db.setBpmFix(mp3, scale: 0.5);
    final r = (await BpmStore.load(mp3))!;
    await BpmStore.save(mp3, r.withManual(null)); // e.g. re-analysed elsewhere
    await Scanner(db).processLocal(mp3, noNet);
    expect((await db.song(mp3))!.medianBpm, 30);
    expect(await segBpms(), [30, 35]);
    expect((await BpmStore.load(mp3))!.manual, const ManualBpm(scale: 0.5));
  });

  test('fix without a sidecar works from the stored segments', () async {
    await BpmStore.sidecar(mp3).delete();
    await db.setBpmFix(mp3, scale: 2);
    expect(await segBpms(), [120, 140]);
    await db.setBpmFix(mp3, scale: 0.5);
    expect(await segBpms(), [30, 35]);
    await db.setBpmFix(mp3);
    expect(await segBpms(), [60, 70]);
  });

  test('migration from v10 adds the bpm fix columns', () async {
    final path = '${tmp.path}${Platform.pathSeparator}v10.db';
    sqfliteFfiInit();
    final fresh = await MusicDb.open(path);
    await fresh.close();
    final old = await databaseFactoryFfi.openDatabase(path);
    await old.execute('ALTER TABLE overrides DROP COLUMN bpm_scale');
    await old.execute('ALTER TABLE overrides DROP COLUMN bpm');
    await old.setVersion(10);
    await old.insert('overrides', {'path': 'x', 'artist': 'Kept'});
    await old.close();
    final up = await MusicDb.open(path);
    final ov = (await up.override('x'))!;
    expect(ov['artist'], 'Kept');
    expect(ov.containsKey('bpm_scale'), isTrue);
    expect(ov.containsKey('bpm'), isTrue);
    await up.close();
  });

  test('TapTempo averages the last 8 taps and resets after 2 s idle', () {
    final t = TapTempo();
    expect(t.tap(Duration.zero), isNull);
    expect(t.tap(const Duration(milliseconds: 500)), closeTo(120, 0.001));
    // 10 more taps at 100 bpm: only the last 8 (all 600 ms apart) count
    var at = const Duration(milliseconds: 500);
    double? bpm;
    for (var i = 0; i < 10; i++) {
      at += const Duration(milliseconds: 600);
      bpm = t.tap(at);
    }
    expect(t.count, 8);
    expect(bpm, closeTo(100, 0.001));
    expect(t.tap(at + const Duration(milliseconds: 2500)), isNull, reason: 'idle reset');
    expect(t.count, 1);
  });
}
