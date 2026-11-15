import 'package:analyze_this/screens/browse_screens.dart';
import 'package:analyze_this/services/album_health_controller.dart';
import 'package:analyze_this/services/app_state.dart';
import 'package:analyze_this/services/art_controller.dart';
import 'package:analyze_this/services/db.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets('browse sort controls work on both tabs', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final db = (await tester.runAsync(() => MusicDb.open(':memory:')))!;
    final state = AppState(db);
    addTearDown(() async {
      state.dispose();
      await db.close();
    });

    Widget screen(Widget tab) => MultiProvider(
          providers: [
            ChangeNotifierProvider<AppState>.value(value: state),
            ChangeNotifierProvider<ArtController>.value(value: state.artwork),
            ChangeNotifierProvider<AlbumHealthController>.value(value: state.health),
          ],
          child: MaterialApp(home: Scaffold(body: tab)),
        );

    await tester.pumpWidget(screen(const ArtistsTab()));
    await tester.tap(find.text('Recently added'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(state.browseSort, BrowseSort.recent);
    expect(await tester.runAsync(() => db.setting('browse_sort')), 'recent');
    expect(tester.takeException(), isNull);

    tester.view.physicalSize = const Size(800, 900);
    await tester.pumpWidget(screen(const AlbumsTab()));
    await tester.tap(find.text('Favourites'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(state.browseSort, BrowseSort.favourite);
    expect(await tester.runAsync(() => db.setting('browse_sort')), 'favourite');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
