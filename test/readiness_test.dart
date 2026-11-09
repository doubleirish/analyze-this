import 'package:analyze_this/services/db.dart';
import 'package:analyze_this/services/planner.dart';
import 'package:analyze_this/services/readiness.dart';
import 'package:flutter_test/flutter_test.dart';

Song _s(String path, double bpm, {double duration = 200, String? genre}) => Song(
    path: path, title: path, medianBpm: bpm, bpmStddev: 1, duration: duration, genre: genre);

void main() {
  late MusicDb db;
  setUp(() async => db = await MusicDb.open(':memory:'));
  tearDown(() => db.close());

  test('status thresholds: empty, thin below 3x needed fresh, ok at 3x', () {
    expect(readinessStatus(candidates: 0, fresh: 0, needed: 2), ReadinessStatus.empty);
    expect(readinessStatus(candidates: 10, fresh: 5, needed: 2), ReadinessStatus.thin);
    expect(readinessStatus(candidates: 10, fresh: 6, needed: 2), ReadinessStatus.ok);
    expect(songsNeeded(10, 200), 3);
    expect(songsNeeded(10, 0), 3); // fallback 240 s
  });

  test('counts candidates, needed from their average length, and fresh', () async {
    // 6 songs at 80 BPM (or 160 = double time), 2 at 120 (no match).
    for (var i = 0; i < 6; i++) {
      await db.upsertSong(_s('a$i', i.isEven ? 80 : 160, duration: 300));
    }
    await db.upsertSong(_s('x1', 120));
    await db.upsertSong(_s('x2', 120));
    await db.logClass(
        mixName: 'recent',
        paths: ['a0', 'a1', 'x1'],
        taughtAt: DateTime.now().subtract(const Duration(days: 7)));
    await db.logClass(
        mixName: 'old', paths: ['a2'], taughtAt: DateTime.now().subtract(const Duration(days: 90)));
    const program = Program('P', [
      ProgramPart('Seated flat', 10, 75, 85),
      ProgramPart('Stretch', 3, 55, 65, music: false),
      ProgramPart('Nothing here', 5, 200, 210),
    ]);
    final r = await programReadiness(db, program, recentWeeks: 4);
    expect(r.map((p) => p.index), [0, 2]);
    final flat = r[0];
    expect(flat.candidates, 6);
    expect(flat.avgSeconds, 300);
    expect(flat.needed, 2);
    expect(flat.fresh, 4);
    expect(flat.status, ReadinessStatus.thin);
    final none = r[1];
    expect(none.candidates, 0);
    expect(none.fresh, 0);
    expect(none.needed, 2); // 5 min at the 240 s fallback
    expect(none.status, ReadinessStatus.empty);

    final ok = await programReadiness(db, program, recentWeeks: 4, avgSongSeconds: 600);
    expect(ok[0].needed, 1);
    expect(ok[0].status, ReadinessStatus.ok);
  });

  test('Mix filters from base narrow the candidates', () async {
    await db.upsertSong(_s('rock', 80, genre: 'Rock'));
    await db.upsertSong(_s('pop', 80, genre: 'Pop'));
    const program = Program('P', [ProgramPart('Flat', 4, 75, 85)]);
    final r = await programReadiness(db, program,
        base: (_) => const MixFilter(genre: 'Rock').applyTo(const SongQuery()));
    expect(r.single.candidates, 1);
    expect(r.single.query.genre, 'Rock');
  });

  test('coverage folds half and double time into each role span', () async {
    for (final b in [62.0, 124.0, 31.0, 68.0, 100.0, 90.0, 180.0]) {
      await db.upsertSong(_s('s$b', b));
    }
    const program = Program('P', [
      ProgramPart('Climb', 5, 60, 70),
      ProgramPart('Sprint', 3, 90, 100),
      ProgramPart('Climb', 5, 65, 70),
    ]);
    final c = await rpmCoverage(db, program);
    expect(c.map((r) => r.role), [PartRole.climb, PartRole.sprint]);
    final climb = c[0];
    expect([for (final b in climb.bands) (b.lo, b.hi)], [(60.0, 65.0), (65.0, 70.0)]);
    // 62, 124/2, 31*2 -> 60-65; 68 -> 65-70; 100, 90, 180 don't fold into 60-70
    expect([for (final b in climb.bands) b.songs], [3, 1]);
    final sprint = c[1];
    // 90 and 180/2 -> 90-95; 100 -> 95-100 (upper edge included)
    expect([for (final b in sprint.bands) b.songs], [2, 1]);
  });
}
