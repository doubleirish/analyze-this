import 'package:analyze_this/services/app_state.dart';
import 'package:analyze_this/services/best_of.dart';
import 'package:analyze_this/services/db.dart';
import 'package:flutter_test/flutter_test.dart';

Song _s(String t, {String artist = 'Radiohead', int rating = 0, int size = 1}) =>
    Song(path: 'C:\\m\\$artist\\$t$size.mp3', title: t, artist: artist, rating: rating, size: size);

void main() {
  group('pickBestOf', () {
    test('popular songs first, matching through remaster/live suffixes, one file per title', () {
      final songs = [
        _s('Creep - Remastered 2009'),
        _s('Creep', size: 9),
        _s('Karma Police'),
        _s('Obscure B-side', rating: 5),
        _s('No Surprises'),
      ];
      final pick = pickBestOf(songs, const [
        RankedTrack('Karma Police', 900),
        RankedTrack('Creep', 1000),
        RankedTrack('Not In Library', 5000),
      ]);
      expect([for (final s in pick.songs) titleKey(s.title)],
          ['creep', 'karmapolice', 'obscurebside', 'nosurprises']);
      expect(pick.matched, 2);
      expect(pick.songs.first.size, 9);
    });

    test('caps at size and works without a popularity list', () {
      final songs = [for (var i = 0; i < 30; i++) _s('t$i', rating: i % 6)];
      final pick = pickBestOf(songs, const [], size: 20);
      expect(pick.songs.length, 20);
      expect(pick.matched, 0);
      expect(pick.songs.first.rating, 5);
    });
  });

  test('parses Deezer responses', () {
    expect(
        DeezerPopularity.parseArtistId({
          'data': [
            {'id': 1, 'name': 'Radio Philharmonic'},
            {'id': 2, 'name': 'Radiohead'}
          ]
        }, 'radiohead'),
        2);
    final top = DeezerPopularity.parseTop({
      'data': [
        {'title': 'Creep', 'rank': 900000}
      ]
    });
    expect(top.single.title, 'Creep');
    expect(top.single.rank, 900000);
  });

  test('best-of albums are stored in order, listed, and drop deleted songs', () async {
    final db = await MusicDb.open(':memory:');
    final st = AppState(db);
    final songs = [for (final t in ['a', 'b', 'c']) _s(t)];
    for (final s in songs) {
      await db.upsertSong(s);
    }
    await db.saveBestOf('Radiohead', [songs[2].path, songs[0].path]);

    final albums = await db.bestOfAlbums();
    expect(albums.single.album, bestOfTitle('Radiohead'));
    expect(albums.single.songs, 2);
    final tracks = await db.albumSongs(bestOfTitle('Radiohead'), 'Radiohead');
    expect([for (final s in tracks) s.title], ['c', 'a']);

    await db.deleteSongs([songs[2].path]);
    expect([for (final s in await db.bestOfSongs('Radiohead')) s.title], ['a']);
    expect(st.bestOfProgress, isNull);
    await db.close();
  });
}
