import 'dart:convert';
import 'dart:io';

import 'package:analyze_this/screens/wishlist_view.dart';
import 'package:analyze_this/screens/mix_screen.dart';
import 'package:analyze_this/screens/mix_add.dart' show DamagedBadge;
import 'package:analyze_this/services/app_state.dart';
import 'package:analyze_this/services/db.dart';
import 'package:analyze_this/services/mix_controller.dart';
import 'package:analyze_this/services/track_origin.dart';
import 'package:analyze_this/services/wishlist_match.dart';
import 'package:analyze_this/services/wishlist_parse.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_core/shared_core.dart'
    show PoliteHttp, PlaybackController, TrackMedia, TrackArt;

class _ArtState extends AppState {
  _ArtState(super.db);

  @override
  Future<void> ensureMedia(String path, {bool reload = false}) async {
    media.putIfAbsent(path, () => const TrackMedia());
  }
}

void main() {
  test('parses pasted formats without removing version names', () {
    final entries = parseWishlist('''
1. Artist - Song (Live)
• "Song Two" by Other
3) Another – Track (Album: Record)
Artist - Song (Live)
Title only
''');
    expect(entries.length, 4);
    expect(entries[0].artist, 'Artist');
    expect(entries[0].title, 'Song (Live)');
    expect(entries[1].title, 'Song Two');
    expect(entries[1].artist, 'Other');
    expect(entries[2].album, 'Record');
    expect(entries[2].title, 'Track');
    expect(entries[3].artist, isNull);
  });

  test(
    'identifies copies and asks for review of versions and title-only matches',
    () {
      final songs = [
        Song(
          path: 'bad',
          artist: 'Artist',
          title: 'Song',
          album: 'Record',
          userTags: [corruptTag],
        ),
        Song(path: 'good', artist: 'Artist', title: 'Song', album: 'Record'),
        Song(
          path: 'live',
          artist: 'Artist',
          title: 'Song (Live)',
          album: 'Live',
          userTags: [corruptTag],
        ),
        Song(path: 'other', artist: 'Other', title: 'Song'),
      ];
      final matches = matchWishlist(
        parseWishlist(
          'Artist - Song\nArtist - Song (Live)\nSong\nArtist - Missing\nThe Artist - Song',
        ),
        songs,
      );
      expect(matches.map((r) => r.status), [
        WishStatus.owned,
        WishStatus.damaged,
        WishStatus.ambiguous,
        WishStatus.missing,
        WishStatus.ambiguous,
      ]);
      expect(matches[0].songs.map((s) => s.path), ['good', 'bad']);
      expect(matches[0].songs.any((s) => s.path == 'live'), isFalse);
      expect(matches[1].songs.single.path, 'live');
    },
  );

  test('matches non-Latin names without conflating different artists', () {
    final songs = [
      Song(path: 'a', artist: '歌手', title: '音楽'),
      Song(path: 'b', artist: '別人', title: '音楽'),
    ];
    final matches = matchWishlist(parseWishlist('歌手 - 音楽\n別人 - 音楽'), songs);
    expect(matches.map((r) => r.status), [WishStatus.owned, WishStatus.owned]);
    expect(matches.map((r) => r.songs.single.path), ['a', 'b']);
  });

  test(
    'selects plausible origin and does not mistake other artists for ownership',
    () {
      const compilation = OriginAlbum('Greatest Hits', '1990-01-01', 'album');
      const early = OriginAlbum('First album', '2000-01-01', 'album');
      const later = OriginAlbum('Later album', '2005-01-01', 'album');
      expect(chooseOrigin([compilation, later, early]), early);
      expect(chooseOrigin([early, later], hint: 'Later album'), later);
      final songs = [Song(path: 'x', artist: 'Other', album: 'First album')];
      expect(early.inLibrary('Artist', songs), isFalse);
      expect(early.inLibrary('Other', songs), isTrue);
    },
  );

  test(
    'Deezer lookup verifies recording, caches success, and retries failures',
    () async {
      final dir = await Directory.systemTemp.createTemp('wishlist_test_');
      addTearDown(() => dir.delete(recursive: true));
      var calls = 0;
      var fail = true;
      final client = MockClient((req) async {
        calls++;
        if (fail) return http.Response('error', 503);
        if (req.url.path == '/search/track') {
          return http.Response(
            jsonEncode({
              'data': [
                {
                  'title': 'Song',
                  'artist': {'name': 'Different'},
                  'album': {'id': 99},
                },
                {
                  'title': 'Song (Live)',
                  'artist': {'name': 'Artist'},
                  'album': {'id': 98},
                },
                {
                  'title': 'Song',
                  'artist': {'name': 'Artist'},
                  'album': {'id': 1},
                },
              ],
            }),
            200,
          );
        }
        expect(req.url.path, '/album/1');
        return http.Response(
          jsonEncode({
            'title': 'Album',
            'release_date': '2000-01-01',
            'record_type': 'album',
          }),
          200,
        );
      });
      final net = PoliteHttp(
        client: client,
        defaultGap: Duration.zero,
        gaps: {},
        maxRetries: 0,
      );
      final cache = File('${dir.path}${Platform.pathSeparator}cache.json');
      final entry = WishEntry(
        line: 'Artist - Song',
        artist: 'Artist',
        title: 'Song',
      );
      final lookup = TrackOrigin(cache, net: net);
      await expectLater(lookup.lookup(entry), throwsA(isA<Exception>()));
      fail = false;
      // The failed HTTP client enters cooldown, so a new transport models a retry later.
      final retry = TrackOrigin(
        cache,
        net: PoliteHttp(client: client, defaultGap: Duration.zero, gaps: {}),
      );
      expect((await retry.lookup(entry))?.title, 'Album');
      expect(calls, 3);
      expect(
        (await TrackOrigin(cache, net: net).lookup(entry))?.title,
        'Album',
      );
      expect(calls, 3);
    },
  );

  test('cancelling album lookup leaves no incomplete cached result', () async {
    final dir = await Directory.systemTemp.createTemp('wishlist_cancel_');
    addTearDown(() => dir.delete(recursive: true));
    var stopped = false;
    final client = MockClient((req) async {
      stopped = true;
      return http.Response(
        jsonEncode({
          'data': [
            {
              'title': 'Song',
              'artist': {'name': 'Artist'},
              'album': {'id': 1},
            },
          ],
        }),
        200,
      );
    });
    final cache = File('${dir.path}${Platform.pathSeparator}cache.json');
    final lookup = TrackOrigin(
      cache,
      net: PoliteHttp(client: client, defaultGap: Duration.zero, gaps: {}),
    );
    await expectLater(
      lookup.lookup(
        const WishEntry(line: 'Artist - Song', artist: 'Artist', title: 'Song'),
        cancelled: () => stopped,
      ),
      throwsA(isA<LookupCancelled>()),
    );
    expect(await cache.exists(), isFalse);
  });

  test('remasters match but other artists and recording versions do not', () {
    final entry = parseWishlist('"Dreams" by fleetwood mac').single;
    final titles = [
      'Dreams (2004 Remaster)',
      'Dreams - Remastered 2004',
      'Dreams (Live)',
      'Dreams (Take 2)',
      'Dreams (Sessions, Roughs & Outtakes)',
      'Dreams (Remix)',
      'Dreams (Live Remastered)',
      'Dreams (Live) (2004 Remaster)',
    ];
    expect(
      matchingAlbumIds({
        'data': [
          for (var i = 0; i < titles.length; i++)
            {
              'title': titles[i],
              'artist': {'name': 'Fleetwood Mac'},
              'album': {'id': i + 1},
            },
          {
            'title': 'Dreams',
            'artist': {'name': 'Other'},
            'album': {'id': 99},
          },
        ],
      }, entry),
      [1, 2],
    );
  });

  test(
    'Dreams falls back to plain search and refreshes legacy negative cache',
    () async {
      final dir = await Directory.systemTemp.createTemp('wishlist_dreams_');
      addTearDown(() => dir.delete(recursive: true));
      final cache = File('${dir.path}${Platform.pathSeparator}cache.json');
      final entry = parseWishlist('"Dreams" by fleetwood mac').single;
      await cache.writeAsString(
        jsonEncode({
          jsonEncode(['fleetwood mac', 'dreams', null]): {
            'at': DateTime.now().millisecondsSinceEpoch,
            'album': null,
          },
        }),
      );
      final queries = <String>[];
      final lookup = TrackOrigin(
        cache,
        net: PoliteHttp(
          defaultGap: Duration.zero,
          gaps: {},
          client: MockClient((req) async {
            if (req.url.path == '/search/track') {
              final q = req.url.queryParameters['q']!;
              queries.add(q);
              return http.Response(
                jsonEncode({
                  'data': q.startsWith('artist:')
                      ? []
                      : [
                          {
                            'title': 'Dreams (2004 Remaster)',
                            'artist': {'name': 'Fleetwood Mac'},
                            'album': {'id': 6237061},
                          },
                          {
                            'title': 'Dreams (Live)',
                            'artist': {'name': 'Fleetwood Mac'},
                            'album': {'id': 98},
                          },
                        ],
                }),
                200,
              );
            }
            expect(req.url.path, '/album/6237061');
            return http.Response(
              jsonEncode({
                'title': 'Rumours',
                'release_date': '1977-02-04',
                'record_type': 'album',
              }),
              200,
            );
          }),
        ),
      );
      expect((await lookup.lookup(entry))?.title, 'Rumours');
      expect(queries, [
        'artist:"fleetwood mac" track:"Dreams"',
        'fleetwood mac Dreams',
      ]);
      expect((await lookup.lookup(entry))?.title, 'Rumours');
      expect(queries.length, 2);
    },
  );

  test('new negative caches are reused unless explicitly retried', () async {
    final dir = await Directory.systemTemp.createTemp('wishlist_retry_');
    addTearDown(() => dir.delete(recursive: true));
    var calls = 0;
    final lookup = TrackOrigin(
      File('${dir.path}${Platform.pathSeparator}cache.json'),
      net: PoliteHttp(
        defaultGap: Duration.zero,
        gaps: {},
        client: MockClient((req) async {
          calls++;
          return http.Response('{"data":[]}', 200);
        }),
      ),
    );
    final entry = parseWishlist('Artist - Missing').single;
    expect(await lookup.lookup(entry), isNull);
    expect(calls, 2);
    expect(await lookup.lookup(entry), isNull);
    expect(calls, 2);
    expect(await lookup.lookup(entry, retryMissing: true), isNull);
    expect(calls, 4);
  });

  testWidgets('checking pasted tracks shows status counts and copy details', (
    tester,
  ) async {
    final db = (await tester.runAsync(() => MusicDb.open(':memory:')))!;
    final state = _ArtState(db);
    addTearDown(() async {
      state.dispose();
      await db.close();
    });
    await tester.runAsync(() async {
      await db.upsertSong(
        Song(path: 'bad.mp3', artist: 'Artist', title: 'Song', album: 'Album'),
      );
      await db.addTag('bad.mp3', corruptTag);
    });
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppState>.value(value: state),
          ChangeNotifierProvider<PlaybackController>.value(value: state),
        ],
        child: const MaterialApp(home: Scaffold(body: WishlistView())),
      ),
    );
    await tester.enterText(
      find.byType(TextField),
      'Artist - Song\nArtist - Missing',
    );
    await tester.pump();
    await tester.runAsync(() async {
      await tester.tap(find.text('Check library'));
      for (var i = 0; i < 100 && state.wishlist.checking; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
    });
    await tester.pumpAndSettle();
    expect(state.wishlist.error, isNull);
    expect(state.wishlist.results.map((r) => r.status), [
      WishStatus.damaged,
      WishStatus.missing,
    ]);
    expect(
      state.wishlist.summary(),
      contains('bad.mp3 — damaged: Marked damaged by you'),
    );
    expect(state.wishlist.csv(), contains('"bad.mp3 (damaged)"'));
    expect(find.text('Damaged 1'), findsOneWidget);
    expect(find.text('Not found 1'), findsOneWidget);
    expect(find.byType(TrackArt), findsOneWidget);
    expect(tester.widget<TrackArt>(find.byType(TrackArt)).path, 'bad.mp3');
    await tester.tap(find.text('Artist - Song'));
    await tester.pumpAndSettle();
    expect(find.textContaining('bad.mp3'), findsOneWidget);
    expect(find.byType(TrackArt), findsNWidgets(2));
    expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('mix artwork preserves row numbers, damage badges and reorder', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final db = (await tester.runAsync(() => MusicDb.open(':memory:')))!;
    final state = _ArtState(db);
    addTearDown(() async {
      state.dispose();
      await db.close();
    });
    state.mixer.mix = [
      Song(path: 'good.mp3', title: 'Good', duration: 200, medianBpm: 85),
      Song(
        path: 'bad.mp3',
        title: 'Bad',
        duration: 200,
        medianBpm: 85,
        userTags: [corruptTag],
      ),
    ];
    state.mixer.mixPart = [null, null];
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppState>.value(value: state),
          ChangeNotifierProvider<PlaybackController>.value(value: state),
          ChangeNotifierProvider<MixController>.value(value: state.mixer),
        ],
        child: const MaterialApp(home: Scaffold(body: MixTab())),
      ),
    );
    await tester.pumpAndSettle();
    final good = find.byKey(const ValueKey('good.mp3'));
    final bad = find.byKey(const ValueKey('bad.mp3'));
    expect(
      find.descendant(of: good, matching: find.byType(TrackArt)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: bad, matching: find.byType(TrackArt)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: bad, matching: find.byType(DamagedBadge)),
      findsOneWidget,
    );
    expect(find.descendant(of: good, matching: find.text('1')), findsOneWidget);
    expect(find.descendant(of: bad, matching: find.text('2')), findsOneWidget);
    tester
        .widget<ReorderableListView>(find.byType(ReorderableListView))
        .onReorderItem!(0, 1);
    await tester.pumpAndSettle();
    expect(state.mixer.paths, ['bad.mp3', 'good.mp3']);
    expect(find.descendant(of: bad, matching: find.text('1')), findsOneWidget);
    expect(
      tester
          .widget<TrackArt>(
            find.descendant(of: bad, matching: find.byType(TrackArt)),
          )
          .path,
      'bad.mp3',
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
