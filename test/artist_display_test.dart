import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:analyze_this/screens/browse_screens.dart';
import 'package:analyze_this/screens/library_screen.dart';
import 'package:analyze_this/services/album_health_controller.dart';
import 'package:analyze_this/services/app_state.dart';
import 'package:analyze_this/services/art_controller.dart';
import 'package:analyze_this/services/db.dart';
import 'package:analyze_this/services/discography.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_core/shared_core.dart';

class _TestState extends AppState {
  _TestState(super.db);

  @override
  Future<void> ensureMedia(String path, {bool reload = false}) async {
    media.putIfAbsent(path, () => const TrackMedia());
  }

  @override
  Future<List<AlbumRelease>?> missingAlbumsFor(
    String artist,
    Iterable<String> owned, {
    bool refresh = false,
  }) async => [];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('album hides duplicate rows, explains copies, and adds only best to mix', (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final db = await tester.runAsync(() => MusicDb.open(':memory:'));
      final state = _TestState(db!);
      addTearDown(() async { state.dispose(); await db.close(); });
      final key = dupKeyFor('David Bowie', 'Heroes');
      await tester.runAsync(() async {
        for (final (path, size) in [('heroes.mp3', 4800000), ('heroes.wma', 6400000),
            ('broken.mp3', 8000000)]) {
          await db.upsertSong(Song(path: path, title: 'Heroes', artist: 'David Bowie',
              album: 'Bowie', duration: 200, size: size, dupKey: key));
        }
        await db.addTag('broken.mp3', corruptTag);
      });
      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider<AppState>.value(value: state),
          ChangeNotifierProvider<PlaybackController>.value(value: state),
          ChangeNotifierProvider<AlbumHealthController>.value(value: state.health),
        ],
        child: const MaterialApp(home: AlbumDetailScreen(album: 'Bowie', artist: 'David Bowie')),
      ));
      for (var i = 0; i < 30 && find.byType(SongTile).evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump();
      }
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.byType(SongTile), findsOneWidget);
      final row = tester.widget<SongTile>(find.byType(SongTile));
      expect(row.song.path, 'heroes.wma');
      expect(row.dupes.map((s) => s.path), containsAll(['heroes.mp3', 'broken.mp3']));
      expect(find.textContaining('1 songs'), findsOneWidget);
      expect(find.textContaining('2 hidden copies'), findsOneWidget);
      final copies = find.byIcon(Icons.content_copy);
      expect(copies, findsOneWidget);
      final icon = tester.widget<IconButton>(find.ancestor(of: copies, matching: find.byType(IconButton)).first);
      expect(icon.tooltip, contains('~256 kbps'));
      expect(icon.tooltip, contains('heroes.mp3'));
      expect(icon.tooltip, contains('broken.mp3'));
      expect(icon.tooltip, contains('damaged'));
      final mouse = await tester.createGesture(kind: ui.PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(copies));
      await tester.pumpAndSettle();
      expect(find.text(icon.tooltip!, findRichText: true), findsOneWidget);
      await mouse.moveTo(tester.getCenter(find.byTooltip('Favourite')));
      await tester.pumpAndSettle();
      expect(find.text('Favourite'), findsOneWidget);
      await mouse.removePointer();
      await tester.pumpAndSettle();
      await tester.tap(copies);
      await tester.pumpAndSettle();
      expect(find.text('Duplicate copies'), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add all to mix'));
      await tester.pump();
      expect(state.mixer.paths, ['heroes.wma']);
      await tester.tap(find.text('Clean duplicates…'));
      await tester.pumpAndSettle();
      expect(find.text('Delete 1 damaged copies?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(await tester.runAsync(() => db.song('broken.mp3')), isNotNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      semantics.dispose();
    }
  });

  testWidgets(
    'many albums wrap at narrow widths and minor releases expand and collapse',
    (tester) async {
      tester.view.physicalSize = const Size(600, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final resources = await tester.runAsync(
        () async => (
          await Directory.systemTemp.createTemp('artist_display_'),
          await MusicDb.open(':memory:'),
        ),
      );
      final (tmp, db) = resources!;
      final state = _TestState(db);
      final net = PoliteHttp(
        client: MockClient((_) async => http.Response('{"data":[]}', 200)),
      );
      final artwork = ArtController(
        state,
        net: net,
        artistArt: ArtistArt(tmp, net: net),
      );
      addTearDown(() async {
        artwork.dispose();
        state.dispose();
        await db.close();
        await tmp.delete(recursive: true);
      });
      artwork.artistImages['u2'] = null;
      await tester.runAsync(() async {
        for (var album = 0; album < 9; album++) {
          for (var track = 0; track < 7; track++) {
            await db.upsertSong(
              Song(
                path: 'album$album-$track.flac',
                artist: 'U2',
                album: 'Album $album',
                duration: 300,
                year: 2000 + album,
              ),
            );
          }
        }
        await db.upsertSong(
          Song(
            path: 'single.flac',
            artist: 'U2',
            album: 'Single',
            title: 'Single song',
            duration: 200,
          ),
        );
      });
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AppState>.value(value: state),
            ChangeNotifierProvider<PlaybackController>.value(value: state),
            ChangeNotifierProvider<ArtController>.value(value: artwork),
            ChangeNotifierProvider<AlbumHealthController>.value(
              value: state.health,
            ),
          ],
          child: const MaterialApp(home: ArtistDetailScreen(name: 'U2')),
        ),
      );
      for (
        var i = 0;
        i < 30 && find.text('Albums (9)').evaluate().isEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(find.text('Albums (9)'), findsOneWidget);
      expect(tester.takeException(), isNull);
      final first = tester.getTopLeft(find.text('Album 8'));
      final fourth = tester.getTopLeft(find.text('Album 5'));
      expect(
        fourth.dy,
        greaterThan(first.dy),
        reason: 'Cards must wrap instead of extending horizontally',
      );
      await tester.ensureVisible(find.text('Album 0'));
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.text('Album 0')).right,
        lessThanOrEqualTo(600),
      );
      expect(
        tester.getRect(find.text('Album 0')).bottom,
        lessThanOrEqualTo(800),
      );
      await tester.ensureVisible(find.text('Singles & EPs (1)'));
      expect(find.text('Single'), findsNothing);
      await tester.tap(find.text('Singles & EPs (1)'));
      await tester.pumpAndSettle();
      expect(find.text('Single'), findsOneWidget);
      await tester.tap(find.text('Singles & EPs (1)'));
      await tester.pumpAndSettle();
      expect(find.text('Single'), findsNothing);
      tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position
          .jumpTo(0);
      await tester.pumpAndSettle();
      for (
        var i = 0;
        i < 30 && find.textContaining('Scan missing (').evaluate().isEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
      }
      expect(find.textContaining('Scan missing ('), findsOneWidget);
      await tester.tap(find.byTooltip('Change artist photo'));
      await tester.pumpAndSettle();
      expect(find.text('Use an album cover...'), findsOneWidget);
      await tester.tap(find.text('Use an album cover...'));
      await tester.pumpAndSettle();
      expect(find.text('Choose an album cover'), findsOneWidget);
      expect(find.text('Single'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test('artist photo changes propagate, persist and reject unavailable alternatives', () async {
    final tmp = await Directory.systemTemp.createTemp(
      'artist_photo_controller_',
    );
    final db = await MusicDb.open(':memory:');
    final state = _TestState(db);
    final old = [0xFF, 0xD8, ...List.filled(498, 1)];
    final cover = [0xFF, 0xD8, ...List.filled(498, 2)];
    var fail = false;
    final net = PoliteHttp(
      defaultGap: Duration.zero,
      gaps: const {},
      maxRetries: 0,
      client: MockClient((r) async {
        if (fail) return http.Response('failed', 500);
        if (r.url.host == 'api.deezer.com') {
          return http.Response(
            jsonEncode({
              'data': [
                {
                  'name': 'U2',
                  'picture_medium': 'https://cdn.dzcdn.net/old.jpg',
                },
              ],
            }),
            200,
          );
        }
        return http.Response.bytes(old, 200);
      }),
    );
    final art = ArtistArt(tmp, net: net);
    final controller = ArtController(state, net: net, artistArt: art);
    try {
      final source = await File('${tmp.path}\\album.jpg').writeAsBytes(cover);
      state.media['song'] = TrackMedia(art: source);
      await controller.useAlbumCoverAsArtistPhoto('U2', 'song');
      expect(await controller.artistImages['u2']!.readAsBytes(), cover);
      final restarted = ArtController(
        state,
        net: net,
        artistArt: ArtistArt(tmp, net: net),
      );
      await restarted.ensureArtistImage('u2');
      expect(await restarted.artistImages['u2']!.readAsBytes(), cover);
      restarted.dispose();
      await controller.randomOnlineArtistPhoto('U2');
      expect(await controller.artistImages['u2']!.readAsBytes(), old);
      await expectLater(
        controller.randomOnlineArtistPhoto('U2'),
        throwsStateError,
      );
      expect(controller.artistBusy, isEmpty);
      await controller.useAlbumCoverAsArtistPhoto('U2', 'song');
      fail = true;
      await expectLater(
        controller.resetArtistPhoto('U2'),
        throwsA(isA<HttpException>()),
      );
      expect(await controller.artistImages['u2']!.readAsBytes(), cover);
      fail = false;
      await controller.resetArtistPhoto('U2');
      expect(await controller.artistImages['u2']!.readAsBytes(), old);
    } finally {
      controller.dispose();
      state.dispose();
      await db.close();
      await tmp.delete(recursive: true);
    }
  });

  testWidgets('replacing a cached photo refreshes all avatars for the artist', (
    tester,
  ) async {
    final resources = await tester.runAsync(
      () async => (
        await Directory.systemTemp.createTemp('artist_avatar_'),
        await MusicDb.open(':memory:'),
      ),
    );
    final (tmp, db) = resources!;
    final state = _TestState(db);
    final art = ArtistArt(tmp);
    final controller = ArtController(state, net: art.net, artistArt: art);
    addTearDown(() async {
      controller.dispose();
      state.dispose();
      await db.close();
      await tmp.delete(recursive: true);
    });
    Future<void> choose(Color color) async {
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder).drawColor(color, ui.BlendMode.src);
      final picture = recorder.endRecording();
      final image = await picture.toImage(1, 1);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      picture.dispose();
      final cover = await File('${tmp.path}\\cover.png')
          .writeAsBytes(data!.buffer.asUint8List());
      state.media['song'] = TrackMedia(art: cover);
      await controller.useAlbumCoverAsArtistPhoto('U2', 'song');
    }

    Future<void> waitForPhoto() async {
      var loaded = false;
      Object? error;
      final stream = FileImage(controller.artistImages['u2']!)
          .resolve(ImageConfiguration.empty);
      final listener = ImageStreamListener(
        (_, _) => loaded = true,
        onError: (failure, _) => error = failure,
      );
      stream.addListener(listener);
      try {
        for (var i = 0; i < 100 && !loaded && error == null; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
        expect(error, isNull);
        expect(loaded, isTrue);
      } finally {
        stream.removeListener(listener);
      }
    }

    await tester.runAsync(() => choose(Colors.red));
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<PlaybackController>.value(value: state),
          ChangeNotifierProvider<ArtController>.value(value: controller),
        ],
        child: const MaterialApp(
          home: Row(
            children: [
              ArtistAvatar(name: 'U2', samplePath: 'song', size: 120),
              ArtistAvatar(name: 'u2', samplePath: 'song', size: 48),
            ],
          ),
        ),
      ),
    );
    await waitForPhoto();
    final before = tester
        .widgetList<Image>(find.byType(Image))
        .map((i) => i.key)
        .toList();
    expect(before, hasLength(2));
    await tester.runAsync(() => choose(Colors.blue));
    await tester.pump();
    final after = tester
        .widgetList<Image>(find.byType(Image))
        .map((i) => i.key)
        .toList();
    expect(after, hasLength(2));
    for (var i = 0; i < before.length; i++) {
      expect(
        after[i],
        isNot(before[i]),
        reason: 'The file path is unchanged, but the image must reload',
      );
    }
    await waitForPhoto();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
