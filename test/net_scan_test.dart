import 'dart:convert';
import 'dart:io';

import 'package:analyze_this/services/db.dart';
import 'package:analyze_this/services/deezer_genre.dart';
import 'package:analyze_this/services/musicbrainz.dart';
import 'package:shared_core/shared_core.dart';
import 'package:analyze_this/services/scanner.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _Clock {
  DateTime t = DateTime.utc(2026, 1, 1);
  final sleeps = <Duration>[];
  DateTime now() => t;
  Future<void> sleep(Duration d) async {
    sleeps.add(d);
    t = t.add(d);
  }
}

void main() {
  test('Deezer album genre: matches artist and title, maps genre_id to a name', () async {
    final paths = <String>[];
    final net = PoliteHttp(
      client: MockClient((r) async {
        paths.add(r.url.path);
        if (r.url.path == '/genre') {
          return http.Response(
              jsonEncode({'data': [{'id': 0, 'name': 'All'}, {'id': 152, 'name': 'Rock'}]}), 200);
        }
        return http.Response(
            jsonEncode({
              'data': [
                {'title': 'Other', 'genre_id': 132, 'artist': {'name': 'Band'}},
                {'title': 'Album (Deluxe)', 'genre_id': 152, 'artist': {'name': 'Band'}},
              ]
            }),
            200);
      }),
      sleep: (_) async {},
    );
    final d = DeezerGenres(net: net);
    expect(await d.albumGenre('Band', 'Album'), 'Rock');
    expect(await d.albumGenre('Nobody', 'Album'), isNull);
    expect(paths.where((p) => p == '/genre'), hasLength(1));
  });
  test('retries after 429 using Retry-After and widens the gap', () async {
    final c = _Clock();
    var calls = 0;
    final net = PoliteHttp(
      client: MockClient((r) async =>
          ++calls == 1 ? http.Response('', 429, headers: {'retry-after': '7'}) : http.Response('ok', 200)),
      sleep: c.sleep,
      now: c.now,
    );
    final res = await net.get(Uri.https('api.example.com', '/x'));
    expect(res.body, 'ok');
    expect(calls, 2);
    expect(c.sleeps.any((d) => d >= const Duration(seconds: 6)), isTrue);
    expect(net.throttled, 1);
    expect(net.gapFor('api.example.com'), const Duration(milliseconds: 1000));
  });

  test('retry-after accepts seconds, HTTP dates and ignores junk', () {
    final now = DateTime.utc(2026, 1, 1, 0, 0, 0);
    expect(PoliteHttp.retryAfter('12', now), const Duration(seconds: 12));
    expect(PoliteHttp.retryAfter('Thu, 01 Jan 2026 00:00:30 GMT', now), const Duration(seconds: 30));
    expect(PoliteHttp.retryAfter('soon', now), isNull);
    expect(PoliteHttp.retryAfter(null, now), isNull);
  });

  test('spaces requests per host but not across hosts', () async {
    final c = _Clock();
    final net = PoliteHttp(
      client: MockClient((r) async => http.Response('ok', 200)),
      gaps: {'slow.test': const Duration(seconds: 1)},
      defaultGap: const Duration(milliseconds: 100),
      sleep: c.sleep,
      now: c.now,
    );
    await Future.wait([
      for (var i = 0; i < 3; i++) net.get(Uri.https('slow.test', '/$i')),
      net.get(Uri.https('other.test', '/a')),
    ]);
    // slow.test: 2nd waits 1 s, 3rd waits 2 s; other.test never waits
    expect(c.sleeps.where((d) => d >= const Duration(seconds: 1)), hasLength(2));
    expect(c.sleeps.every((d) => d <= const Duration(seconds: 2)), isTrue);
  });

  test('persistent 429 cools the host down and fails fast', () async {
    final c = _Clock();
    var calls = 0;
    final net = PoliteHttp(
      client: MockClient((r) async {
        calls++;
        return http.Response('', 429);
      }),
      maxRetries: 2,
      sleep: c.sleep,
      now: c.now,
    );
    final u = Uri.https('busy.test', '/');
    await expectLater(net.get(u), throwsA(isA<http.ClientException>()));
    expect(calls, 3);
    await expectLater(net.get(u), throwsA(isA<http.ClientException>()));
    expect(calls, 3);
    c.t = c.t.add(const Duration(minutes: 2));
    await expectLater(net.get(u), throwsA(isA<http.ClientException>()));
    expect(calls, 6);
  });

  test('OpStat eta and overall ETA use the slowest operation', () {
    expect(const OpStat(10, 10, 0).eta, Duration.zero);
    expect(const OpStat(0, 100, 0).eta, isNull);
    expect(const OpStat(50, 100, 2).eta, const Duration(seconds: 25));
    // preloaded items finish instantly, so only pending work counts
    expect(const OpStat(50, 100, 2, pending: 10).eta, const Duration(seconds: 5));
    expect(const OpStat(50, 100, 0, pending: 0).eta, Duration.zero);
    const p = ScanProgress(5, 10, '',
        analyze: OpStat(5, 10, 1), lyrics: OpStat(2, 12, 0.5), genre: OpStat(0, 0, 0));
    expect(p.eta, const Duration(seconds: 20));
    const unknown = ScanProgress(5, 10, '', analyze: OpStat(5, 10, 0));
    expect(unknown.eta, isNull);
  });

  test('scan reports per-operation progress', () async {
    final tmp = await Directory.systemTemp.createTemp('analyze_this_scan_');
    final db = await MusicDb.open(':memory:');
    try {
      final sub = await Directory('${tmp.path}${Platform.pathSeparator}more').create();
      for (final dir in [tmp.path, sub.path]) {
        await File('$dir${Platform.pathSeparator}Europe - The Final Countdown.mp3')
            .writeAsBytes(List.filled(100, 1));
      }
      for (var i = 0; i < 4; i++) {
        await File('${tmp.path}${Platform.pathSeparator}Band - Song $i.mp3')
            .writeAsBytes(List.filled(100, 1));
      }
      var calls = 0;
      final c = _Clock();
      final net = PoliteHttp(
        client: MockClient((r) async {
          calls++;
          return http.Response(
              jsonEncode({
                'recordings': [
                  {
                    'score': 100,
                    'first-release-date': '1986-05-26',
                    'tags': [
                      {'name': 'rock', 'count': 3}
                    ]
                  }
                ]
              }),
              200);
        }),
        sleep: c.sleep,
        now: c.now,
      );
      final scanner = Scanner(db, net: net, musicBrainz: MusicBrainz(net: net));
      ScanProgress? last;
      final errors = await scanner.scanAll([tmp.path],
          options: const ScanOptions(
              analyzeBpm: false, fetchLyrics: false, lookupMusicBrainz: true),
          onProgress: (p) => last = p);
      expect(errors, isEmpty);
      expect(calls, lessThanOrEqualTo(5));
      expect(last!.onlineDone, last!.onlineTotal);
      expect(last!.analyze.done, 6);
      // counted in lookups: both Final Countdown copies share one
      expect(last!.genre.done, 5);
      expect(last!.genre.total, 5);
      expect(last!.eta, Duration.zero);
      final songs = await db.search(const SongQuery(genre: 'rock'));
      expect(songs, hasLength(6));
      expect(songs.every((s) => s.year == null), isTrue);
      // unchanged files are not looked up again
      calls = 0;
      await scanner.scanAll([tmp.path],
          options: const ScanOptions(
              analyzeBpm: false, fetchLyrics: false, lookupMusicBrainz: true));
      expect(calls, 0);
    } finally {
      await db.close();
      await tmp.delete(recursive: true);
    }
  });

  test('quick scan stores tags only, keeps existing rows, and U2 is findable', () async {
    final tmp = await Directory.systemTemp.createTemp('analyze_this_quick_');
    final db = await MusicDb.open(':memory:');
    try {
      for (final n in ['U2 - One', 'U2 - With Or Without You', 'Blur - Parklife']) {
        await File('${tmp.path}${Platform.pathSeparator}$n.mp3').writeAsBytes(List.filled(100, 1));
      }
      final scanner = Scanner(db);
      expect(await scanner.quickScan([tmp.path]), isEmpty);
      final u2 = await db.search(const SongQuery(artist: 'U2'));
      expect(u2, hasLength(2));
      expect(u2.every((s) => s.medianBpm == null && !s.lyricsChecked), isTrue);
      expect((await db.artists()).map((a) => a.name), containsAll(['U2', 'Blur']));

      await db.setFav(u2.first.path, true);
      await scanner.quickScan([tmp.path]);
      expect((await db.song(u2.first.path))!.fav, isTrue);
      expect(await db.songCount(), 3);

      await File('${tmp.path}${Platform.pathSeparator}Blur - Parklife.mp3').delete();
      await scanner.quickScan([tmp.path]);
      expect(await db.songCount(), 2);
    } finally {      await db.close();
      await tmp.delete(recursive: true);
    }
  });
}
