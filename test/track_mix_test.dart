import 'dart:math';

import 'package:analyze_this/services/app_state.dart';
import 'package:analyze_this/services/db.dart';
import 'package:analyze_this/services/mix_controller.dart';
import 'package:analyze_this/services/mix_csv.dart';
import 'package:analyze_this/services/planner.dart';
import 'package:analyze_this/services/segment_edit.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_core/shared_core.dart' show StepPlan, TimedNote, activeTimedNote;

void main() {
  late MusicDb db;
  Song song(String n, {double bpm = 90, double duration = 200, String artist = 'A'}) =>
      Song(path: 'C:\\m\\$n.mp3', title: n, artist: artist, medianBpm: bpm, duration: duration);

  setUp(() async => db = await MusicDb.open(':memory:'));
  tearDown(() async => db.close());

  group('track mix', () {
    test('songs define the parts; exercises map on; moves and swaps keep them', () {
      final m = MixController(db);
      m.startFromTracks([song('a'), song('b', duration: 300), song('c')]);
      expect(m.program.trackMix, isTrue);
      expect(m.program.parts, hasLength(3));
      expect(m.program.parts[1].minutes, closeTo(5, 0.01));
      expect(m.mixPart, [0, 1, 2]);

      expect(m.assignExercise(1, PartRole.pyramid), isTrue);
      m.setPartNote(1, 'Breathe');
      m.reorderMix(1, 0);
      expect([for (final s in m.mix) s.title], ['b', 'a', 'c']);
      expect(m.program.parts[0].kind, PartRole.pyramid);
      expect(m.program.parts[0].trainerNote, 'Breathe');
      expect(m.mixPart, [0, 1, 2]);

      m.removeFromMix(1);
      expect(m.program.parts, hasLength(2));
      m.addToMix(song('d', duration: 120));
      expect(m.program.parts.last.minutes, closeTo(2, 0.01));

      m.undo();
      expect(m.program.parts, hasLength(2));
      m.undo();
      expect(m.program.parts, hasLength(3));
    });

    test('saved mixes keep sub-exercise timings and notes', () async {
      await db.upsertSong(song('a'));
      await db.upsertSong(song('b'));
      final m = MixController(db);
      m.startFromTracks([song('a'), song('b')]);
      m.assignExercise(0, PartRole.pyramid);
      m.setPartNote(0, 'Check resistance');
      m.setSongSegments(song('a').path, [
        const SegmentEdit(label: 'Up', seconds: 80, minRpm: 90, maxRpm: 100, note: 'Add gear'),
        const SegmentEdit(label: 'Down', seconds: 120, minRpm: 80, maxRpm: 90),
      ]);
      await m.saveMix();
      final m2 = MixController(db);
      await m2.loadSavedMixes();
      await m2.loadMix(m2.savedMixes.single);
      expect(m2.songSegments[song('a').path]!.first.note, 'Add gear');
      expect(m2.program.parts[0].trainerNote, 'Check resistance');
      expect(m2.planAt(0)!.segments.map((g) => g.label), ['Up', 'Down']);
    });

    test('a track mix survives a draft restart', () async {
      final st = AppState(db, random: Random(1));
      await db.upsertSong(song('a'));
      await db.upsertSong(song('b'));
      final m = st.mixer;
      m.startFromTracks([song('a'), song('b')]);
      m.assignExercise(0, PartRole.tabata);
      m.setSongSegments(song('a').path,
          [const SegmentEdit(label: 'Go', seconds: 30, minRpm: 90, maxRpm: 100, note: 'Fast')]);
      await m.saveDraft();
      final m2 = AppState(db, random: Random(2)).mixer;
      expect(await m2.restoreDraft(), isTrue);
      expect(m2.program.trackMix, isTrue);
      expect(m2.program.parts[0].kind, PartRole.tabata);
      expect(m2.songSegments[song('a').path]!.single.note, 'Fast');
    });
  });

  group('sub-exercise timing', () {
    test('manual segments replace the pattern and fit the song', () {
      final m = MixController(db);
      m.startFromTracks([song('a', duration: 200)]);
      m.assignExercise(0, PartRole.pyramid);
      final auto = m.planAt(0)!;
      expect(auto.segments.length, greaterThan(2));
      final edits = SegmentEdit.fromPlan(auto);
      m.setSongSegments(song('a').path, [
        edits[0].copyWith(seconds: 60, note: 'Settle'),
        edits[1].copyWith(seconds: 60),
      ]);
      final plan = m.planAt(0)!;
      expect(plan.segments, hasLength(2));
      expect(plan.segments[0].end, 60);
      expect(plan.segments[1].end, 200); // the shortfall goes to the last one
      expect(plan.segments[0].note, 'Settle');
      expect(plan.toJson()['segments'][0]['note'], 'Settle');
      m.undo();
      expect(m.planAt(0)!.segments.length, auto.segments.length);
    });

    test('segments longer than the song are cut; tap marks set lengths', () {
      const a = SegmentEdit(label: 'a', seconds: 100, minRpm: 80, maxRpm: 90);
      final segs = applySegmentEdits([a, a, a], 150);
      expect([for (final s in segs) s.end], [100, 150]);
      expect(unallocatedSeconds([a, a], 250), 50);
      final tapped = editsFromMarks([a, a, a], [40, 90], 200);
      expect([for (final e in tapped) e.seconds], [40, 50, 110]);
    });
  });

  group('csv', () {
    test('round trip keeps program, songs, notes and segments', () {
      final songs = [song('a, "x"', artist: 'Ar'), song('b')];
      const prog = Program('Mine', [
        ProgramPart('Warm', 4, 80, 90, trainerNote: 'Easy start'),
        ProgramPart('Pyr', 3, 85, 105, role: PartRole.pyramid),
      ]);
      final text = mixToCsv(
        name: 'Mix 1',
        program: prog,
        songs: songs,
        mixPart: [0, 1],
        notes: {songs[0].path: 'Hello, "team"'},
        segments: {
          songs[1].path: [const SegmentEdit(label: 'Up', seconds: 20.5, minRpm: 85, maxRpm: 95, note: 'x')]
        },
      );
      final csv = parseMixCsv(text);
      expect(csv.errors, isEmpty);
      expect(csv.name, 'Mix 1');
      expect(csv.parts.map((p) => p.part.name), ['Warm', 'Pyr']);
      expect(csv.parts[0].part.trainerNote, 'Easy start');
      expect(csv.parts[1].part.kind, PartRole.pyramid);
      expect(csv.parts[0].songs.single.note, 'Hello, "team"');
      expect(csv.parts[0].songs.single.title, 'a, "x"');
      expect(csv.parts[1].songs.single.segments.single.seconds, 20.5);
    });

    test('a plain artist,title list is a track mix; problems are reported', () {
      final csv = parseMixCsv('artist,title,role\r\nAr,Hello,warmup\r\nAr,Nope,\r\n');
      expect(csv.trackMix, isTrue);
      expect(csv.parts, hasLength(2));
      expect(csv.parts[0].part.kind, PartRole.warmup);
      final bad = parseMixCsv('type,exercise,minutes\nfoo,x,1\npart,Ride,abc\n');
      expect(bad.errors.length, 2);
      expect(parseMixCsv('').errors, isNotEmpty);
    });

    test('applying a csv builds a track mix and reports missing songs', () {
      final lib = [song('Hello', artist: 'Ar'), song('Other')];
      final m = MixController(db);
      final csv = parseMixCsv('type,artist,title,role,note\n'
          'song,ar,hello,climb,Hills\n'
          'song,Nobody,Missing,,\n'
          'segment,,,,\n');
      final r = m.applyCsv(csv, lib);
      expect(r.matched, 1);
      expect(r.missing, hasLength(1));
      expect(m.program.trackMix, isTrue);
      expect(m.program.parts.single.kind, PartRole.climb);
      expect(m.songNotes[lib[0].path], 'Hills');
      expect(parseMixCsv(m.toCsv()).errors, isEmpty);
    });
  });

  group('timed notes', () {
    test('activeTimedNote shows a note for its hold window', () {
      const n = [TimedNote(10, 'a'), TimedNote(30, 'b')];
      expect(activeTimedNote(n, 5), isNull);
      expect(activeTimedNote(n, 12)!.text, 'a');
      expect(activeTimedNote(n, 25), isNull);
      expect(activeTimedNote(n, 31)!.text, 'b');
    });

    test('add, edit, delete and undo; reach the plan, csv, saved mix and draft', () async {
      final st = AppState(db, random: Random(1));
      await db.upsertSong(song('a'));
      final m = st.mixer;
      final p = song('a').path;
      m.startFromTracks([song('a')]);
      m.addTimedNote(p, 40, 'Stand up');
      m.addTimedNote(p, 10, 'Breathe');
      expect(m.timedNotes[p]!.map((n) => n.text), ['Breathe', 'Stand up']);
      m.updateTimedNote(p, 0, at: 12);
      expect(m.planAt(0)!.timedNotes.first.at, 12);
      expect(StepPlan.fromJson(m.planAt(0)!.toJson()).timedNotes, hasLength(2));
      final csv = parseMixCsv(m.toCsv());
      expect(csv.errors, isEmpty);
      expect(csv.parts.single.songs.single.timed.map((n) => n.text), ['Breathe', 'Stand up']);

      await m.saveMix();
      await m.saveDraft();
      final m2 = AppState(db, random: Random(2)).mixer;
      expect(await m2.restoreDraft(), isTrue);
      expect(m2.timedNotes[p], hasLength(2));
      await m2.loadSavedMixes();
      m2.timedNotes.clear();
      await m2.loadMix(m2.savedMixes.single);
      expect(m2.timedNotes[p], hasLength(2));

      m.removeTimedNote(p, 0);
      expect(m.timedNotes[p], hasLength(1));
      m.undo();
      expect(m.timedNotes[p], hasLength(2));
      m.updateTimedNote(p, 0, text: ' ');
      expect(m.timedNotes[p], hasLength(1));
    });
  });
}
