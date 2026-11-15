import 'package:analyze_this/screens/playlist_text_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('pastes playlist and selects M3U format', (tester) async {
    PlaylistText? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await showDialog<PlaylistText>(
                  context: context,
                  builder: (_) => const PlaylistTextDialog(),
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Import'))
          .onPressed,
      isNull,
    );
    await tester.enterText(
      find.byType(TextField),
      '#EXTM3U\nC:\\Music\\song.mp3',
    );
    await tester.pump();
    await tester.tap(find.text('Artist - Title list'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('M3U / file paths').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Import'));
    await tester.pumpAndSettle();
    expect(result?.format, PlaylistTextFormat.m3u);
    expect(result?.text, '#EXTM3U\nC:\\Music\\song.mp3');
  });
}
