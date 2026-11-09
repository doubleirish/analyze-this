// Headless genre merge: applies canonicalGenre to the library database (the
// app does the same at startup). Runs through `flutter test`; does nothing
// unless MERGE_GENRES_DB is set. Close analyze-this first.
import 'dart:io';

import 'package:analyze_this/services/db.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final dbFile = Platform.environment['MERGE_GENRES_DB'];

  test('merge genres', () async {
    final db = await MusicDb.open(dbFile!);
    final before = await db.genres();
    await db.mergeGenres();
    final after = await db.genres();
    stdout.writeln('GENRES before=${before.length} after=${after.length}');
    stdout.writeln('GONE ${before.where((g) => !after.contains(g)).join(' | ')}');
    stdout.writeln('NOW ${after.join(' | ')}');
    await db.close();
  });
}
