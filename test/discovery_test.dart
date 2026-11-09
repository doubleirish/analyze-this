import 'dart:convert';
import 'dart:io';

import 'package:shared_core/shared_core.dart';
import 'package:analyze_this/services/db.dart';
import 'package:analyze_this/services/discography.dart';
import 'package:analyze_this/services/lyric_keywords.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Song _s(String p, String artist, String album, double bpm,
        {int? year, String? genre, String? lyrics}) =>
    Song(
        path: p,
        artist: artist,
        album: album,
        title: p,
        medianBpm: bpm,
        year: year,
        genre: genre,
        lyrics: lyrics,
        dupKey: dupKeyFor(artist, p),
        addedAt: 1000);

Future<MusicDb> _library() async {
  final db = await MusicDb.open(':memory:');
  for (final x in [
    _s('a1', 'Oasis', 'Morning Glory', 120, year: 1995, genre: 'Britpop'),
    _s('a2', 'oasis ', 'morning glory', 128, year: 1995, genre: 'Britpop'),
    _s('a3', 'Oasis', 'Definitely Maybe', 140, year: 1994),
    _s('b1', 'Blur', 'Parklife', 126, year: 1994, genre: 'Britpop'),
    _s('c1', 'Europe', 'The Final Countdown', 118, year: 1986),
  ]) {
    await db.upsertSong(x);
  }
  return db;
}

