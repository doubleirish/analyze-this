import 'dart:convert';

import 'package:analyze_this/services/db.dart';
import 'package:analyze_this/services/mix_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late MusicDb db;

  setUp(() async {
    db = await MusicDb.open(':memory:');
    await db.upsertSong(Song(path: 'a', title: 'A', duration: 120));
    await db.upsertSong(Song(path: 'b', title: 'B', duration: 200.5));
    await db.upsertSong(Song(path: 'c', title: 'C', duration: 60));
  });
  tearDown(() => db.close());

  final program = jsonEncode({'name': 'Hills', 'parts': []});

  test('rename keeps the phone key and rejects a taken name', () async {
    final id = await db.saveMix('One', ['a', 'b'], parts: [0, 1], program: program);
    await db.saveMix('Two', ['c']);
    await db.setSetting('mix_key:$id', 'key-1');

    await db.renameMix(id, '  Uno ');
    expect((await db.mixes()).map((m) => m.name), ['Two', 'Uno']);
    expect(await db.setting('mix_key:$id'), 'key-1');
    expect(await db.mixPaths(id), ['a', 'b']);

    await expectLater(db.renameMix(id, 'Two'), throwsA(isA<MixNameTaken>()));
    expect((await db.mixes()).map((m) => m.name), ['Two', 'Uno']);
    await db.renameMix(id, 'Uno'); // renaming to its own name is fine
  });

  test('duplicate copies items, parts and program but not the key', () async {
    final id = await db.saveMix('One', ['a', 'b', 'c'], parts: [0, null, 2], program: program);
    await db.setSetting('mix_key:$id', 'key-1');

    final copy = await db.duplicateMix(id, 'One again');
    expect(copy, isNot(id));
    expect(await db.mixPaths(copy), ['a', 'b', 'c']);
    expect(await db.mixParts(copy), [0, null, 2]);
    final info = (await db.mixes()).firstWhere((m) => m.id == copy);
    expect(info.name, 'One again');
    expect(info.programJson, program);
    expect(await db.setting('mix_key:$copy'), isNull);
    expect(await db.mixPaths(id), ['a', 'b', 'c']);

    await expectLater(db.duplicateMix(id, 'One'), throwsA(isA<MixNameTaken>()));
  });

  test('mixSummaries counts songs, lengths and program names', () async {
    final one = await db.saveMix('One', ['a', 'b', 'gone'], program: program);
    final empty = await db.saveMix('Empty', []);
    final s = {for (final m in await db.mixSummaries()) m.id: m};
    expect(s[one]!.songCount, 3);
    expect(s[one]!.totalSeconds, closeTo(320.5, 1e-9));
    expect(s[one]!.programName, 'Hills');
    expect(s[empty]!.songCount, 0);
    expect(s[empty]!.totalSeconds, 0);
    expect(s[empty]!.programName, isNull);
  });

  test('delete removes the mix and its items', () async {
    final id = await db.saveMix('One', ['a']);
    await db.deleteMix(id);
    expect(await db.mixSummaries(), isEmpty);
    expect(await db.mixPaths(id), isEmpty);
  });

  test('controller keeps the loaded mix consistent on rename and delete', () async {
    final c = MixController(db);
    final id = await db.saveMix('One', ['a', 'b']);
    await c.loadSavedMixes();
    await c.loadMix(c.savedMixes.single);
    final key = c.mixKey;

    await c.renameMix(c.savedMixes.single, 'Renamed');
    expect(c.mixName, 'Renamed');
    expect(c.dirty, isFalse, reason: 'renaming a saved mix is already saved');
    expect(c.mixDbId, id);
    expect(c.mixKey, key);
    expect(await db.setting('mix_key:$id'), key);

    await c.duplicateMix(c.savedMixes.single, 'Copy');
    expect(c.savedMixes.map((m) => m.name), ['Copy', 'Renamed']);
    expect(c.mixDbId, id);

    await c.deleteMix(c.savedMixes.firstWhere((m) => m.id == id));
    expect(c.mixDbId, isNull);
    expect(c.mix.length, 2);
    expect(c.savedMixes.map((m) => m.name), ['Copy']);
  });
}
