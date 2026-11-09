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
}
