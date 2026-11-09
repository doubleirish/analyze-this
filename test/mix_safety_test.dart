import 'dart:math';

import 'package:analyze_this/services/app_state.dart';
import 'package:analyze_this/services/db.dart';
import 'package:analyze_this/services/mix_controller.dart';
import 'package:analyze_this/services/planner.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late MusicDb db;

  Song song(String n, {double bpm = 85, double duration = 200}) =>
      Song(path: 'C:\\m\\$n.mp3', title: n, artist: 'A', medianBpm: bpm, duration: duration);

  List<String?> titles(MixController m) => [for (final s in m.mix) s.title];

  setUp(() async => db = await MusicDb.open(':memory:'));
  tearDown(() async => db.close());

  test('undo / redo of add, remove, reorder and fill', () async {
    for (var k = 0; k < 6; k++) {
      await db.upsertSong(song('s$k', bpm: 80.0 + k * 3, duration: 240));
    }
    final m = AppState(db, random: Random(1)).mixer;
    expect(m.canUndo, isFalse);
    m.addToMix(song('a'));
    m.addToMix(song('b'));
    m.addToMix(song('c'));
    m.removeFromMix(1);
    m.reorderMix(1, 0);
    expect(titles(m), ['c', 'a']);
    m.undo();
    expect(titles(m), ['a', 'c']);
    m.undo();
    expect(titles(m), ['a', 'b', 'c']);
    expect(m.mixPart, [null, null, null]);
    m.redo();
    m.redo();
    expect(titles(m), ['c', 'a']);
    expect(m.canRedo, isFalse);

    const prog = Program('t', [ProgramPart('Warm', 8, 80, 95)]);
    await m.fillProgram(prog);
    expect(m.mix, isNotEmpty);
    expect(m.program.name, 't');
    m.undo();
    expect(titles(m), ['c', 'a']);
    expect(m.program.name, classicProgramName);
    m.redo();
    expect(m.program.name, 't');

    // A new edit clears the redo stack.
    m.undo();
    m.addToMix(song('d'));
    expect(m.canRedo, isFalse);
  });

  test('undo is capped at 50 steps; name typing is one step', () {
    final m = MixController(db);
    for (var k = 0; k < 60; k++) {
      m.addToMix(song('s$k'));
    }
    var steps = 0;
    while (m.canUndo) {
      m.undo();
      steps++;
    }
    expect(steps, MixController.maxUndo);
    expect(m.mix, hasLength(10));

    final n = MixController(db);
    n.addToMix(song('a'));
    for (final t in ['S', 'Sp', 'Spi', 'Spin']) {
      n.setMixName(t);
    }
    expect(n.mixName, 'Spin');
    n.undo();
    expect(n.mixName, 'New mix');
    expect(n.mix, hasLength(1));
  });

  test('dirty after an edit, clean after save and load', () async {
    await db.upsertSong(song('a'));
    await db.upsertSong(song('b'));
    final m = AppState(db).mixer;
    expect(m.dirty, isFalse);
    m.addToMix(song('a'));
    expect(m.dirty, isTrue);
    m.undo();
    expect(m.dirty, isFalse);
    m.redo();
    m.setMixName('Tuesday');
    await m.saveMix();
    expect(m.dirty, isFalse);
    expect(m.canUndo, isTrue, reason: 'saving is not an undo step but keeps the history');
    m.addToMix(song('b'));
    expect(m.dirty, isTrue);
    m.undo();
    expect(m.dirty, isFalse);
    expect(m.mixDbId, isNotNull, reason: 'undo keeps the saved identity');

    m.addToMix(song('b'));
    await m.loadMix(m.savedMixes.single);
    expect(m.dirty, isFalse);
    expect(titles(m), ['a']);
    m.toggleLock(0);
    expect(m.dirty, isTrue, reason: 'locks count as a change');
  });

  test('the draft restores the working mix, drops missing songs, keeps the mix key',
      () async {
    for (final n in ['a', 'b', 'c']) {
      await db.upsertSong(song(n));
    }
    final st = AppState(db);
    final m = st.mixer;
    m.addToMix(song('a'));
    m.addToMix(song('b'));
    m.addToPart(song('c'), 2); // no earlier part in the mix: goes first
    m.toggleLock(0);
    m.setMixName('Draft mix');
    final key = m.mixKey;
    await m.saveDraft();
    await db.deleteSongs([song('a').path]);

    final st2 = AppState(db);
    await st2.load();
    final m2 = st2.mixer;
    expect(titles(m2), ['c', 'b']);
    expect(m2.mixPart, [2, null]);
    expect(m2.isLocked(0), isTrue);
    expect(m2.isLocked(1), isFalse);
    expect(m2.mixName, 'Draft mix');
    expect(m2.mixKey, key);
    expect(m2.dirty, isTrue, reason: 'never saved');
    expect(m2.canUndo, isFalse);

    // A saved mix restored from the draft stays clean.
    await m2.saveMix();
    await m2.saveDraft();
    final m3 = AppState(db).mixer;
    expect(await m3.restoreDraft(), isTrue);
    expect(m3.dirty, isFalse);
    expect(m3.mixDbId, m2.mixDbId);

    // Clearing stores an empty draft.
    m3.clearMix();
    await m3.saveDraft();
    final m4 = AppState(db).mixer;
    await m4.restoreDraft();
    expect(m4.mix, isEmpty);
    expect(m4.mixKey, m3.mixKey);
  });

  test('locked songs survive reorder, auto-fill and re-filling their part', () async {
    for (var k = 0; k < 20; k++) {
      await db.upsertSong(song('w$k', bpm: 85, duration: 120));
      await db.upsertSong(song('h$k', bpm: 100, duration: 120));
    }
    final m = AppState(db, random: Random(3)).mixer;
    const prog = Program('t', [
      ProgramPart('Warm', 6, 80, 90),
      ProgramPart('Hard', 6, 95, 105),
    ]);
    await m.fillProgram(prog);
    expect(m.mixPart, everyElement(isNotNull));
    final firstHard = m.mixPart.indexOf(1);
    final lockedWarm = m.mix[1];
    final lockedHard = m.mix[firstHard + 1];
    m.toggleLock(1);
    m.toggleLock(firstHard + 1);
    m.reorderMix(1, 0);
    expect(m.isLocked(0), isTrue, reason: 'the lock follows the song');
    expect(m.isLocked(1), isFalse);

    await m.fillProgram(prog);
    expect(m.mix.first.path, lockedWarm.path, reason: 'locked songs lead their part');
    final hardStart = m.mixPart.indexOf(1);
    expect(m.mix[hardStart].path, lockedHard.path);
    expect(m.lockedPaths, {lockedWarm.path, lockedHard.path});
    // only the time left is filled: 6 min part, 2 min songs => 3 songs each
    expect(m.mixPart.where((p) => p == 0), hasLength(3));
    expect(m.mixPart.where((p) => p == 1), hasLength(3));

    final warmBefore = [
      for (var i = 0; i < m.mix.length; i++)
        if (m.mixPart[i] == 0) m.mix[i].path
    ];
    final beforeRefill = [for (final s in m.mix) s.path];
    final added = await m.refillPart(1);
    expect(added, 2);
    expect([
      for (var i = 0; i < m.mix.length; i++)
        if (m.mixPart[i] == 0) m.mix[i].path
    ], warmBefore, reason: 'other parts are untouched');
    expect(m.mixPart, [0, 0, 0, 1, 1, 1]);
    expect(m.mix[3].path, lockedHard.path);
    m.undo();
    expect([for (final s in m.mix) s.path], beforeRefill);
    m.undo(); // the second fill
    expect(m.mix.first.path, lockedWarm.path);
    m.undo(); // the reorder
    expect(m.mix[1].path, lockedWarm.path);
    expect(m.isLocked(1), isTrue);

    m.removeFromMix(1);
    expect(m.lockedPaths, isNot(contains(lockedWarm.path)));
    m.undo();
    expect(m.isLocked(1), isTrue, reason: 'undo brings the lock back');
  });
}
