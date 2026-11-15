import 'dart:async';

import 'package:analyze_this/screens/with_player.dart';
import 'package:analyze_this/services/output_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_core/shared_core.dart';

class _Engine extends Fake implements PlayerEngine {
  final changes = StreamController<bool>.broadcast();
  @override
  bool playing = false;
  @override
  Stream<bool> get playingStream => changes.stream;

  void setPlaying(bool value) {
    playing = value;
    changes.add(value);
  }

  @override
  Future<void> pause() async => setPlaying(false);
  @override
  Future<void> play() async => setPlaying(true);
}

class _Playback extends PlaybackController {
  _Playback() : super(appId: 'test');
  final _engine = _Engine();
  @override
  _Engine get player => _engine;
  @override
  List<String> get libraryPaths => [];
  @override
  List<String> get mixPaths => [];

  void load(bool loaded) {
    queue = loaded ? ['song.mp3'] : [];
    index = loaded ? 0 : -1;
    notifyListeners();
  }

  @override
  void dispose() {
    // The fake engine has no native resources.
    index = -1;
    player.changes.close();
    super.dispose();
  }
}

void main() {
  testWidgets('pushed pages keep the bar while loaded, including pause', (
    tester,
  ) async {
    final playback = _Playback();
    final output = OutputController(playback);
    addTearDown(playback.dispose);
    addTearDown(output.dispose);
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<PlaybackController>.value(value: playback),
          ChangeNotifierProvider<OutputController>.value(value: output),
        ],
        child: MaterialApp(
          navigatorKey: navigator,
          home: const Scaffold(body: Text('Home')),
        ),
      ),
    );
    navigator.currentState!.push(
      playerRoute<void>(builder: (_) => const Scaffold(body: Text('Details'))),
    );
    await tester.pumpAndSettle();
    expect(find.byType(MiniPlayer), findsNothing);
    playback.load(true);
    await tester.pump();
    expect(find.byType(MiniPlayer), findsOneWidget);
    expect(find.text('song.mp3'), findsOneWidget);
    expect(find.byTooltip('Play on…'), findsOneWidget);
    expect(find.byTooltip('Play'), findsOneWidget);
    playback.player.setPlaying(true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byTooltip('Pause'), findsOneWidget);
    await tester.tap(find.byTooltip('Pause'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(find.byType(MiniPlayer), findsOneWidget);
    expect(find.byTooltip('Play'), findsOneWidget);
    playback.load(false);
    await tester.pump();
    expect(find.byType(MiniPlayer), findsNothing);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.text('Home'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'now-playing icon pulses only while playing and honors reduced motion',
    (tester) async {
      final playback = _Playback()..load(true);
      addTearDown(playback.dispose);
      var reducedMotion = false;
      late StateSetter rebuild;
      await tester.pumpWidget(
        ChangeNotifierProvider<PlaybackController>.value(
          value: playback,
          child: MaterialApp(
            home: StatefulBuilder(
              builder: (context, setState) {
                rebuild = setState;
                return MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(disableAnimations: reducedMotion),
                  child: const Scaffold(bottomNavigationBar: MiniPlayer()),
                );
              },
            ),
          ),
        ),
      );
      double scale() => tester
          .widget<ScaleTransition>(
            find.descendant(
              of: find.byTooltip('Now playing'),
              matching: find.byType(ScaleTransition),
            ),
          )
          .scale
          .value;
      expect(scale(), 1);
      playback.player.setPlaying(true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(scale(), greaterThan(1));
      final first = scale();
      await tester.pump(const Duration(milliseconds: 400));
      expect(scale(), isNot(first));
      playback.player.setPlaying(false);
      await tester.pump();
      expect(scale(), 1);
      await tester.pump(const Duration(milliseconds: 600));
      expect(scale(), 1);
      rebuild(() => reducedMotion = true);
      playback.player.setPlaying(true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(scale(), 1);
      rebuild(() => reducedMotion = false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(scale(), greaterThan(1));
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );
}
