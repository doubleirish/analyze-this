import 'dart:convert';
import 'dart:io';

import 'package:shared_core/shared_core.dart';

import 'db.dart';

/// How many songs a best-of album holds.
const bestOfSize = 20;

/// "Creep - Remastered 2009", "Creep (Live)" and "Creep" all compare equal.
String titleKey(String? title) {
  var t = (title ?? '').toLowerCase();
  t = t.replaceAll(RegExp(r'[\(\[][^\)\]]*[\)\]]'), ' ');
  t = t.replaceAll(RegExp(r'\s[-–]\s.*$'), '');
  return t.replaceAll(RegExp(r'[^a-z0-9]'), '');
}

/// A Deezer track: title and popularity (higher is more popular).
class RankedTrack {
  const RankedTrack(this.title, this.rank);
  final String title;
  final int rank;
}

class BestOfPick {
  const BestOfPick(this.songs, this.matched);

  /// Most popular first.
  final List<Song> songs;

  /// How many came from the popularity list; the rest are filled from ratings.
  final int matched;
}

/// Picks up to [size] of [songs] for the artist's best-of: songs whose title is on
/// the popularity list come first (most popular first, one file per title), then
/// the rest by favourite and rating.
BestOfPick pickBestOf(List<Song> songs, List<RankedTrack> ranked, {int size = bestOfSize}) {
  int better(Song a, Song b) {
    final c = (b.fav ? 1 : 0) - (a.fav ? 1 : 0);
    if (c != 0) return c;
    final r = b.rating - a.rating;
    return r != 0 ? r : b.size - a.size;
  }

  final byTitle = <String, List<Song>>{};
  for (final s in songs) {
    final k = titleKey(s.title);
    if (k.isNotEmpty) byTitle.putIfAbsent(k, () => []).add(s);
  }
  final out = <Song>[];
  final used = <String>{};
  final order = [...ranked]..sort((a, b) => b.rank.compareTo(a.rank));
  for (final t in order) {
    if (out.length >= size) break;
    final k = titleKey(t.title);
    final hits = byTitle[k];
    if (hits == null || !used.add(k)) continue;
    out.add(([...hits]..sort(better)).first);
  }
  final matched = out.length;
  final rest = songs.where((s) {
    final k = titleKey(s.title);
    return k.isNotEmpty && !used.contains(k);
  }).toList()
    ..sort(better);
  for (final s in rest) {
    if (out.length >= size) break;
    if (used.add(titleKey(s.title))) out.add(s);
  }
  return BestOfPick(out, matched);
}

/// Artist popularity from Deezer's free public API (no key).
class DeezerPopularity {
  DeezerPopularity({PoliteHttp? net}) : net = net ?? PoliteHttp();
  final PoliteHttp net;

  /// Null when Deezer doesn't know the artist; throws on network failure.
  Future<List<RankedTrack>?> topTracks(String artist) async {
    final res = await net.get(Uri.https('api.deezer.com', '/search/artist',
        {'q': artist.replaceAll(RegExp(r'["\\]'), ' '), 'limit': '10'}));
    if (res.statusCode != 200) throw HttpException('Deezer HTTP ${res.statusCode}');
    final id = parseArtistId(jsonDecode(res.body), artist);
    if (id == null) return null;
    final top = await net.get(Uri.https('api.deezer.com', '/artist/$id/top', {'limit': '100'}));
    if (top.statusCode != 200) throw HttpException('Deezer HTTP ${top.statusCode}');
    return parseTop(jsonDecode(top.body));
  }

  /// First search hit whose name matches [artist] (ignoring case and spacing).
  static int? parseArtistId(Object? json, String artist) {
    if (json is! Map || json['data'] is! List) return null;
    final want = ArtistArt.keyFor(artist);
    for (final e in json['data'] as List) {
      if (e is Map && e['id'] is int && ArtistArt.keyFor('${e['name']}') == want) {
        return e['id'] as int;
      }
    }
    return null;
  }

  static List<RankedTrack> parseTop(Object? json) {
    if (json is! Map || json['data'] is! List) return [];
    return [
      for (final e in json['data'] as List)
        if (e is Map && e['title'] is String)
          RankedTrack(e['title'] as String, (e['rank'] as num?)?.toInt() ?? 0)
    ];
  }
}
