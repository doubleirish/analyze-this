import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:analyze_this/services/backup.dart';
import 'package:analyze_this/services/db.dart';
import 'package:analyze_this/services/mix_controller.dart';
import 'package:analyze_this/services/planner.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late MusicDb db;

  setUp(() async {
    db = await MusicDb.open(':memory:');
    for (final s in ['a', 'b', 'c']) {
      await db.upsertSong(Song(path: s, title: s, duration: 200, medianBpm: 120, avgBpm: 120));
    }
  });
  tearDown(() => db.close());

  group('song settings', () {
    test('trim, explicit mark and last-mixed survive a rescan; loudness updates', () async {
      await db.setTrim('a', 10, 150);
      await db.setExplicitMark(['a'], true);
      await db.markMixed(['a']);
      await db.upsertSong(Song(path: 'a', title: 'a2', duration: 210, medianBpm: 121, avgBpm: 121, loudness: -9));
      final s = (await db.song('a'))!;
      expect(s.title, 'a2');
      expect(s.trimStart, 10);
      expect(s.trimEnd, 150);
      expect(s.playSeconds, 140);
      expect(s.isExplicit, isTrue);
      expect(s.lastMixed, isNotNull);
      expect(s.loudness, -9);
      expect(await db.pathsWithoutLoudness(), ['b', 'c']);
    });

    test('duration filters use the trimmed length', () async {
      await db.setTrim('a', 0, 60);
      final short = await db.search(const SongQuery(maxSeconds: 90));
      expect([for (final s in short) s.path], ['a']);
    });

    test('clearing the explicit mark falls back to the lyrics check', () async {
      await db.setExplicitMark(['b'], true);
      await db.setExplicitMark(['b'], null);
      expect((await db.song('b'))!.isExplicit, isFalse);
    });
  });

  group('mixes', () {
    test('song notes are saved, loaded and copied', () async {
      final id = await db.saveMix('Ride', ['a', 'b'], notes: {'b': 'Out of the saddle'});
      expect(await db.mixNotes(id), {'b': 'Out of the saddle'});
      final dup = await db.duplicateMix(id, 'Ride 2');
      expect(await db.mixNotes(dup), {'b': 'Out of the saddle'});
    });

    test('recent-mix paths cover the newest N mixes only', () async {
      final old = await db.saveMix('Old', ['c']);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final mid = await db.saveMix('Mid', ['a']);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await db.saveMix('New', ['b']);
      expect(await db.pathsInRecentMixes(2), {'a', 'b'});
      expect(await db.pathsInRecentMixes(2, exceptMix: mid), {'b', 'c'});
      expect(old, isNot(mid));
    });
  });

  group('backup', () {
    late Directory tmp;
    setUp(() async => tmp = await Directory.systemTemp.createTemp('at_backup'));
    tearDown(() async => tmp.delete(recursive: true));

    test('create, list, validate, stage and apply a restore', () async {
      final svc = BackupService(db, tmp);
      final zip = await svc.create();
      expect((await svc.list()).single.file.path, zip.path);

      final data = BackupService.validateBackup(await zip.readAsBytes(), currentSchema: await db.schemaVersion());
      expect(String.fromCharCodes(data.sublist(0, 15)), 'SQLite format 3');

      await svc.stageRestore(zip);
      expect(svc.restorePending, isTrue);
      expect((await svc.list()).length, 2, reason: 'pre-restore backup made');

      final dbPath = p.join(tmp.path, 'lib.db');
      await File(dbPath).writeAsString('old');
      expect(await BackupService.applyPendingRestore(tmp, dbPath), isTrue);
      expect(svc.restorePending, isFalse);
      final restored = await MusicDb.open(dbPath);
      expect((await restored.song('a'))?.title, 'a');
      await restored.close();
    });

    test('rejects foreign zips, newer schemas and non-SQLite data', () async {
      List<int> zip(Map<String, List<int>> files) {
        final a = Archive();
        files.forEach((k, v) => a.add(ArchiveFile.bytes(k, v)));
        return ZipEncoder().encodeBytes(a);
      }

      final info = '{"app":"analyze-this","schema":17}'.codeUnits;
      final header = Uint8List(100)..setAll(0, 'SQLite format 3\u0000'.codeUnits);
      expect(() => BackupService.validateBackup([1, 2, 3], currentSchema: 17), throwsFormatException);
      expect(
        () => BackupService.validateBackup(zip({'../library.db': header, 'backup.json': info}), currentSchema: 17),
        throwsFormatException,
      );
      expect(
        () => BackupService.validateBackup(
          zip({
            'library.db': [1, 2],
            'backup.json': info,
          }),
          currentSchema: 17,
        ),
        throwsFormatException,
      );
      header[63] = 99;
      expect(
        () => BackupService.validateBackup(zip({'library.db': header, 'backup.json': info}), currentSchema: 17),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('newer'))),
      );
      header[63] = 17;
      expect(
        BackupService.validateBackup(zip({'library.db': header, 'backup.json': info}), currentSchema: 17).length,
        100,
      );
    });

    test('automatic backups run once a day and keep the newest five', () async {
      final svc = BackupService(db, tmp);
      expect(await svc.autoBackupIfDue(), isNotNull);
      expect(await svc.autoBackupIfDue(), isNull);
      for (var i = 0; i < 6; i++) {
        await svc.create(auto: true);
        await Future<void>.delayed(const Duration(milliseconds: 1100));
      }
      await svc.create();
      await svc.autoBackupIfDue();
      final all = await svc.list();
      expect(all.where((b) => b.auto).length, BackupService.keepAuto);
      expect(all.where((b) => !b.auto).length, 1);
    });
  });

  group('rotation', () {
    late MusicDb rdb;
    const prog = Program('Ride', [ProgramPart('Steady', 12, 80, 90)]);
    setUp(() async {
      rdb = await MusicDb.open(':memory:');
      for (var k = 0; k < 24; k++) {
        await rdb.upsertSong(Song(path: 'C:\\r\\s$k.mp3', title: 's$k', artist: 'A$k', medianBpm: 85, duration: 180));
      }
    });
    tearDown(() => rdb.close());

    test('a series is saved, tagged and does not repeat songs', () async {
      final m = MixController(rdb, random: Random(3));
      m.selectProgram(prog);
      final ids = await m.planSeries('Wk', 3);
      expect(ids, hasLength(3));
      final names = {for (final x in m.savedMixes) x.name};
      expect(names, containsAll(['Wk 1', 'Wk 2', 'Wk 3']));
      final all = <String>[];
      for (final id in ids) {
        final ps = await rdb.mixPaths(id);
        expect(ps, hasLength(4));
        all.addAll(ps);
      }
      expect(all.toSet(), hasLength(all.length));
      expect((await rdb.mixSummaries()).where((x) => x.tags.contains('series:Wk')), hasLength(3));
    });

    test('rotation never picks songs of the last N other mixes', () async {
      final m = MixController(rdb, random: Random(5));
      m.selectProgram(prog);
      await m.planSeries('Wk', 2);
      final last = (await rdb.mixPaths(m.mixDbId!)).toSet();
      final first = m.savedMixes.firstWhere((x) => x.name == 'Wk 1');
      final firstPaths = (await rdb.mixPaths(first.id)).toSet();
      final n = MixController(rdb, random: Random(9));
      n.selectProgram(prog);
      await n.setRotationMixes(2);
      for (var k = 0; k < 4; k++) {
        await n.fillProgram(prog);
        expect(n.paths.toSet().intersection({...last, ...firstPaths}), isEmpty);
      }
      // The mix being edited is not counted against itself.
      await n.loadMix(first);
      final again = await rdb.search(n.mixBase().copyWith(limit: 100));
      expect(again.map((s) => s.path).toSet().intersection(firstPaths), isNotEmpty);
      expect(again.map((s) => s.path).toSet().intersection(last), isEmpty);
    });

    test('refresh swaps recently used songs for fresh ones in one undo step', () async {
      final m = MixController(rdb, random: Random(3));
      m.selectProgram(prog);
      await m.planSeries('Wk', 2);
      await m.loadMix(m.savedMixes.firstWhere((x) => x.name == 'Wk 1'));
      m.setMixName('Copy');
      await m.saveMix();
      final before = [...m.paths];
      expect(await m.staleIndexes(), [0, 1, 2, 3]);
      final picks = await m.refreshPicks();
      expect(picks, hasLength(4));
      final used = {...before, ...await rdb.pathsInRecentMixes(3)};
      for (final s in picks.values) {
        expect(used.contains(s.path), isFalse);
      }
      m.applyReplacements(picks);
      expect(m.paths.toSet().intersection(before.toSet()), isEmpty);
      m.undo();
      expect(m.paths, before);
    });

    test('role supply shows what each limit removes', () async {
      final m = MixController(rdb, random: Random(3));
      m.selectProgram(prog);
      await m.planSeries('Wk', 2);
      final n = MixController(rdb, random: Random(9));
      n.selectProgram(prog);
      final role = prog.parts.first.kind;
      var sup = (await n.supplyFor(role)).single;
      expect([sup.tempo, sup.eligible, sup.why], [24, 24, '']);
      await n.setRotationMixes(2);
      sup = (await n.supplyFor(role)).single;
      expect(sup.eligible, 16);
      expect(sup.why, 'rotation −8');
      await n.setRoleFilter(role, const MixFilter(artist: 'A1'));
      sup = (await n.supplyFor(role)).single;
      expect(sup.filtered, lessThan(24));
      expect(sup.why, startsWith('filter −'));
    });
  });
}
