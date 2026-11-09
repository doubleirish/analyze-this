import 'package:analyze_this/screens/generate_program_dialog.dart';
import 'package:analyze_this/services/planner.dart';
import 'package:analyze_this/services/program_generator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('wizard: add, drop, remove and reorder activities, keeping the class length',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    Program? picked;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async => picked = await showGenerateProgramDialog(context, const []),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    int activities() =>
        tester.widget<ReorderableListView>(find.byType(ReorderableListView)).itemCount;
    Finder palette(String name) => find.byWidgetPredicate(
        (w) => w is Draggable<ProgramPart> && w.data?.name == name);
    Future<void> showInPalette(String name) async {
      final list = find.byType(Scrollable).last;
      tester.state<ScrollableState>(list).position.jumpTo(0);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(palette(name), 60, scrollable: list);
      await tester.pumpAndSettle();
    }
    final n = activities();
    expect(n, greaterThan(2));
    expect(find.text('Undo my changes'), findsNothing);

    // + adds at the end
    await showInPalette('Sprint');
    await tester.tap(find.descendant(
        of: palette('Sprint'), matching: find.byIcon(Icons.add_circle_outline)));
    await tester.pumpAndSettle();
    expect(activities(), n + 1);
    expect(find.text('Undo my changes'), findsOneWidget);

    // dragging from the list onto the first activity inserts before it
    await showInPalette('Stand-sit-hover');
    final drag = await tester.startGesture(tester.getCenter(palette('Stand-sit-hover')));
    await drag.moveBy(const Offset(-30, 0));
    await tester.pump();
    await drag.moveTo(tester.getCenter(find.byIcon(Icons.drag_indicator).first));
    await tester.pump();
    await drag.up();
    await tester.pumpAndSettle();
    expect(activities(), n + 2);

    // remove the second activity
    await tester.tap(find.widgetWithIcon(IconButton, Icons.close).at(1));
    await tester.pumpAndSettle();
    expect(activities(), n + 1);

    // drag the new first activity below the next one
    final handles = find.byIcon(Icons.drag_indicator);
    final from = tester.getCenter(handles.at(0));
    final to = tester.getCenter(handles.at(1));
    final move = await tester.startGesture(from);
    await tester.pump(const Duration(milliseconds: 100));
    for (var i = 1; i <= 10; i++) {
      await move.moveTo(from + Offset(0, (to.dy - from.dy + 30) * i / 10));
      await tester.pump(const Duration(milliseconds: 20));
    }
    await move.up();
    await tester.pumpAndSettle();
    expect(activities(), n + 1);

    await tester.tap(find.text('Use this program'));
    await tester.pumpAndSettle();
    expect(picked, isNotNull);
    final p = picked!;
    expect(p.minutes, closeTo(45, 0.01));
    expect(p.parts.first.kind, PartRole.warmup);
    final acts = [for (final x in p.parts) if (isActivity(x)) x.name];
    expect(acts, hasLength(n + 1));
    expect(acts[1], 'Stand-sit-hover');
    expect(acts.last, 'Sprint');
    expect(p.name, contains('${p.parts.length} parts · 45 min'));
  });

  testWidgets('the warm-up, cool-down and stretch can be switched off and back on',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    Program? picked;
    final reported = <Bookends>[];
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async => picked = await showGenerateProgramDialog(
              context,
              const [],
              bookends: const Bookends(stretch: false),
              onBookends: reported.add,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    Finder tile(PartRole r) => find.byKey(ValueKey('bookend-${r.name}'));
    Finder switchOf(PartRole r) => find.descendant(of: tile(r), matching: find.byType(Switch));

    // the header and footer of a ReorderableListView are built lazily, so a tile
    // has to be scrolled into view before it exists in the tree
    final listScroll = find
        .descendant(of: find.byType(ReorderableListView), matching: find.byType(Scrollable))
        .first;
    Future<bool> show(PartRole r) async {
      await tester.scrollUntilVisible(tile(r), r == PartRole.warmup ? -200 : 200,
          scrollable: listScroll);
      await tester.pumpAndSettle();
      return tester.widget<Switch>(switchOf(r)).value;
    }
    Future<void> toggle(PartRole r) async {
      await show(r);
      await tester.tap(switchOf(r));
      await tester.pumpAndSettle();
    }

    // the starting choice is used: no stretch, and the end drop zone says so
    expect(await show(PartRole.warmup), isTrue);
    expect(await show(PartRole.stretch), isFalse);
    expect(find.text('Stretch — off'), findsOneWidget);
    expect(find.text('Drop an activity here to add it before the cool-down'), findsOneWidget);

    final activities =
        tester.widget<ReorderableListView>(find.byType(ReorderableListView)).itemCount;

    await toggle(PartRole.warmup);
    expect(await show(PartRole.warmup), isFalse);
    expect(find.text('Warm-up — off'), findsOneWidget);
    expect(reported.last, const Bookends(warmUp: false, stretch: false));
    expect(tester.widget<ReorderableListView>(find.byType(ReorderableListView)).itemCount,
        activities,
        reason: 'the activities are kept');

    await toggle(PartRole.cooldown);
    expect(find.text('Drop an activity here to add it at the end'), findsOneWidget);

    await toggle(PartRole.stretch);
    expect(await show(PartRole.stretch), isTrue);
    expect(find.text('Drop an activity here to add it before the stretch'), findsOneWidget);
    expect(reported.last, const Bookends(warmUp: false, coolDown: false));

    await tester.tap(find.text('Use this program'));
    await tester.pumpAndSettle();
    final p = picked!;
    expect(p.minutes, closeTo(45, 0.01), reason: 'the class keeps its length');
    expect(p.parts.any((x) => x.kind == PartRole.warmup), isFalse);
    expect(p.parts.any((x) => x.kind == PartRole.cooldown), isFalse);
    expect(p.parts.last.kind, PartRole.stretch);
  });
}
