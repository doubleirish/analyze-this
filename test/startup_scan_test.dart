import 'dart:io';

import 'package:analyze_this/services/app_state.dart';
import 'package:analyze_this/services/db.dart';
import 'package:analyze_this/services/scanner.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;
  late MusicDb db;
  final sep = Platform.pathSeparator;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('startup_scan_');
    db = await MusicDb.open(':memory:');
  });

  tearDown(() async {
    await db.close();
    await tmp.delete(recursive: true);
  });

  Future<File> mp3(String name) async {
    final f = File('${tmp.path}$sep$name.mp3');
    await f.writeAsBytes(List.filled(100, 1));
    return f;
  }

  test('quick scan adds new, drops removed and refreshes changed files', () async {
    final keep = await mp3('Europe - The Final Countdown');
    final changed = await mp3('Queen - Bohemian Rhapsody');
    final gone = '${tmp.path}${sep}Gone - Song.mp3';
    final stat = await keep.stat();
    await db.upsertSong(Song(
        path: keep.path,
        size: stat.size,
        mtime: stat.modified.millisecondsSinceEpoch,
        title: 'Kept title',
        artist: 'Europe',
        rating: 4,
        tagsV: 1));
    await db.upsertSong(Song(
        path: changed.path, size: 1, mtime: 1, title: 'Stale', artist: 'Queen', rating: 5, tagsV: 1));
    await db.upsertSong(Song(path: gone, size: 100, title: 'Gone', tagsV: 1));
    final added = await mp3('ABBA - Waterloo');

    final errors = await Scanner(db).quickScan([tmp.path]);
    expect(errors, isEmpty);

    expect(await db.song(gone), isNull);
    expect((await db.song(added.path))?.title, 'Waterloo');
    expect((await db.song(keep.path))?.title, 'Kept title');
    final c = (await db.song(changed.path))!;
    expect(c.title, 'Bohemian Rhapsody');
    expect(c.size, 100);
    expect(c.rating, 5);
  });

  test('quick scan leaves songs on unavailable folders alone', () async {
    final missing = '${tmp.path}${sep}unplugged';
    final song = '$missing${sep}A - B.mp3';
    await db.upsertSong(Song(path: song, size: 100, title: 'B', tagsV: 1));

    final errors = await Scanner(db).quickScan([missing]);
    expect(errors, isEmpty);
    expect(await db.song(song), isNotNull);
  });

  test('overlapping refreshes are folded into one follow-up and see the latest data', () async {
    final s = AppState(db);
    await db.upsertSong(Song(path: 'a.mp3', size: 1, title: 'A', tagsV: 1));
    final first = s.refresh();
    final overlapping = [for (var i = 0; i < 20; i++) s.refresh()];
    await db.upsertSong(Song(path: 'b.mp3', size: 1, title: 'B', tagsV: 1));
    final v0 = s.libraryVersion;
    await Future.wait([first, ...overlapping]);
    expect(s.libraryVersion - v0, lessThanOrEqualTo(2));
    expect(s.songCount, 2);
    await s.refresh();
    expect(s.songCount, 2);
  });

  test('deleteSongs removes every record of the songs', () async {
    await db.upsertSong(Song(path: 'a.mp3', size: 1, title: 'A', tagsV: 1));
    await db.upsertSong(Song(path: 'b.mp3', size: 1, title: 'B', tagsV: 1));
    await db.addTag('a.mp3', 'x');
    await db.deleteSongs(['a.mp3']);
    expect(await db.song('a.mp3'), isNull);
    expect(await db.tagsOf('a.mp3'), isEmpty);
    expect(await db.song('b.mp3'), isNotNull);
    await db.deleteSongs([]);
  });

  test('startup scan runs only with folders and the setting on (default on)', () async {
    expect(AppState.shouldScanOnStartup(['C:\\Music'], true), isTrue);
    expect(AppState.shouldScanOnStartup(['C:\\Music'], false), isFalse);
    expect(AppState.shouldScanOnStartup([], true), isFalse);

    final s = AppState(db);
    expect(s.scanOnStartup, isTrue);
    expect(await db.setting('scan_on_startup'), isNull);
    await s.setScanOnStartup(false);
    expect(await db.setting('scan_on_startup'), '0');
  });
}
