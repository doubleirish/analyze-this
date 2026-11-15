import 'dart:convert';
import 'dart:io';

import 'package:shared_core/shared_core.dart' show PoliteHttp;

import 'discography.dart';
import 'song_models.dart';
import 'wishlist_match.dart';
import 'wishlist_parse.dart';

class OriginAlbum {
  const OriginAlbum(this.title, this.date, this.type);
  final String title;
  final String? date;
  final String type;

  Song? libraryAlbum(String artist, Iterable<Song> songs) {
    final artistKey = wishArtistKey(artist);
    final key = albumKey(title);
    if (artistKey.isEmpty || key.isEmpty) return null;
    for (final song in songs) {
      if (wishArtistKey(song.artist) == artistKey &&
          albumKey(song.album ?? '') == key) {
        return song;
      }
    }
    return null;
  }

  bool inLibrary(String artist, Iterable<Song> songs) =>
      libraryAlbum(artist, songs) != null;
}

class TrackOrigin {
  TrackOrigin(this.cacheFile, {required this.net});
  final File cacheFile;
  final PoliteHttp net;
  Map<String, dynamic>? _cache;

  Future<Object?> _get(Uri uri) async {
    final response = await net.get(uri);
    if (response.statusCode != 200) {
      throw HttpException('Deezer HTTP ${response.statusCode}', uri: uri);
    }
    final json = jsonDecode(response.body);
    if (json is Map && json['error'] != null) {
      throw HttpException('Deezer: ${json['error']}', uri: uri);
    }
    return json;
  }

  Future<OriginAlbum?> lookup(
    WishEntry entry, {
    bool Function()? cancelled,
    bool retryMissing = false,
  }) async {
    void checkCancelled() {
      if (cancelled?.call() ?? false) throw const LookupCancelled();
    }

    checkCancelled();
    final artist = entry.artist;
    if (artist == null || artist.trim().isEmpty) return null;
    final key = jsonEncode([
      artist.toLowerCase(),
      entry.title.toLowerCase(),
      entry.album?.toLowerCase(),
    ]);
    if (_cache == null) {
      if (await cacheFile.exists()) {
        final content = jsonDecode(await cacheFile.readAsString());
        if (content is! Map<String, dynamic>) {
          throw const FormatException('Invalid album lookup cache');
        }
        _cache = content;
      } else {
        _cache = {};
      }
    }
    final hit = _cache![key];
    if (hit is Map &&
        hit['at'] is int &&
        DateTime.now().millisecondsSinceEpoch - (hit['at'] as int) <
            const Duration(days: 30).inMilliseconds) {
      final value = hit['album'];
      if (value == null && hit['version'] == 2 && !retryMissing) return null;
      if (value is Map && value['title'] is String && value['type'] is String) {
        return OriginAlbum(
          value['title'] as String,
          value['date'] as String?,
          value['type'] as String,
        );
      }
      if (value != null) throw const FormatException('Invalid cached album');
    }
    String esc(String s) => s.replaceAll(RegExp(r'["\\]'), ' ');
    final query = 'artist:"${esc(artist)}" track:"${esc(entry.title)}"';
    final data = await _get(
      Uri.https('api.deezer.com', '/search/track', {
        'q': query,
        'limit': '100',
      }),
    );
    checkCancelled();
    var ids = matchingAlbumIds(data, entry);
    if (ids.isEmpty) {
      final fallback = await _get(
        Uri.https('api.deezer.com', '/search/track', {
          'q': '${esc(artist)} ${esc(entry.title)}',
          'limit': '100',
        }),
      );
      checkCancelled();
      ids = matchingAlbumIds(fallback, entry);
    }
    final albums = <OriginAlbum>[];
    for (final id in ids) {
      checkCancelled();
      final data = await _get(Uri.https('api.deezer.com', '/album/$id'));
      checkCancelled();
      if (data is! Map ||
          data['title'] is! String ||
          data['record_type'] is! String) {
        throw const FormatException('Invalid Deezer album response');
      }
      albums.add(
        OriginAlbum(
          data['title'] as String,
          data['release_date'] as String?,
          (data['record_type'] as String).toLowerCase(),
        ),
      );
    }
    final result = chooseOrigin(albums, hint: entry.album);
    final updated = {
      ..._cache!,
      key: {
        'at': DateTime.now().millisecondsSinceEpoch,
        'version': 2,
        'album': result == null
            ? null
            : {'title': result.title, 'date': result.date, 'type': result.type},
      },
    };
    await cacheFile.parent.create(recursive: true);
    await cacheFile.writeAsString(jsonEncode(updated));
    _cache = updated;
    return result;
  }
}

class LookupCancelled implements Exception {
  const LookupCancelled();
}

/// Require the same artist and recording, allowing only remaster labels.
/// The first search result can otherwise be a cover, live version or remix.
List<int> matchingAlbumIds(Object? data, WishEntry entry) {
  if (data is! Map || data['data'] is! List) {
    throw const FormatException('Invalid Deezer search response');
  }
  final ids = <int>{};
  String recordingTitle(String title) => title.replaceFirst(
    RegExp(
      r'\s*(?:\((?:\d{4}\s+)?remaster(?:ed)?(?:\s+\d{4})?\)|-\s*(?:\d{4}\s+)?remaster(?:ed)?(?:\s+\d{4})?)\s*$',
      caseSensitive: false,
    ),
    '',
  );
  final want = dupKeyFor(entry.artist, recordingTitle(entry.title));
  if (want.split('|').first.isEmpty) return [];
  for (final row in data['data'] as List) {
    if (row is! Map || row['artist'] is! Map || row['album'] is! Map) continue;
    final artist = (row['artist'] as Map)['name'];
    final album = (row['album'] as Map)['id'];
    if (artist is String &&
        row['title'] is String &&
        album is int &&
        dupKeyFor(artist, recordingTitle(row['title'] as String)) == want) {
      ids.add(album);
    }
  }
  return ids.toList();
}

OriginAlbum? chooseOrigin(List<OriginAlbum> albums, {String? hint}) {
  if (albums.isEmpty) return null;
  int rank(OriginAlbum a) {
    if (hint != null && albumKey(a.title) == albumKey(hint)) return -1;
    if (RegExp(
      r'\b(live|greatest hits|best of|soundtrack|compilation)\b',
      caseSensitive: false,
    ).hasMatch(a.title)) {
      return 3;
    }
    return switch (a.type) {
      'album' || 'ep' => 0,
      'single' => 1,
      _ => 2,
    };
  }

  final sorted = [...albums]
    ..sort((a, b) {
      final r = rank(a).compareTo(rank(b));
      if (r != 0) return r;
      final ad = a.date;
      final bd = b.date;
      final aValid =
          ad != null &&
          RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(ad) &&
          !ad.startsWith('0000');
      final bValid =
          bd != null &&
          RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(bd) &&
          !bd.startsWith('0000');
      if (aValid && bValid) return ad.compareTo(bd);
      if (aValid != bValid) return aValid ? -1 : 1;
      return a.title.compareTo(b.title);
    });
  return sorted.first;
}
