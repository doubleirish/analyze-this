import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:shared_core/shared_core.dart';

class MbInfo {
  const MbInfo({this.genre, this.year});
  final String? genre;
  final int? year;
}

/// Looks up genre (top community tag) and first release year on MusicBrainz.
/// Pacing (1 request/s) and 429 handling come from [PoliteHttp].
class MusicBrainz {
  MusicBrainz({PoliteHttp? net, http.Client? client}) : net = net ?? PoliteHttp(client: client);

  final PoliteHttp net;
  final Map<String, MbInfo?> _cache = {};

  static const _ua = 'analyze-this/1.0 (personal music library)';

  /// Returns null when nothing matched. Throws on network/HTTP failure.
  /// Repeat lookups of the same artist+title are answered from memory.
  Future<MbInfo?> lookup(String artist, String title, {bool refresh = false}) async {
    final key = '${artist.toLowerCase()}|${title.toLowerCase()}';
    if (!refresh && _cache.containsKey(key)) return _cache[key];
    String esc(String s) => s.replaceAll(RegExp(r'["\\]'), ' ');
    final q = 'recording:"${esc(title)}" AND artist:"${esc(artist)}"';
    final uri = Uri.https('musicbrainz.org', '/ws/2/recording/', {'query': q, 'fmt': 'json', 'limit': '1'});
    final res = await net.get(uri, headers: {'User-Agent': _ua});
    if (res.statusCode != 200) {
      throw http.ClientException('MusicBrainz HTTP ${res.statusCode}', uri);
    }
    return _cache[key] = parse(jsonDecode(res.body) as Map<String, dynamic>);
  }

  static MbInfo? parse(Map<String, dynamic> j) {
    final recs = j['recordings'];
    if (recs is! List || recs.isEmpty) return null;
    final r = recs.first as Map<String, dynamic>;
    if (((r['score'] as num?) ?? 100) < 80) return null;
    int? year;
    final m = RegExp(r'^\d{4}').firstMatch('${r['first-release-date'] ?? ''}');
    if (m != null) year = int.parse(m.group(0)!);
    String? genre;
    final tags = r['tags'];
    if (tags is List && tags.isNotEmpty) {
      final sorted = [...tags.cast<Map<String, dynamic>>()]
        ..sort((a, b) => ((b['count'] as num?) ?? 0).compareTo((a['count'] as num?) ?? 0));
      genre = sorted.first['name'] as String?;
    }
    if (year == null && genre == null) return null;
    return MbInfo(genre: genre, year: year);
  }

  final Map<String, List<MbRelease>> _releaseSearchCache = {};
  final Map<String, MbRelease?> _releaseCache = {};

  Future<Map<String, dynamic>> _getJson(Uri uri) async {
    final res = await net.get(uri, headers: {'User-Agent': _ua});
    if (res.statusCode != 200) {
      throw http.ClientException('MusicBrainz HTTP ${res.statusCode}', uri);
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  /// Release candidates for an album, best first, without tracklists (see
  /// [release]). Either field may be empty.
  Future<List<MbRelease>> searchReleases({String artist = '', String album = '', int limit = 5}) async {
    String esc(String s) => s.replaceAll(RegExp(r'["\\]'), ' ').trim();
    final parts = [
      if (album.trim().isNotEmpty) 'release:"${esc(album)}"',
      if (artist.trim().isNotEmpty) 'artist:"${esc(artist)}"',
    ];
    if (parts.isEmpty) return [];
    final q = parts.join(' AND ');
    final key = '$q|$limit';
    final hit = _releaseSearchCache[key];
    if (hit != null) return hit;
    final uri = Uri.https('musicbrainz.org', '/ws/2/release/', {'query': q, 'fmt': 'json', 'limit': '$limit'});
    return _releaseSearchCache[key] = parseReleaseSearch(await _getJson(uri));
  }

  /// A release with its full tracklist; null when MusicBrainz doesn't know it.
  Future<MbRelease?> release(String id) async {
    if (_releaseCache.containsKey(id)) return _releaseCache[id];
    final uri = Uri.https('musicbrainz.org', '/ws/2/release/$id', {'inc': 'recordings+artist-credits', 'fmt': 'json'});
    return _releaseCache[id] = parseRelease(await _getJson(uri));
  }

  static String _credit(Object? credit) {
    if (credit is! List) return '';
    final b = StringBuffer();
    for (final c in credit.whereType<Map<String, dynamic>>()) {
      b.write(c['name'] ?? (c['artist'] as Map?)?['name'] ?? '');
      b.write(c['joinphrase'] ?? '');
    }
    return b.toString().trim();
  }

  static List<MbRelease> parseReleaseSearch(Map<String, dynamic> j) {
    final rels = j['releases'];
    if (rels is! List) return [];
    return [
      for (final r in rels.whereType<Map<String, dynamic>>())
        if (r['id'] is String && r['title'] is String)
          MbRelease(
            id: r['id'] as String,
            title: r['title'] as String,
            artist: _credit(r['artist-credit']),
            date: r['date'] as String?,
            score: (r['score'] as num?)?.toInt() ?? 0,
          ),
    ];
  }

  /// Parses a release lookup (`inc=recordings+artist-credits`). Tracks of all
  /// discs are returned in order, with [MbTrack.disc] and [MbTrack.position].
  static MbRelease? parseRelease(Map<String, dynamic> j) {
    if (j['id'] is! String || j['title'] is! String) return null;
    final artist = _credit(j['artist-credit']);
    final tracks = <MbTrack>[];
    final media = j['media'];
    if (media is List) {
      for (final m in media.whereType<Map<String, dynamic>>()) {
        final disc = (m['position'] as num?)?.toInt() ?? 1;
        final list = m['tracks'];
        if (list is! List) continue;
        for (final t in list.whereType<Map<String, dynamic>>()) {
          final rec = t['recording'] as Map<String, dynamic>?;
          final title = (t['title'] ?? rec?['title']) as String?;
          if (title == null) continue;
          final credit = _credit(t['artist-credit'] ?? rec?['artist-credit']);
          tracks.add(MbTrack(
            title: title,
            artist: credit.isEmpty ? artist : credit,
            lengthMs: ((t['length'] ?? rec?['length']) as num?)?.toInt(),
            disc: disc,
            position: (t['position'] as num?)?.toInt() ?? tracks.length + 1,
          ));
        }
      }
    }
    return MbRelease(
      id: j['id'] as String,
      title: j['title'] as String,
      artist: artist,
      date: j['date'] as String?,
      score: 100,
      tracks: tracks,
    );
  }
}

class MbTrack {
  const MbTrack({required this.title, required this.artist, this.lengthMs, this.disc = 1, this.position = 1});
  final String title;
  final String artist;
  final int? lengthMs;
  final int disc;
  final int position;
}

class MbRelease {
  const MbRelease(
      {required this.id, required this.title, required this.artist, this.date, this.score = 0, this.tracks = const []});
  final String id;
  final String title;
  final String artist;
  final String? date;

  /// MusicBrainz search score, 0-100.
  final int score;
  final List<MbTrack> tracks;
}
