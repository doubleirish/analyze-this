import 'dart:math';

import 'package:analyze_this/services/db.dart';
import 'package:analyze_this/services/mix_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late MusicDb db;

  Song song(String p, double dur, double bpm) =>
      Song(path: p, title: p, duration: dur, medianBpm: bpm, avgBpm: bpm);

  setUp(() async {
    db = await MusicDb.open(':memory:');
    for (final s in [
      song('bad', 240, 120),
      song('near', 245, 121),
      song('far', 420, 121),
      song('slow', 240, 80),
      song('other', 180, 120),
    ]) {
      await db.upsertSong(s);
    }
  });
  tearDown(() => db.close());

  group('recordHealth', () {
    test('damage tags the song; a clean recheck of the same file clears a quick flag', () async {
      expect(await db.recordHealth('bad', damaged: true, reason: 'truncated', depth: 'quick', size: 1, mtime: 1),
          isTrue);
      expect((await db.song('bad'))!.damaged, isTrue);
      expect((await db.healthOf(['bad']))['bad']!.reason, 'truncated');

      await db.recordHealth('bad', damaged: false, depth: 'quick', size: 1, mtime: 1);
      expect((await db.song('bad'))!.damaged, isFalse);
    });

    test('a quick pass does not clear damage found by a deep check', () async {
      await db.recordHealth('bad', damaged: true, reason: 'decode error', depth: 'deep', size: 1, mtime: 1);
      expect(await db.recordHealth('bad', damaged: false, depth: 'quick', size: 1, mtime: 1), isTrue);
      expect((await db.song('bad'))!.damaged, isTrue);
      // a changed file is judged afresh
      await db.recordHealth('bad', damaged: false, depth: 'quick', size: 2, mtime: 2);
      expect((await db.song('bad'))!.damaged, isFalse);
    });

    test('removing the tag by hand overrides later checks of the same file', () async {
      await db.recordHealth('bad', damaged: true, reason: 'x', depth: 'quick', size: 1, mtime: 1);
      await db.removeTag('bad', corruptTag);
      expect(await db.recordHealth('bad', damaged: true, reason: 'x', depth: 'quick', size: 1, mtime: 1),
          isFalse);
      expect((await db.song('bad'))!.damaged, isFalse);
      expect(await db.recordHealth('bad', damaged: true, reason: 'x', depth: 'quick', size: 9, mtime: 9),
          isTrue);
    });

    test('tagging by hand records a manual flag', () async {
      await db.addTag('other', 'Corrupt');
      final h = (await db.healthOf(['other']))['other']!;
      expect(h.damaged, isTrue);
      expect(h.depth, 'manual');
    });

    test('hideCorrupt and per-mix counts', () async {
      await db.recordHealth('bad', damaged: true, reason: 'x', depth: 'quick', size: 1, mtime: 1);
      final all = await db.search(const SongQuery());
      final clean = await db.search(const SongQuery(hideCorrupt: true));
      expect(all.map((s) => s.path), contains('bad'));
      expect(clean.map((s) => s.path), isNot(contains('bad')));
      final a = await db.saveMix('A', ['bad', 'near']);
      await db.saveMix('B', ['near']);
      expect(await db.damagedCountByMix(), {a: 1});
      expect((await db.damagedSongs()).single.$1.path, 'bad');
    });
  });

  group('MixController', () {
    late MixController c;
    setUp(() async {
      c = MixController(db, random: Random(1));
      await db.recordHealth('bad', damaged: true, reason: 'truncated', depth: 'quick', size: 1, mtime: 1);
    });

    test('damaged songs cannot be added by hand', () async {
      final bad = (await db.song('bad'))!;
      expect(c.addToMix(bad), isFalse);
      expect(c.addToPart(bad, 0), isFalse);
      expect(c.mix, isEmpty);
      expect(c.addToMix((await db.song('near'))!), isTrue);
    });

    test('replace picks the closest length and tempo; replace-all is one undo', () async {
      final id = await db.saveMix('M', ['bad', 'other']);
      await c.loadMix(MixInfo(id, 'M'));
      expect(c.damagedIndexes, [0]);
      expect(c.damagedReasons['bad'], 'truncated');

      final cands = await c.replacementsFor(0);
      expect(cands.first.path, 'near');
      expect(cands.map((s) => s.path), isNot(contains('bad')));

      final (done, total) = await c.replaceAllDamaged();
      expect((done, total), (1, 1));
      expect(c.paths, ['near', 'other']);
      expect(c.damagedIndexes, isEmpty);
      c.undo();
      expect(c.paths, ['bad', 'other']);
    });
  });
}
