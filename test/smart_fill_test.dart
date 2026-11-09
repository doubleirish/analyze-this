import 'dart:math';

import 'package:analyze_this/services/db.dart';
import 'package:analyze_this/services/fill_planner.dart';
import 'package:analyze_this/services/mix_controller.dart';
import 'package:analyze_this/services/planner.dart';
import 'package:flutter_test/flutter_test.dart';

Song song(String n, {double bpm = 85, double duration = 200, String artist = 'A', int rating = 0}) =>
    Song(
        path: 'C:\\m\\$n.mp3',
        title: n,
        artist: artist,
        medianBpm: bpm,
        duration: duration,
        rating: rating);

List<String?> titles(Iterable<Song> l) => [for (final s in l) s.title];

void main() {
  group('orderChain', () {
    test('smooths the tempo chain, counting half / double time', () {
      final prev = song('p', bpm: 86, artist: 'P');
      final bad = [
        song('a', bpm: 120, artist: 'W'),
        song('b', bpm: 90, artist: 'X'),
        song('c', bpm: 170, artist: 'Y'),
        song('d', bpm: 88, artist: 'Z'),
      ];
      final ordered = orderChain(bad, previous: prev);
      // 170 is 85 at half time, closest to 86; 88 ≈ 176/2; then 90, then 120.
      expect(titles(ordered), ['c', 'd', 'b', 'a']);
      expect(bigJumps([prev, ...ordered]), hasLength(1));
      expect(bigJumps([prev, ...bad]), hasLength(2));
    });

    test('avoids the same artist twice in a row unless only a big jump is left', () {
      final ordered = orderChain([
        song('a1', bpm: 90, artist: 'A'),
        song('a2', bpm: 91, artist: 'A'),
        song('b1', bpm: 93, artist: 'B'),
      ]);
      expect(titles(ordered), ['a1', 'b1', 'a2']);

      final forced = orderChain([
        song('a1', bpm: 90, artist: 'A'),
        song('a2', bpm: 91, artist: 'A'),
        song('b1', bpm: 130, artist: 'B'),
      ]);
      expect(titles(forced), ['a1', 'a2', 'b1']);
    });

    test('songs without tempo do not break the chain', () {
      final ordered = orderChain([
        Song(path: 'x', title: 'x'),
        song('a', bpm: 100),
      ], previous: song('p', bpm: 100, artist: 'P'));
      expect(ordered, hasLength(2));
    });
  });

  group('pickFill', () {
    test('skips the previous artist, falling back when there is only one', () {
      final prev = song('p', artist: 'Queen');
      final cands = [song('q1', artist: 'queen '), song('q2', artist: 'Queen'), song('o', artist: 'Other')];
      for (var seed = 0; seed < 20; seed++) {
        expect(pickFill(cands, Random(seed), previous: prev, need: 1000)!.title, 'o');
      }
      final only = [song('q1', artist: 'Queen'), song('q2', artist: 'Queen')];
      expect(pickFill(only, Random(1), previous: prev, need: 1000), isNotNull);
      expect(pickFill(const [], Random(1), need: 1000), isNull);
    });

    test('the last song of a part is the closest fit to the time left', () {
      final cands = [
        song('long', duration: 330),
        song('fit', duration: 215),
        song('short', duration: 150, rating: 5),
        song('tiny', duration: 100),
      ];
      for (var seed = 0; seed < 20; seed++) {
        expect(pickFill(cands, Random(seed), need: 220)!.title, 'fit');
      }
      // Nothing can finish 900 s yet: a weighted random pick, reproducible by seed.
      final a = [for (var s = 0; s < 10; s++) pickFill(cands, Random(s), need: 900)!.title];
      final b = [for (var s = 0; s < 10; s++) pickFill(cands, Random(s), need: 900)!.title];
      expect(a, b);
      expect(a.toSet().length, greaterThan(1));
    });
  });

  group('preferCandidates', () {
    final prev = song('p', artist: 'Queen');
    final q = song('q', artist: 'Queen');
    final taught = song('t', artist: 'Other');
    final fresh = song('f', artist: 'Other');

    test('drops the previous artist, then recently taught songs', () {
      expect(titles(preferCandidates([q, taught, fresh], previous: prev, recentlyTaught: {taught.path})),
          ['f']);
      // No recently taught set: only the artist tier applies.
      expect(titles(preferCandidates([q, taught, fresh], previous: prev)), ['t', 'f']);
    });

    test('falls back tier by tier rather than returning nothing', () {
      // Only taught songs by other artists: keep them over the same artist.
      expect(titles(preferCandidates([q, taught], previous: prev, recentlyTaught: {taught.path})),
          ['t']);
      // Only the same artist: still prefer the one not taught.
      final q2 = song('q2', artist: 'Queen');
      expect(titles(preferCandidates([q, q2], previous: prev, recentlyTaught: {q.path})), ['q2']);
      // Everything taught: all of them.
      expect(titles(preferCandidates([taught], recentlyTaught: {taught.path})), ['t']);
    });

    test('rankNotRecent puts taught songs last, keeping order', () {
      expect(titles(rankNotRecent([taught, q, fresh], {taught.path})), ['q', 'f', 't']);
    });
  });

  test('fillReport', () {
    expect(fillReport(12, 1, 2), 'Filled 12 songs · 1 relaxed · 2 big jumps');
    expect(fillReport(1, 0, 0), 'Filled 1 song');
    expect(fillReport(3, 0, 1), 'Filled 3 songs · 1 big jump');
    expect(fillReport(3, 0, 0, uneven: 1), 'Filled 3 songs · 1 uneven part');
  });

  group('planPartSongs', () {
    test('two even songs beat one long song plus a short tail', () {
      final cands = [
        song('long', duration: 420, artist: 'L', rating: 5),
        song('tail', duration: 70, artist: 'T', rating: 5),
        song('a', duration: 245, artist: 'X'),
        song('b', duration: 250, artist: 'Y', bpm: 87),
      ];
      for (var seed = 0; seed < 10; seed++) {
        final pick = planPartSongs(cands, 490, Random(seed))!;
        expect(titles(pick.songs)..sort(), ['a', 'b'], reason: 'seed $seed');
        expect(pick.stage, 0);
      }
    });

    test('prefers a tempo match among even songs', () {
      final cands = [
        song('a', duration: 240, artist: 'X'),
        song('b', duration: 240, artist: 'Y', bpm: 100),
        song('c', duration: 240, artist: 'Z', bpm: 88),
      ];
      expect(titles(planPartSongs(cands, 480, Random(1))!.songs)..sort(), ['a', 'c']);
    });

    test('the songs end within a minute of the target', () {
      final cands = [for (var k = 0; k < 20; k++) song('s$k', duration: 170.0 + k * 7, artist: '$k')];
      for (final need in [300.0, 480.0, 600.0, 900.0]) {
        final pick = planPartSongs(cands, need, Random(3))!;
        final total = pick.songs.fold<double>(0, (a, s) => a + s.duration!);
        expect((total - need).abs(), lessThanOrEqualTo(partToleranceSeconds), reason: '$need');
      }
    });

    test('balances new songs against locked ones', () {
      final locked = song('lock', duration: 240, artist: 'L');
      final cands = [
        song('short', duration: 130, artist: 'S'),
        song('even', duration: 250, artist: 'E'),
        song('short2', duration: 120, artist: 'S2'),
      ];
      expect(titles(planPartSongs(cands, 250, Random(1), anchors: [locked])!.songs), ['even']);
    });

    test('loosens only when nothing balanced exists, and flags it', () {
      final pick = planPartSongs(
          [song('long', duration: 400, artist: 'L'), song('short', duration: 100, artist: 'S')],
          500,
          Random(1))!;
      expect(pick.songs, hasLength(2));
      expect(pick.uneven, isTrue);
    });

    test('too little time left picks nothing unless a song is required', () {
      final cands = [song('a', duration: 200)];
      expect(planPartSongs(cands, 40, Random(1)), isNull);
      expect(planPartSongs(cands, 40, Random(1), required: true, single: true)!.songs, hasLength(1));
    });
  });

  group('MixController fill', () {
    late MusicDb db;
    setUp(() async {
      db = await MusicDb.open(':memory:');
      for (var k = 0; k < 12; k++) {
        await db.upsertSong(song('s$k',
            bpm: 80.0 + k, duration: 180, artist: k.isEven ? 'Even' : 'Odd'));
      }
    });
    tearDown(() async => db.close());

    const prog = Program('t', [
      ProgramPart('Warm', 12, 80, 90),
      ProgramPart('Push', 6, 85, 100),
    ]);

    test('is reproducible with a seeded Random and chains smoothly', () async {
      final m = MixController(db, random: Random(7));
      expect(await m.fillProgram(prog), 0);
      final again = MixController(db, random: Random(7));
      await again.fillProgram(prog);
      expect(titles(again.mix), titles(m.mix));

      expect(m.mixPart, [0, 0, 0, 0, 1, 1]);
      for (var i = 0; i + 1 < m.mix.length; i++) {
        expect(sameArtist(m.mix[i], m.mix[i + 1]), isFalse, reason: 'at $i');
      }
      expect(bigJumps(m.mix), isEmpty);
      expect(m.lastFillAdded, 6);
      expect(m.lastFillBigJumps, 0);
      expect(m.lastFillReport, 'Filled 6 songs');
      // Each part is in greedy chain order after the previous song.
      expect(titles(m.mix.sublist(0, 4)), titles(orderChain(m.mix.sublist(0, 4))));
      expect(titles(m.mix.sublist(4)),
          titles(orderChain(m.mix.sublist(4), previous: m.mix[3])));
    });

    test('partWarning flags parts off their length or with uneven songs', () async {
      final m = MixController(db, random: Random(7));
      await m.fillProgram(prog);
      expect(m.partWarning(0), isNull);
      m.addToPart(Song(path: 'C:\\m\\x.mp3', title: 'x', medianBpm: 86, duration: 60), 1);
      expect(m.partWarning(1), 'Uneven song lengths');
      m.addToPart(Song(path: 'C:\\m\\y.mp3', title: 'y', medianBpm: 86, duration: 200), 1);
      expect(m.partWarning(1), startsWith('Over by'));
    });

    test('locked songs stay first in their part; new picks chain on from them', () async {
      final m = MixController(db, random: Random(2));
      await m.fillProgram(prog);
      m.addToPart(Song(path: 'C:\\m\\lock.mp3', title: 'lock', artist: 'L', medianBpm: 170, duration: 180), 1);
      final li = m.mix.indexWhere((s) => s.title == 'lock');
      m.toggleLock(li);

      await m.fillProgram(prog);
      final start = m.mixPart.indexOf(1);
      expect(m.mix[start].title, 'lock');
      expect(m.mixPart.where((p) => p == 1), hasLength(2));
      // 170 is 85 at half time, so the pick after it is no big jump.
      expect(bpmJump(170, m.mix[start + 1].medianBpm!), lessThan(bigJumpBpm));

      final added = await m.refillPart(1);
      expect(added, 1);
      expect(m.mix[m.mixPart.indexOf(1)].title, 'lock');
      expect(bpmJump(170, m.mix[m.mixPart.indexOf(1) + 1].medianBpm!), lessThan(bigJumpBpm));
    });

    test('avoids recently taught songs when others fit, else falls back', () async {
      final base = MixController(db, random: Random(7));
      await base.fillProgram(prog);
      final taught = [for (final s in base.mix.take(3)) s.path];
      await db.logClass(
          mixName: 'last week',
          paths: taught,
          taughtAt: DateTime.now().subtract(const Duration(days: 7)));

      for (var seed = 0; seed < 5; seed++) {
        final m = MixController(db, random: Random(seed));
        await m.fillProgram(prog);
        expect(m.mix, hasLength(6));
        expect(m.paths.where(taught.contains), isEmpty, reason: 'seed $seed');
      }

      // Every song taught: the fill still uses them.
      await db.logClass(
          mixName: 'all',
          paths: [for (var k = 0; k < 12; k++) song('s$k').path],
          taughtAt: DateTime.now());
      final m = MixController(db, random: Random(7));
      await m.fillProgram(prog);
      expect(m.mix, hasLength(6));
    });
  });
}
