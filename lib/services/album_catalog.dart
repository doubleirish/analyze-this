import 'package:shared_core/shared_core.dart';

import 'album_health.dart';
import 'db.dart';

/// Include every tagged album, not just the problematic ones checkAlbums returns.
/// Merge copies across roots by artist + full title, keeping editions distinct.
AlbumCatalog buildAlbumCatalog(Iterable<Song> songs, {DateTime? generatedAt}) {
  final groups = <String, List<Song>>{};
  final artists = <String, String>{};
  final folders = <String, List<Song>>{};
  for (final s in songs) {
    final title = (s.album ?? '').trim();
    if (title.isEmpty) continue;
    final key = '${normalizeCatalogText(title)}|${albumFolder(s.path)}';
    folders.putIfAbsent(key, () => []).add(s);
  }
  for (final list in folders.values) {
    final artist = albumArtist(list);
    for (final s in list) {
      final title = s.album!.trim();
      final key = '${normalizeCatalogText(artist)}|${normalizeCatalogText(title)}';
      groups.putIfAbsent(key, () => []).add(s);
      artists[key] = artist;
    }
  }
  final albums = <CatalogAlbum>[];
  for (final e in groups.entries) {
    final coverage = albumTrackCoverage(e.value);
    albums.add(
      CatalogAlbum(
        key: e.key,
        artist: artists[e.key]!,
        album: e.value.first.album!.trim(),
        have: coverage.have,
        total: coverage.total,
        incomplete: coverage.incomplete,
      ),
    );
  }
  albums.sort((a, b) => a.key.compareTo(b.key));
  return AlbumCatalog(generatedAt: generatedAt ?? DateTime.now(), albums: albums);
}
