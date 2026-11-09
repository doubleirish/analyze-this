import 'dart:io';

import 'package:analyze_this/services/class_history.dart';
import 'package:analyze_this/services/db.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _songs = ['C:\\m\\1.mp3', 'C:\\m\\2.mp3', 'C:\\m\\3.mp3', 'C:\\m\\4.mp3', 'C:\\m\\5.mp3'];

final _t0 = DateTime(2026, 10, 1, 18);

PlayRecord _p(String path, int minutes, {double listened = 200, bool completed = true}) =>
    (path: path, at: _t0.add(Duration(minutes: minutes)), listened: listened, completed: completed);

/// One counted play of each of the first [n] songs, five minutes apart.
List<PlayRecord> _class(int n, {int startMin = 0}) =>
    [for (var i = 0; i < n; i++) _p(_songs[i], startMin + i * 5)];

const MixSongs _mix = (id: 1, name: 'Tuesday', paths: _songs);

void main() {
  late MusicDb db;
  setUp(() async => db = await MusicDb.open(':memory:'));
  tearDown(() => db.close());

  group('log', () {
    test('a logged class keeps its snapshot when the mix changes', () async {
      final id = await db.saveMix('Tuesday', _songs.sublist(0, 3));
      await db.logClass(
          mixId: id, mixName: 'Tuesday', paths: await db.mixPaths(id), taughtAt: _t0);
      await db.saveMix('Tuesday', [_songs[4], _songs[3]]);
      final s = (await db.classSessions(mixId: id)).single;
      expect(s.paths, _songs.sublist(0, 3));
      expect(s.source, 'manual');
      expect(s.taughtAt, _t0);
      expect(await db.taughtDates(_songs[0]), [_t0]);
      expect(await db.taughtDates(_songs[4]), isEmpty);
    });

    test('lastTaught, pathsTaughtSince and delete', () async {
      final later = _t0.add(const Duration(days: 7));
      final a = await db.logClass(mixId: 1, mixName: 'A', paths: [_songs[0]], taughtAt: _t0);
      await db.logClass(mixId: 1, mixName: 'A', paths: [_songs[1]], taughtAt: later);
      await db.logClass(mixId: 2, mixName: 'B', paths: [_songs[2]], taughtAt: _t0);
      await db.logClass(mixName: 'unsaved', paths: [_songs[3]], taughtAt: later);
      expect(await db.lastTaught(), {1: later, 2: _t0});
      expect(await db.pathsTaughtSince(_t0.add(const Duration(days: 1))), {_songs[1], _songs[3]});
      expect((await db.classSessions()).length, 4);
      await db.deleteClassSession(a);
      expect(await db.taughtDates(_songs[0]), isEmpty);
      expect((await db.classSessions(mixId: 1)).single.taughtAt, later);
    });

    test('hideTaughtWithinDays filters songs taught inside the window only', () async {
      for (final p in _songs) {
        await db.upsertSong(Song(path: p, title: p));
      }
      final now = DateTime.now();
      await db.logClass(
          mixName: 'recent', paths: [_songs[0]], taughtAt: now.subtract(const Duration(days: 10)));
      await db.logClass(
          mixName: 'old', paths: [_songs[1]], taughtAt: now.subtract(const Duration(days: 60)));
      Future<Set<String>> found(int? days) async =>
          {for (final s in await db.search(SongQuery(hideTaughtWithinDays: days))) s.path};
      expect(await found(null), _songs.toSet());
      expect(await found(42), _songs.toSet().difference({_songs[0]}));
      expect(await found(90), _songs.sublist(2).toSet());
      expect(await found(5), _songs.toSet());
      expect(await db.count(const SongQuery(hideTaughtWithinDays: 42)), 4);
      expect(SongQuery.fromJson(const SongQuery(hideTaughtWithinDays: 42).toJson()).hideTaughtWithinDays,
          42);
    });

    test('recent_weeks defaults to 6 and drives recentlyTaughtPaths', () async {
      expect(await db.recentWeeks(), 6);
      final now = DateTime.now();
      await db.logClass(
          mixName: 'x', paths: [_songs[0]], taughtAt: now.subtract(const Duration(days: 30)));
      expect(await db.recentlyTaughtPaths(), {_songs[0]});
      await db.setRecentWeeks(2);
      expect(await db.recentWeeks(), 2);
      expect(await db.recentlyTaughtPaths(), isEmpty);
    });
  });

  group('detector', () {
    List<ClassSuggestion> detect(List<PlayRecord> plays,
            {List<ClassSession> sessions = const [], Set<String> dismissed = const {}}) =>
        detectTaughtClasses(mixes: [_mix], plays: plays, sessions: sessions, dismissed: dismissed);

    test('finds a window covering 80% of the songs', () {
      final r = detect([..._class(4), _p(_songs[0], 600)]);
      expect(r, hasLength(1));
      expect(r.single.start, _t0);
      expect(r.single.matched, 4);
      expect(r.single.total, 5);
      expect(r.single.key, '1:2026-10-01');
    });

    test('ignores under 80% and plays spread wider than the window', () {
      expect(detect(_class(3)), isEmpty);
      expect(
          detect([
            for (var i = 0; i < 4; i++) _p(_songs[i], i * 50), // 150 min end to end
          ]),
          isEmpty);
    });

    test('only counted plays count', () {
      final plays = [
        ..._class(3),
        _p(_songs[3], 20, listened: 10, completed: false),
      ];
      expect(detect(plays), isEmpty);
      expect(detect([..._class(3), _p(_songs[3], 20, listened: 30, completed: false)]),
          hasLength(1));
    });

    test('ignores a class already logged near the window', () {
      ClassSession s(int? mixId, DateTime at) =>
          ClassSession(1, mixId: mixId, mixName: 'x', taughtAt: at);
      expect(detect(_class(4), sessions: [s(1, _t0.add(const Duration(hours: 10)))]), isEmpty);
      expect(detect(_class(4), sessions: [s(2, _t0)]), hasLength(1));
      expect(detect(_class(4), sessions: [s(1, _t0.subtract(const Duration(days: 2)))]),
          hasLength(1));
    });

    test('ignores dismissed suggestions', () {
      expect(detect(_class(4), dismissed: {'1:2026-10-01'}), isEmpty);
      expect(detect(_class(4), dismissed: {'1:2026-10-02'}), hasLength(1));
    });

    test('one suggestion per class, and mixes under 3 songs are skipped', () {
      expect(detect([..._class(5), ..._class(5, startMin: 30)]), hasLength(1));
      expect(
          detectTaughtClasses(
              mixes: [(id: 2, name: 'tiny', paths: _songs.sublist(0, 2))],
              plays: _class(2),
              sessions: const []),
          isEmpty);
    });

    test('findClassSuggestions reads the db; logging or dismissing clears it', () async {
      final now = DateTime.now();
      final id = await db.saveMix('Tuesday', _songs.sublist(0, 4));
      final start = now.subtract(const Duration(days: 3));
      for (var i = 0; i < 4; i++) {
        await db.recordPlay(_songs[i], 200, true,
            app: 'beats-me', at: start.add(Duration(minutes: i * 4)).millisecondsSinceEpoch);
      }
      final r = await findClassSuggestions(db, now: now);
      expect(r.single.mixId, id);
      await db.dismissClassSuggestion(r.single.key);
      expect(await findClassSuggestions(db, now: now), isEmpty);
      expect(await findClassSuggestions(db, now: now.add(const Duration(days: 90))), isEmpty);
    });
  });

  group('migrations', () {
    test('a fresh database has the class tables', () async {
      await db.logClass(mixName: 'x', paths: [_songs[0]], taughtAt: _t0);
      expect((await db.classSessions()).single.paths, [_songs[0]]);
    });

    test('a v13 database without class tables upgrades and keeps its data', () async {
      final tmp = await Directory.systemTemp.createTemp('class_history_db_');
      addTearDown(() => tmp.delete(recursive: true));
      final path = '${tmp.path}${Platform.pathSeparator}old.db';
      final old = await MusicDb.open(path);
      await old.upsertSong(Song(path: _songs[0], title: 'x', rating: 4));
      final mix = await old.saveMix('Tuesday', _songs.sublist(0, 2));
      await old.close();

      var raw = await databaseFactoryFfi.openDatabase(path);
      await raw.execute('DROP TABLE class_session_items');
      await raw.execute('DROP TABLE class_sessions');
      await raw.setVersion(13);
      await raw.close();

      final up = await MusicDb.open(path);
      expect((await up.song(_songs[0]))!.rating, 4);
      expect(await up.mixPaths(mix), _songs.sublist(0, 2));
      await up.logClass(mixId: mix, mixName: 'Tuesday', paths: _songs.sublist(0, 2), taughtAt: _t0);
      expect(await up.lastTaught(), {mix: _t0});
      await up.close();
      raw = await databaseFactoryFfi.openDatabase(path);
      expect(await raw.getVersion(), greaterThanOrEqualTo(14));
      await raw.close();
    });
  });
}
