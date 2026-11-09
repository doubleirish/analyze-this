import 'package:analyze_this/services/album_catalog.dart';
import 'package:analyze_this/services/db.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_core/shared_core.dart';

Song track(
  int n, {
  String root = r'D:\music',
  String album = 'Album',
  String artist = 'Band',
  int? total,
  int? disc,
  int? discTotal,
}) => Song(
  path: '$root\\$artist\\$album\\CD${disc ?? 1}\\$n.mp3',
  artist: artist,
  album: album,
  title: 'Track $n',
  trackNo: n,
  trackTotal: total,
  discNo: disc,
  discTotal: discTotal,
);

void main() {
  test('includes healthy, incomplete and unknown albums, skips untagged songs', () {
    final catalog = buildAlbumCatalog([
      track(1, total: 2),
      track(2, total: 2),
      track(1, album: 'Incomplete', total: 3),
      track(3, album: 'Incomplete', total: 3),
      track(1, album: 'Unknown'),
      Song(path: r'D:\music\untagged.mp3'),
    ]);
    expect(catalog.albums.length, 3);
    final complete = catalog.search('band album').single;
    expect((complete.have, complete.total, complete.incomplete), (2, 2, false));
    final missing = catalog.search('incomplete').single;
    expect((missing.have, missing.total, missing.incomplete), (2, 3, true));
    expect(catalog.search('unknown').single.total, isNull);
    expect(AlbumCatalog.decode(catalog.encode()).albums.length, 3);
  });

  test('counts distinct tracks across roots without copies hiding missing tracks', () {
    final c = buildAlbumCatalog([
      track(1, total: 3),
      track(1, root: r'E:\archive', total: 3),
      track(2, root: r'E:\archive', total: 3),
    ]).albums.single;
    expect((c.have, c.total, c.incomplete), (2, 3, true));
    final merged = buildAlbumCatalog([track(1, total: 2), track(2, root: r'E:\archive', total: 2)])
        .albums
        .single;
    expect((merged.have, merged.total, merged.incomplete), (2, 2, false));
  });

  test('multi-disc totals are summed; missing discs remain incomplete with unknown total', () {
    final perDisc = [
      for (final d in [1, 2])
        for (final n in [1, 2]) track(n, disc: d, total: 2, discTotal: 2),
    ];
    final c = buildAlbumCatalog(perDisc).albums.single;
    expect((c.have, c.total, c.incomplete), (4, 4, false));
    final missingDisc = buildAlbumCatalog(perDisc.where((s) => s.discNo == 1)).albums.single;
    expect((missingDisc.have, missingDisc.total, missingDisc.incomplete), (2, null, true));
    final continuous = buildAlbumCatalog([
      for (final n in [1, 2, 3, 4]) track(n, disc: n <= 2 ? 1 : 2, total: 4, discTotal: 2),
    ]).albums.single;
    expect((continuous.have, continuous.total, continuous.incomplete), (4, 4, false));
  });

  test('track gaps work without totals; absent tags do not invent completeness', () {
    final missing = buildAlbumCatalog([track(1), track(3)]).albums.single;
    expect((missing.have, missing.total, missing.incomplete), (2, null, true));
    final mixed = buildAlbumCatalog([
      track(1, total: 3),
      Song(path: r'D:\music\Band\Album\un.mp3', album: 'Album', artist: 'Band', title: 'Other'),
    ]).albums.single;
    expect((mixed.have, mixed.total, mixed.incomplete), (2, 3, true));
  });

  test('same-name artists and editions are separate, compilation artist is shared', () {
    final c = buildAlbumCatalog([
      track(1),
      track(1, artist: 'Other'),
      track(1, album: 'Album (Deluxe)', total: 2),
      for (var n = 1; n <= 4; n++)
        Song(
          path: 'D:\\music\\Compilation\\$n.mp3',
          artist: 'Singer $n',
          album: 'Compilation',
          trackNo: n,
          trackTotal: 4,
        ),
    ]);
    expect(c.albums.length, 4);
    expect(c.search('deluxe').single.incomplete, isTrue);
    expect(c.search('compilation').single.artist, 'Various artists');
  });

  test('lightweight database query includes albums from every root and preserves tags', () async {
    final db = await MusicDb.open(':memory:');
    addTearDown(db.close);
    await db.upsertSong(track(1, total: 3));
    await db.upsertSong(track(3, root: r'E:\archive', total: 3));
    await db.upsertSong(Song(path: r'D:\music\no_album.mp3'));
    final songs = await db.albumCatalogSongs();
    expect(songs.length, 2);
    expect(buildAlbumCatalog(songs).albums.single.incomplete, isTrue);
  });
}
