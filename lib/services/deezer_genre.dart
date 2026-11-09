import 'dart:convert';
import 'dart:io';

import 'package:shared_core/shared_core.dart';
import 'discography.dart' show albumKey;

/// Album genres from Deezer's free public API (no key; about 50 requests per
/// 5 seconds). One search per album, plus a single fetch of Deezer's genre list.
class DeezerGenres {
  DeezerGenres({PoliteHttp? net}) : net = net ?? PoliteHttp();

  final PoliteHttp net;
  Map<int, String>? _names;

  /// Null when Deezer has no matching album. Throws on network failure.
  Future<String?> albumGenre(String artist, String album) async {
    final res = await net.get(Uri.https('api.deezer.com', '/search/album',
        {'q': 'artist:"${_esc(artist)}" album:"${_esc(album)}"', 'limit': '10'}));
    if (res.statusCode != 200) throw HttpException('Deezer HTTP ${res.statusCode}');
    final id = parseGenreId(jsonDecode(res.body), artist, album);
    if (id == null) return null;
    return (await _genreNames())[id];
  }

  static String _esc(String s) => s.replaceAll(RegExp(r'["\\]'), ' ');

  /// `genre_id` of the best matching album in a `/search/album` response; the
  /// first (most relevant) match with a real genre wins.
  static int? parseGenreId(Object? json, String artist, String album) {
    if (json is! Map || json['data'] is! List) return null;
    final wantArtist = ArtistArt.keyFor(artist);
    final wantAlbum = albumKey(album);
    for (final e in json['data'] as List) {
      if (e is! Map || e['artist'] is! Map) continue;
      if (ArtistArt.keyFor('${(e['artist'] as Map)['name']}') != wantArtist) continue;
      if (albumKey('${e['title']}') != wantAlbum) continue;
      final g = e['genre_id'];
      if (g is int && g > 0) return g;
    }
    return null;
  }

  Future<Map<int, String>> _genreNames() async {
    if (_names != null) return _names!;
    final res = await net.get(Uri.https('api.deezer.com', '/genre'));
    if (res.statusCode != 200) throw HttpException('Deezer HTTP ${res.statusCode}');
    return _names = parseGenreList(jsonDecode(res.body));
  }

  static Map<int, String> parseGenreList(Object? json) {
    if (json is! Map || json['data'] is! List) return {};
    return {
      for (final e in json['data'] as List)
        if (e is Map && e['id'] is int && e['name'] is String && e['id'] != 0)
          e['id'] as int: e['name'] as String
    };
  }
}
