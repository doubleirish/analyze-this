import 'dart:convert';
import 'dart:io';

import 'package:shared_core/shared_core.dart';

class AlbumRelease {
  const AlbumRelease(this.title, this.date, this.type, this.coverUrl);
  final String title;

  /// yyyy-mm-dd as given by Deezer; null when unknown.
  final String? date;
  final String type;
  final String? coverUrl;

  int? get year => date == null ? null : int.tryParse(date!.substring(0, 4));

  Map<String, Object?> toJson() => {'title': title, 'date': date, 'type': type, 'cover': coverUrl};

  static AlbumRelease fromJson(Map<String, dynamic> j) => AlbumRelease(
      j['title'] as String, j['date'] as String?, j['type'] as String, j['cover'] as String?);
}

/// Normalised album title: drops edition/remaster suffixes so "Album (Deluxe)"
/// matches "Album".
String albumKey(String title) {
  var t = title.toLowerCase();
  t = t.replaceAll(RegExp(r'[\(\[][^\)\]]*[\)\]]'), ' ');
  t = t.replaceAll(
      RegExp(r'\s[-–:]\s*(.*(remaster|deluxe|edition|expanded|anniversary|bonus|version|mono|stereo).*)$'),
      ' ');
  t = t.replaceAll('&', ' and ').replaceAll(RegExp(r"[^a-z0-9]+"), ' ').trim();
  return t.replaceFirst(RegExp(r'^the '), '');
}

/// Releases the artist has that none of [owned] album titles match, oldest
/// first (undated last), one per normalised title.
List<AlbumRelease> missingAlbums(List<AlbumRelease> releases, Iterable<String> owned) {
  final have = {for (final o in owned) albumKey(o)};
  final byKey = <String, AlbumRelease>{};
  for (final r in releases) {
    final k = albumKey(r.title);
    if (k.isEmpty || have.contains(k)) continue;
    final old = byKey[k];
    if (old == null || _cmp(r, old) < 0) byKey[k] = r;
  }
  return byKey.values.toList()..sort(_cmp);
}

int _cmp(AlbumRelease a, AlbumRelease b) {
  if (a.date == null || b.date == null) {
    return a.date == b.date ? a.title.compareTo(b.title) : (a.date == null ? 1 : -1);
  }
  final c = a.date!.compareTo(b.date!);
  return c != 0 ? c : a.title.compareTo(b.title);
}

/// Artist discographies from Deezer, cached on disk for [maxAge], and
/// album covers cached as image files.
class Discography {
  Discography(this.dir, {PoliteHttp? net, this.maxAge = const Duration(days: 30), DateTime Function()? now})
      : net = net ?? PoliteHttp(),
        _now = now ?? DateTime.now;

  final Directory dir;
  final PoliteHttp net;
  final Duration maxAge;
  final DateTime Function() _now;
  final Map<String, Future<List<AlbumRelease>?>> _pending = {};

  File _json(String artist) =>
      File('${dir.path}${Platform.pathSeparator}${ArtistArt.keyFor(artist)}.json');

  /// Null when Deezer has no matching artist. Throws on network failure
  /// (nothing is cached then, so the next call retries).
  Future<List<AlbumRelease>?> releases(String artist) =>
      _pending.putIfAbsent(artist.toLowerCase().trim(), () async {
        try {
          return await _releases(artist);
        } finally {
          _pending.remove(artist.toLowerCase().trim());
        }
      });

  Future<List<AlbumRelease>?> _releases(String artist) async {
    final f = _json(artist);
    if (await f.exists()) {
      try {
        final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        final at = DateTime.fromMillisecondsSinceEpoch(j['at'] as int);
        if (_now().difference(at) < maxAge) {
          final l = j['releases'] as List?;
          return l == null
              ? null
              : [for (final e in l) AlbumRelease.fromJson(e as Map<String, dynamic>)];
        }
      } catch (_) {}
    }
    final id = await _artistId(artist);
    List<AlbumRelease>? out;
    if (id != null) {
      final res = await net.get(
          Uri.https('api.deezer.com', '/artist/$id/albums', {'limit': '200'}));
      if (res.statusCode != 200) throw HttpException('Deezer HTTP ${res.statusCode}');
      out = parseAlbums(jsonDecode(res.body));
    }
    await dir.create(recursive: true);
    await f.writeAsString(jsonEncode({
      'at': _now().millisecondsSinceEpoch,
      'releases': out == null ? null : [for (final r in out) r.toJson()],
    }));
    return out;
  }

