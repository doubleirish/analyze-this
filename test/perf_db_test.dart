import 'dart:io';

import 'package:analyze_this/services/db.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _v10Indexes = [
  'idx_songs_median_bpm',
  'idx_songs_artist',
  'idx_songs_genre',
  'idx_songs_dup_key',
  'idx_songs_added_at',
  'idx_mix_items_path',
  'idx_song_tags_tag',
];

Future<Set<String>> _indexNames(Database db) async => {
      for (final r in await db.rawQuery("SELECT name FROM sqlite_master WHERE type = 'index'"))
        r['name'] as String
    };

void main() {
  group('bulk tag loading', () {
    late MusicDb db;

    setUp(() async => db = await MusicDb.open(':memory:'));
    tearDown(() => db.close());

    Future<void> expectTagsMatch(List<Song> songs) async {
      for (final s in songs) {
        expect(s.userTags, await db.tagsOf(s.path), reason: s.path);
      }
    }

    test('search and allSongs match tagsOf across the chunk boundary', () async {
      const n = 950;
      String p(int i) => 'C:\\m\\${i.toString().padLeft(4, '0')}.mp3';
      for (var i = 0; i < n; i++) {
        await db.upsertSong(Song(path: p(i), title: 't$i', artist: 'A', medianBpm: 100));
        if (i % 3 == 1) {
          for (final t in ['zulu', 'Alpha', '10', '9']) {
            await db.addTag(p(i), t);
          }
        } else if (i % 3 == 2) {
          await db.addTag(p(i), 'solo');
        }
      }

      final all = await db.allSongs();
      expect(all, hasLength(n));
      await expectTagsMatch(all);
      final byPath = {for (final s in all) s.path: s};
      expect(byPath[p(0)]!.userTags, isEmpty);
      expect(byPath[p(1)]!.userTags, ['10', '9', 'alpha', 'zulu']);
      expect(byPath[p(2)]!.userTags, ['solo']);
      expect(byPath[p(n - 1)]!.userTags, ['10', '9', 'alpha', 'zulu']);

      final found = await db.search(const SongQuery(limit: 2000, sort: SongSort.title));
      expect(found, hasLength(n));
      await expectTagsMatch(found);

      expect(await db.tagsFor(const []), isEmpty);
      final some = await db.tagsFor([p(0), p(1), p(1), 'missing']);
      expect(some, {
        p(0): isEmpty,
        p(1): ['10', '9', 'alpha', 'zulu'],
        'missing': isEmpty,
      });
    });

    test('similar, best-of, album, favourites and recent songs carry their tags', () async {
      Song s(String n, {bool fav = false}) => Song(
          path: 'C:\\m\\$n.mp3',
          title: n,
          artist: 'Band',
          album: 'Record',
          genre: 'Rock',
          year: 1991,
          medianBpm: 120,
          fav: fav);
      for (final n in ['a', 'b', 'c', 'd']) {
        await db.upsertSong(s(n, fav: n != 'd'));
      }
      await db.addTag('C:\\m\\a.mp3', 'summer');
      await db.addTag('C:\\m\\b.mp3', 'party');
      await db.addTag('C:\\m\\b.mp3', 'drive');

      final seed = (await db.song('C:\\m\\a.mp3'))!;
      expect(seed.userTags, ['summer']);

      final sim = await db.similar(seed);
      expect(sim.map((e) => e.path), isNot(contains(seed.path)));
      expect(sim, hasLength(3));
      await expectTagsMatch(sim);
      expect(sim.firstWhere((e) => e.title == 'b').userTags, ['drive', 'party']);

      await db.saveBestOf('Band', ['C:\\m\\b.mp3', 'C:\\m\\a.mp3']);
      final best = await db.bestOfSongs('Band');
      expect(best.map((e) => e.title), ['b', 'a']);
      await expectTagsMatch(best);
      expect(best.first.userTags, ['drive', 'party']);
      expect(await db.albumSongs(bestOfTitle('Band'), 'Band'), hasLength(2));

      final album = await db.albumSongs('Record', 'Band');
      expect(album.map((e) => e.title), ['a', 'b', 'c', 'd']);
      await expectTagsMatch(album);

      final forgotten = await db.forgottenFavorites();
      expect(forgotten.map((e) => e.title).toSet(), {'a', 'b', 'c'});
      await expectTagsMatch(forgotten);

      await db.recordPlay('C:\\m\\a.mp3', 60, true, at: 1000);
      await db.recordPlay('C:\\m\\b.mp3', 60, true, at: 3000);
      await db.recordPlay('C:\\m\\c.mp3', 60, true, at: 2000);
      await db.recordPlay('C:\\m\\gone.mp3', 60, true, at: 4000);
      final recent = await db.recentlyPlayed();
      expect(recent.map((e) => e.title), ['b', 'c', 'a']);
      await expectTagsMatch(recent);
      expect((await db.recentlyPlayed(limit: 1)).single.title, 'b');
    });
  });

  group('schema v10 indexes', () {
    late Directory tmp;

    setUp(() async => tmp = await Directory.systemTemp.createTemp('perf_db_'));
    tearDown(() => tmp.delete(recursive: true));

    test('a fresh database has the v10 indexes', () async {
      final path = '${tmp.path}${Platform.pathSeparator}fresh.db';
      final db = await MusicDb.open(path);
      await db.close();
      final raw = await databaseFactoryFfi.openDatabase(path);
      expect(await raw.getVersion(), greaterThanOrEqualTo(10));
      expect(await _indexNames(raw), containsAll(_v10Indexes));
      await raw.close();
    });

    test('upgrading a v9 database adds the indexes and keeps the data', () async {
      final path = '${tmp.path}${Platform.pathSeparator}old.db';
      final db = await MusicDb.open(path);
      await db.upsertSong(Song(path: 'C:\\m\\x.mp3', title: 'x', medianBpm: 128));
      await db.addTag('C:\\m\\x.mp3', 'keep');
      await db.saveMix('m', ['C:\\m\\x.mp3']);
      await db.close();

      // v10 only added indexes, so dropping them recreates the v9 schema.
      var raw = await databaseFactoryFfi.openDatabase(path);
      for (final i in _v10Indexes) {
        await raw.execute('DROP INDEX $i');
      }
      await raw.setVersion(9);
      expect((await _indexNames(raw)).intersection(_v10Indexes.toSet()), isEmpty);
      await raw.close();

      final upgraded = await MusicDb.open(path);
      final s = await upgraded.song('C:\\m\\x.mp3');
      expect(s!.medianBpm, 128);
      expect(s.userTags, ['keep']);
      expect(await upgraded.mixPaths((await upgraded.mixes()).single.id), ['C:\\m\\x.mp3']);
      await upgraded.close();

      raw = await databaseFactoryFfi.openDatabase(path);
      expect(await raw.getVersion(), greaterThanOrEqualTo(10));
      expect(await _indexNames(raw), containsAll(_v10Indexes));
      await raw.close();
    });
  });
}
