import 'dart:io';
import 'dart:math';

import 'package:analyze_this/screens/browse_screens.dart';
import 'package:analyze_this/services/app_state.dart';
import 'package:analyze_this/services/db.dart';
import 'package:analyze_this/services/mix_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_core/shared_core.dart' show PlayMode;

class _PlaybackState extends AppState {
  _PlaybackState(super.db) { player; }

  @override
  Future<void> loadCurrent({bool preview = false}) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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

  Future<Song> fixture(Directory dir, String file, {String title = 'Same',
      String album = 'Album', bool damaged = false, int frames = 3}) async {
    final bytes = <int>[];
    for (var i = 0; i < frames; i++) {
      bytes.addAll([0xff, 0xfb, 0x90, 0, ...List.filled(413, 0)]);
    }
    final f = await File('${dir.path}\\$file').writeAsBytes(bytes);
    final stat = await f.stat();
    final s = Song(path: f.path, artist: 'Artist', title: title, album: album,
        dupKey: dupKeyFor('Artist', title), duration: 200, size: stat.size,
        mtime: stat.modified.millisecondsSinceEpoch);
    await db.upsertSong(s);
    if (damaged) await db.addTag(s.path, corruptTag);
    return (await db.song(s.path))!;
  }

  test('album/artist queues and library shuffle use available copies without hiding distinct tracks', () async {
    final dir = await Directory.systemTemp.createTemp('duplicate_playback_');
    final state = _PlaybackState(db);
    addTearDown(() async { state.dispose(); await dir.delete(recursive: true); });
    final low = await fixture(dir, '01 Same.mp3');
    final high = await fixture(dir, '99 Same.wma', frames: 6);
    final different = await fixture(dir, '01 Different.mp3', title: 'Different');
    final live = await fixture(dir, 'Live.mp3', album: 'Live');
    state.results = [low, high, different, live];
    await playAlbum(state, 'Album', 'Artist');
    expect(state.queue.toSet(), {high.path, different.path});
    await playArtist(state, 'Artist', shuffle: true);
    expect(state.queue.toSet(), {high.path, different.path, live.path});
    state.mode = PlayMode.shuffle;
    await state.play(low.path);
    expect(state.queue.first, high.path);
    expect(state.queue.toSet(), {high.path, different.path, live.path});
    await File(high.path).delete();
    await playAlbum(state, 'Album', 'Artist');
    expect(state.queue.toSet(), {low.path, different.path});
  });

  test('cleanup deletes only damaged copies with unchanged healthy replacements', () async {
    final dir = await Directory.systemTemp.createTemp('duplicate_cleanup_');
    final state = _PlaybackState(db);
    addTearDown(() async { state.dispose(); await dir.delete(recursive: true); });
    final good = await fixture(dir, 'good.mp3');
    final bad = await fixture(dir, 'bad.mp3', damaged: true);
    final bad2 = await fixture(dir, 'bad2.mp3', title: 'All damaged', damaged: true);
    final bad3 = await fixture(dir, 'bad3.mp3', title: 'All damaged', damaged: true);
    final missing = await fixture(dir, 'missing.mp3', title: 'Missing keeper');
    final orphan = await fixture(dir, 'orphan.mp3', title: 'Missing keeper', damaged: true);
    final changed = await fixture(dir, 'changed.mp3', title: 'Changed keeper');
    final unsafe = await fixture(dir, 'unsafe.mp3', title: 'Changed keeper', damaged: true);
    final rescanned = await fixture(dir, 'rescanned.mp3', title: 'Changed damaged', damaged: true);
    final keeper = await fixture(dir, 'keeper.mp3', title: 'Changed damaged');
    final unflagged = await fixture(dir, 'unflagged.mp3', title: 'Unflagged', damaged: true);
    final unflaggedKeeper = await fixture(dir, 'unflaggedkeeper.mp3', title: 'Unflagged');
    await File(missing.path).delete();
    await File(changed.path).writeAsBytes([1, 2]);
    await File(rescanned.path).writeAsBytes([1, 2]);
    final newStat = await File(rescanned.path).stat();
    await db.upsertSong(Song(
        path: rescanned.path, artist: rescanned.artist, title: rescanned.title,
        album: rescanned.album, dupKey: rescanned.dupKey, size: newStat.size,
        mtime: newStat.modified.millisecondsSinceEpoch));
    await db.removeTag(unflagged.path, corruptTag);
    await File('${bad.path}.lrc').writeAsString('lyrics');
    final songs = [good, bad, bad2, bad3, missing, orphan, changed, unsafe,
        rescanned, keeper, unflagged, unflaggedKeeper];
    expect(await state.cleanDuplicates(songs), 1);
    expect(await File(bad.path).exists(), isFalse);
    expect(await File('${bad.path}.lrc').exists(), isFalse);
    expect(await db.song(bad.path), isNull);
    for (final s in [good, bad2, bad3, orphan, unsafe, rescanned, unflagged]) {
      expect(await File(s.path).exists(), isTrue, reason: s.path);
      expect(await db.song(s.path), isNotNull);
    }
  });

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