  Future<int?> _artistId(String artist) async {
    final res = await net.get(
        Uri.https('api.deezer.com', '/search/artist', {'q': artist, 'limit': '5'}));
    if (res.statusCode != 200) throw HttpException('Deezer HTTP ${res.statusCode}');
    final j = jsonDecode(res.body);
    if (j is! Map || j['data'] is! List) return null;
    final want = ArtistArt.keyFor(artist);
    for (final e in j['data'] as List) {
      if (e is Map && ArtistArt.keyFor('${e['name']}') == want && e['id'] is int) {
        return e['id'] as int;
      }
    }
    return null;
  }

  /// Albums and EPs from a Deezer `/artist/{id}/albums` response.
  static List<AlbumRelease> parseAlbums(Object? json) {
    if (json is! Map || json['data'] is! List) return [];
    final out = <AlbumRelease>[];
    for (final e in json['data'] as List) {
      if (e is! Map) continue;
      final type = '${e['record_type'] ?? ''}'.toLowerCase();
      if (type != 'album' && type != 'ep') continue;
      final title = '${e['title'] ?? ''}'.trim();
      if (title.isEmpty) continue;
      final d = '${e['release_date'] ?? ''}';
      final cover = [e['cover_medium'], e['cover_big'], e['cover']]
          .whereType<String>()
          .where((u) => u.startsWith('http'))
          .firstOrNull;
      out.add(AlbumRelease(title, RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(d) && !d.startsWith('0000') ? d : null,
          type, cover));
    }
    return out;
  }

  /// Fewest tracks among the Deezer editions of [album] by [artist] (the
  /// standard edition is the shortest). Null when nothing matches. Throws on
  /// network failure; results are cached on disk for [maxAge].
  Future<int?> trackCount(String artist, String album) async {
    final key = '${ArtistArt.keyFor(artist)}__${albumKey(album)}';
    final f = File('${dir.path}${Platform.pathSeparator}track_counts.json');
    var cache = <String, dynamic>{};
    try {
      cache = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    } catch (_) {}
    final hit = cache[key];
    if (hit is Map) {
      final at = DateTime.fromMillisecondsSinceEpoch(hit['at'] as int);
      if (_now().difference(at) < maxAge) return hit['n'] as int?;
    }
    final res = await net.get(Uri.https('api.deezer.com', '/search/album',
        {'q': 'artist:"$artist" album:"$album"', 'limit': '25'}));
    if (res.statusCode != 200) throw HttpException('Deezer HTTP ${res.statusCode}');
    final n = parseTrackCount(jsonDecode(res.body), artist, album);
    cache[key] = {'at': _now().millisecondsSinceEpoch, 'n': n};
    await dir.create(recursive: true);
    await f.writeAsString(jsonEncode(cache));
    return n;
  }

  /// Smallest `nb_tracks` of a `/search/album` result whose artist and title match.
  static int? parseTrackCount(Object? json, String artist, String album) {
    if (json is! Map || json['data'] is! List) return null;
    final wantArtist = ArtistArt.keyFor(artist);
    final wantAlbum = albumKey(album);
    int? best;
    for (final e in json['data'] as List) {
      if (e is! Map) continue;
      final a = e['artist'];
      final n = e['nb_tracks'];
      if (a is! Map || n is! int || n <= 0) continue;
      if (ArtistArt.keyFor('${a['name']}') != wantArtist) continue;
      if (albumKey('${e['title']}') != wantAlbum) continue;
      if (best == null || n < best) best = n;
    }
    return best;
  }

  File _coverFile(String artist, String title) => File(
      '${dir.path}${Platform.pathSeparator}covers${Platform.pathSeparator}'
      '${ArtistArt.keyFor(artist)}__${ArtistArt.keyFor(albumKey(title))}.jpg');

  /// Cover image for a release; downloads once. Null if unavailable.
  Future<File?> cover(String artist, AlbumRelease r) async {
    final f = _coverFile(artist, r.title);
    if (await f.exists()) return f;
    if (r.coverUrl == null) return null;
    try {
      final res = await net.get(Uri.parse(r.coverUrl!));
      if (res.statusCode != 200 || res.bodyBytes.length < 200) return null;
      await f.parent.create(recursive: true);
      await f.writeAsBytes(res.bodyBytes);
      return f;
    } catch (_) {
      return null;
    }
  }
}