void main() {
  test('artist albums sort by favourites, then year; best-of stays in albums', () {
    AlbumInfo album(String title, {int? year, int favs = 0}) =>
        AlbumInfo(title, 'U2', 10, title, year: year, favs: favs);
    final sorted = sortArtistAlbums([
      album('Undated'),
      album('Newest', year: 2026),
      album('Favourite', year: 1980, favs: 2),
      album('Beta', year: 1990, favs: 1),
      album('alpha', year: 1990, favs: 1),
      album('Later favourite', year: 2000, favs: 1),
      const AlbumInfo('Best of', 'U2', 2, 'best', synthetic: true),
    ]);
    expect(sorted.map((a) => a.album),
        ['Best of', 'Favourite', 'Later favourite', 'alpha', 'Beta', 'Newest', 'Undated']);
    expect(sorted.first.isMinor, isFalse);
  });

  test('minor releases use track count or complete duration, with a strict 30 minute boundary', () {
    AlbumInfo album(int tracks, double? seconds) =>
        AlbumInfo('Release', 'U2', tracks, 'song', totalSecs: seconds);
    expect(album(3, null).isMinor, isTrue);
    expect(album(6, 2400).isMinor, isTrue);
    expect(album(7, 1799).isMinor, isTrue);
    expect(album(7, 1800).isMinor, isFalse);
    expect(album(7, null).isMinor, isFalse);
  });

  test('album aggregates count favourites and do not treat partial durations as short releases', () async {
    final db = await MusicDb.open(':memory:');
    addTearDown(db.close);
    for (var i = 0; i < 7; i++) {
      await db.upsertSong(Song(path: 'song$i', album: 'Album', artist: 'U2',
          duration: 200, fav: i < 2));
    }
    var a = (await db.albums(artist: 'u2')).single;
    expect((a.favs, a.totalSecs, a.isMinor), (2, 1400.0, true));
    await db.upsertSong(Song(path: 'unknown', album: 'Album', artist: 'u2 '));
    a = (await db.albums(artist: 'U2')).single;
    expect((a.favs, a.totalSecs, a.isMinor), (2, null, false));
    await db.setFav('song2', true);
    expect((await db.albums(artist: 'U2')).single.favs, 3);
  });

  test('missing albums: ignores editions, oldest first, undated last', () {
    expect(albumKey('The Joshua Tree (Super Deluxe Edition)'), 'joshua tree');
    expect(albumKey('Parklife - 2012 Remaster'), 'parklife');
    final r = [
      const AlbumRelease('Zooropa', '1993-07-05', 'album', null),
      const AlbumRelease('Boy (Deluxe)', '1980-10-20', 'album', null),
      const AlbumRelease('Boy', '1980-10-20', 'album', null),
      const AlbumRelease('October', '1981-10-12', 'album', null),
      const AlbumRelease('Mystery', null, 'ep', null),
      const AlbumRelease('War', '1983-02-28', 'album', null),
    ];
    expect(missingAlbums(r, ['war', 'Boy [Remastered]']).map((e) => e.title),
        ['October', 'Zooropa', 'Mystery']);
  });

  test('discography parses albums/EPs, caches, and does not cache failures', () async {
    final dir = await Directory.systemTemp.createTemp('disco');
    var calls = 0;
    var fail = true;
    final client = MockClient((req) async {
      calls++;
      if (fail) return http.Response('x', 500);
      if (req.url.path == '/search/artist') {
        return http.Response(
            jsonEncode({'data': [{'id': 7, 'name': 'U2'}]}), 200);
      }
      if (req.url.path == '/artist/7/albums') {
        return http.Response(
            jsonEncode({'data': [
              {'title': 'Boy', 'release_date': '1980-10-20', 'record_type': 'album', 'cover_medium': 'https://x/c.jpg'},
              {'title': 'Sunday', 'release_date': '1983-01-01', 'record_type': 'single'},
            ]}),
            200);
      }
      return http.Response.bytes(List.filled(400, 1), 200);
    });
    final d = Discography(dir, net: PoliteHttp(client: client, defaultGap: Duration.zero, maxRetries: 0));
    await expectLater(d.releases('U2'), throwsA(anything));
    fail = false;
    final r = (await d.releases('U2'))!;
    expect(r.map((e) => e.title), ['Boy']);
    final before = calls;
    expect(await d.releases('u2'), hasLength(1));
    expect(calls, before);
    expect(await d.cover('U2', r.single), isNotNull);
    await dir.delete(recursive: true);
  });

  test('genre lists: artist default, album overrides it, song genre wins', () async {
    final db = await _library();
    await db.setArtistGenre('Oasis', 'Rock');
    Future<Map<String, String?>> g() async =>
        {for (final s in await db.search(const SongQuery(artist: 'oasis')) ) s.path: s.genre};
    expect(await g(), {'a1': 'Britpop', 'a2': 'Britpop', 'a3': 'Rock'});

    await db.setAlbumGenre('Oasis', 'Definitely Maybe', 'Indie', source: 'api');
    expect((await g())['a3'], 'Indie');
    // an API album genre never replaces one typed by the user
    await db.setAlbumGenre('Oasis', 'Definitely Maybe', 'Pop', source: 'api');
    expect((await g())['a3'], 'Indie');

    await db.setArtistGenre('Oasis', '');
    await db.setAlbumGenre('Oasis', 'Definitely Maybe', '');
    expect((await g())['a3'], isNull);

    final json = await db.exportGenreFile();
    await db.setArtistGenre('Blur', 'Britpop');
    expect(await db.importGenreFile(json), 0);
    await db.close();
  });

  test('artists sort by song count or name and hide small ones', () async {
    final db = await _library();
    expect((await db.artists(bySongs: false)).map((a) => a.name.trim().toLowerCase()),
        ['blur', 'europe', 'oasis']);
    expect(await db.artists(hideUpTo: 1), hasLength(1));
    expect((await db.albums(bySongs: true)).first.songs, 2);
    expect(await db.albums(hideUpTo: 1), hasLength(1));
    await db.close();
  });

  test('duplicate suggestions keep the copy in the folder with more songs', () async {
    final db = await MusicDb.open(':memory:');
    for (final p in ['/big/a.mp3', '/big/b.mp3', '/big/c.mp3', '/small/a.mp3']) {
      await db.upsertSong(Song(
          path: p,
          artist: 'X',
          title: p.endsWith('/a.mp3') ? 'Same' : p,
          dupKey: dupKeyFor('X', p.endsWith('/a.mp3') ? 'Same' : p)));
    }
    final groups = await db.duplicateSuggestions();
    expect(groups, hasLength(1));
    expect(groups.single.songs[groups.single.keeper].path, '/big/a.mp3');
    expect(groups.single.suggestedRemovals.map((s) => s.path), ['/small/a.mp3']);
    await db.close();
  });

  test('artists and albums group ignoring case, filter and drill down', () async {
    final db = await _library();
    final artists = await db.artists();
    expect(artists.map((a) => a.name.toLowerCase().trim()), ['oasis', 'blur', 'europe']);
    final oasis = artists.first;
    expect((oasis.songs, oasis.albums), (3, 2));
    expect((oasis.minBpm, oasis.maxBpm), (120.0, 140.0));
    expect(await db.artists(filter: 'blu'), hasLength(1));

    expect((await db.albums(artist: 'OASIS')).map((a) => a.songs).toList()..sort(), [1, 2]);
    expect((await db.albums(filter: 'park')).single.artist, 'Blur');
    expect(await db.discographyGaps(), hasLength(4));
    expect(await db.discographyGaps(max: 1), hasLength(3));

    expect(await db.search(const SongQuery(artist: 'oasis', exactNames: true)), hasLength(3));
    expect(await db.search(const SongQuery(artist: 'as')), hasLength(3));
    expect(await db.search(const SongQuery(artist: 'as', exactNames: true)), isEmpty);
    expect(
        await db.search(
            const SongQuery(album: 'morning glory', artist: 'oasis', exactNames: true)),
        hasLength(2));
    await db.close();
  });

  test('similar songs rank by tempo, genre, decade and artist', () async {
    final db = await _library();
    final base = (await db.search(const SongQuery(album: 'Parklife'))).single;
    final out = await db.similar(base);
    expect(out.first.path, 'a2'); // 128 BPM, Britpop, 90s
    expect(out.map((s) => s.path), isNot(contains('b1')));
    // half time counts, but scores below an exact tempo match
    final fast = _s('f', 'X', 'Y', 240);
    expect(similarity(_s('h', 'Q', 'R', 120), fast), greaterThan(0));
    expect(similarity(_s('h', 'Q', 'R', 120), _s('e', 'Q2', 'R2', 120)),
        greaterThan(similarity(_s('h', 'Q', 'R', 120), fast)));
    await db.close();
  });

  test('smart lists round trip a query and count live matches', () async {
    final db = await _library();
    const q = SongQuery(genre: 'brit', minBpm: 125, maxBpm: 130, decade: 1990, favOnly: false);
    await db.saveSmartList('Britpop', q);
    final l = (await db.smartLists()).single;
    expect(l.name, 'Britpop');
    expect(l.query.minBpm, 125);
    expect(l.query.decade, 1990);
    expect(await db.count(l.query), 2);
    await db.setFav('a2', true);
    expect(await db.count(SongQuery.fromJson(q.toJson()).copyWith(favOnly: true)), 1);
    await db.deleteSmartList(l.id);
    expect(await db.smartLists(), isEmpty);
    await db.close();
  });

  test('favourites, recently added and mix history', () async {
    final db = await _library();
    await db.upsertSong(_s('new', 'Late', 'Add', 100)
        .copyWith(fav: true)
        .withAdded(DateTime.now().millisecondsSinceEpoch));
    expect((await db.search(const SongQuery(favOnly: true))).single.path, 'new');
    final recent = DateTime.now().subtract(const Duration(days: 1)).millisecondsSinceEpoch;
    expect((await db.search(SongQuery(addedSince: recent))).single.path, 'new');
    expect((await db.search(const SongQuery(sort: SongSort.added))).first.path, 'new');

    await db.saveMix('Class 1', ['a1', 'b1']);
    await db.saveMix('Class 2', ['a1']);
    final used = await db.mixesUsing('a1');
    expect(used.map((m) => m.name).toSet(), {'Class 1', 'Class 2'});
    expect(used.every((m) => m.savedAt != null), isTrue);
    expect(await db.mixesUsing('c1'), isEmpty);
    expect(await db.search(const SongQuery(hideUsed: true, artist: 'blur')), isEmpty);
    expect((await db.artists()).firstWhere((a) => a.name == 'Blur').used, 1);
    await db.close();
  });

  test('batch overrides change songs and are remembered for rescans', () async {
    final db = await _library();
    await db.setOverrides(['a1', 'a3'], artist: 'Oasis UK', genre: 'Rock');
    final a1 = (await db.song('a1'))!;
    expect((a1.artist, a1.genre, a1.year), ('Oasis UK', 'Rock', 1995));
    expect(a1.dupKey, dupKeyFor('Oasis UK', 'a1'));
    expect((await db.override('a3'))!['artist'], 'Oasis UK');
    expect(await db.override('b1'), isNull);
    await db.setOverrides(['a1'], year: 1996);
    expect((await db.override('a1'))!['artist'], 'Oasis UK'); // earlier fields kept
    expect((await db.song('a1'))!.year, 1996);
    await db.deleteSongs(['a1']);
    expect(await db.override('a1'), isNull);
    await db.close();
  });

  test('stats summarise coverage, tempo and decades', () async {
    final db = await MusicDb.open(':memory:');
    await db.upsertSong(_s('1', 'A', 'X', 124, year: 1985, genre: 'Pop', lyrics: 'la'));
    await db.upsertSong(_s('2', 'B', 'Y', 128, year: 1989, genre: 'pop'));
    await db.upsertSong(Song(path: '3'));
    final st = await db.stats();
    expect((st.total, st.withBpm, st.withLyrics, st.withGenre), (3, 2, 1, 2));
    expect(st.bpmBuckets, {120: 2});
    expect(st.decades, {1980: 2});
    expect(st.genres.single.value, 2);
    await db.close();
  });

  test('top keywords skip filler words and one-song choruses', () {
    final k = topKeywords([
      'Climb the mountain, climb climb climb\nfire fire',
      'We climb higher and higher, fire in the sky',
      'only once here: zebra',
    ]);
    final words = k.map((e) => e.key).toList();
    expect(words.first, 'climb');
    expect(words, containsAll(['fire', 'higher']));
    expect(words, isNot(contains('the')));
    expect(words, isNot(contains('zebra')));
    expect(k.first.value, 3); // 2 (capped) + 1
  });

  group('artist photos', () {
    final body = jsonEncode({
      'data': [
        {'name': 'Oasis Tribute', 'picture_medium': 'https://e-cdns-images.dzcdn.net/wrong.jpg'},
        {'name': 'Oasis', 'picture_medium': 'https://e-cdns-images.dzcdn.net/oasis.jpg'},
      ]
    });

    test('candidates are exact matches, deduplicated and not alternate sizes of the same picture', () {
      expect(ArtistArt.pictureCandidates({'data': [
        {'name': 'U2 Tribute', 'picture_medium': 'https://cdn.dzcdn.net/wrong.jpg'},
        {'name': 'U2', 'picture_medium': 'https://cdn.dzcdn.net/one.jpg',
          'picture_big': 'https://cdn.dzcdn.net/one-big.jpg'},
        {'name': 'u2', 'picture_medium': 'https://cdn.dzcdn.net/one.jpg'},
        {'name': 'U2', 'picture_medium': 'https://cdn.dzcdn.net/images/artist//blank.jpg',
          'picture_big': 'https://cdn.dzcdn.net/two.jpg'},
        {'name': 'U2', 'picture_medium': 'https://example.org/untrusted.jpg'},
      ]}, 'U2'), ['https://cdn.dzcdn.net/one.jpg', 'https://cdn.dzcdn.net/two.jpg']);
    });

    test('custom photo survives restart, overwrites old art and clears miss markers; invalid bytes preserve it', () async {
      final tmp = await Directory.systemTemp.createTemp('artist_override_');
      addTearDown(() => tmp.delete(recursive: true));
      final art = ArtistArt(tmp);
      final first = [0xFF, 0xD8, ...List.filled(498, 1)];
      final second = [0xFF, 0xD8, ...List.filled(498, 2)];
      await File('${tmp.path}\\u2.none').writeAsString('');
      await art.setFromBytes('U2', first);
      expect(await File('${tmp.path}\\u2.none').exists(), isFalse);
      await art.setFromBytes('U2', second);
      await expectLater(art.setFromBytes('U2', [1, 2, 3]), throwsFormatException);
      final restarted = ArtistArt(tmp);
      expect(await (await restarted.fetch('u2'))!.readAsBytes(), second);
      await art.clear('U2');
      expect(await art.cached('U2'), isNull);
    });

    test('picks the exact name match and ignores blank placeholders', () {
      expect(ArtistArt.pickPicture(jsonDecode(body), 'oasis'), 'https://e-cdns-images.dzcdn.net/oasis.jpg');
      expect(ArtistArt.pickPicture(jsonDecode(body), 'Blur'), isNull);
      expect(
          ArtistArt.pickPicture({
            'data': [
              {'name': 'Blur', 'picture_medium': 'https://e-cdns-images.dzcdn.net/images/artist//250x250.jpg'}
            ]
          }, 'Blur'),
          isNull);
      expect(ArtistArt.pickPicture('nonsense', 'Blur'), isNull);
      expect(
          ArtistArt.pickPicture({
            'data': [
              {'name': 'Blur', 'picture_medium': 'http://evil.example/blur.jpg'}
            ]
          }, 'Blur'),
          isNull);
    });

    test('downloads once, caches on disk, remembers misses', () async {
      final tmp = await Directory.systemTemp.createTemp('artist_art_');
      var calls = 0;
      final net = PoliteHttp(
        defaultGap: Duration.zero,
        client: MockClient((r) async {
          calls++;
          if (r.url.host == 'api.deezer.com') {
            return http.Response(r.url.queryParameters['q'] == 'Oasis' ? body : '{"data":[]}', 200);
          }
          return http.Response.bytes([0xFF, 0xD8, ...List.filled(498, 7)], 200);
        }),
      );
      final art = ArtistArt(tmp, net: net);
      try {
        expect(await art.cached('Oasis'), isNull);
        final f = await art.fetch('Oasis');
        expect(f, isNotNull);
        expect(await f!.length(), 500);
        expect(calls, 2); // search + image
        expect(await art.fetch('oasis'), isNotNull);
        expect(await art.cached('OASIS'), isNotNull);
        expect(calls, 2);

        expect(await art.fetch('Nobody'), isNull);
        expect(calls, 3);
        expect(await art.fetch('Nobody'), isNull); // remembered
        expect(calls, 3);
        expect(await art.fetch('Nobody', force: true), isNull); // forced retry
        expect(calls, 4);
      } finally {
        await tmp.delete(recursive: true);
      }
    });

    test('a network error is not remembered as a miss', () async {
      final tmp = await Directory.systemTemp.createTemp('artist_art_');
      var fail = true;
      final net = PoliteHttp(
        defaultGap: Duration.zero,
        maxRetries: 0,
        client: MockClient((r) async => fail ? http.Response('', 500) : http.Response(body, 200)),
      );
      final art = ArtistArt(tmp, net: net);
      try {
        expect(await art.fetch('Oasis'), isNull);
        expect(await File('${tmp.path}/oasis.none').exists(), isFalse);
        fail = false;
        expect(await art.cached('Oasis'), isNull);
      } finally {
        await tmp.delete(recursive: true);
      }
    });
  });
}

extension on Song {
  Song withAdded(int ms) => Song(
      path: path,
      artist: artist,
      album: album,
      title: title,
      medianBpm: medianBpm,
      fav: fav,
      addedAt: ms);
}
