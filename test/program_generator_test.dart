import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:analyze_this/services/activities.dart';
import 'package:analyze_this/services/app_state.dart';
import 'package:analyze_this/services/db.dart';
import 'package:analyze_this/services/genre_names.dart';
import 'package:analyze_this/services/planner.dart';
import 'package:analyze_this/services/program_generator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('canonicalGenre', () {
    test('merges electronic spellings and general prefixes', () {
      for (final g in ['Electro', 'Electronica', 'electronic', 'General Electronic', 'Electronica & Dance']) {
        expect(cleanGenre(g), 'Electronic', reason: g);
      }
      expect(cleanGenre('General Rock'), 'Rock');
      expect(cleanGenre('Rock / Pop'), 'Rock');
      expect(cleanGenre('hip hop'), 'Hip-Hop');
      expect(cleanGenre('Synth Pop'), 'Synthpop');
    });

    test('junk becomes Unknown, real subgenres stay', () {
      for (final g in ['Other', 'genre', 'misc', "'s", 's', 'Desconocido', 'General Unclassifiab', 'MST', '(12)']) {
        expect(cleanGenre(g), 'Unknown', reason: g);
      }
      expect(cleanGenre('Psytrance'), 'Psytrance');
      expect(cleanGenre('Techno'), 'Techno');
      expect(cleanGenre('(999)'), '');
    });

    test('the database merge rewrites stored genres', () async {
      final db = await MusicDb.open(':memory:');
      await db.upsertSong(Song(path: 'a', title: 'a', genre: 'Electronica'));
      await db.upsertSong(Song(path: 'b', title: 'b', genre: 'Electro'));
      await db.upsertSong(Song(path: 'c', title: 'c', genre: 'Other'));
      await db.upsertSong(Song(path: 'd', title: 'd', genre: 'Techno'));
      await db.mergeGenres();
      expect(await db.genres(), ['Electronic', 'Techno', 'Unknown']);
      await db.close();
    });
  });

  group('spreadActivities', () {
    ProgramPart part(PartRole r) => ProgramPart(r.label, 4, 80, 90, role: r);
    List<PartRole> kinds(List<ProgramPart> l) => [for (final p in l) p.kind];

    test('similar activities (climb / hill climb, sprint / surge) are kept apart', () {
      final out = spreadActivities([
        part(PartRole.climb),
        part(PartRole.hillClimb),
        part(PartRole.sprint),
        part(PartRole.surge),
        part(PartRole.steady),
      ]);
      expect(hasRepeatedNeighbour(out), isFalse);
    });

    test('separates repeated kinds and keeps half & half central', () {
      final out = spreadActivities([
        part(PartRole.sprint),
        part(PartRole.sprint),
        part(PartRole.climb),
        part(PartRole.climb),
        part(PartRole.halfAndHalf),
      ]);
      expect(hasRepeatedNeighbour(out), isFalse);
      expect(out[2].kind, PartRole.halfAndHalf);
    });

    test('keeps an order that is already fine', () {
      final acts = [part(PartRole.climb), part(PartRole.sprint), part(PartRole.climb)];
      expect(kinds(spreadActivities(acts)), kinds(acts));
    });

    test('does not throw when repeats are unavoidable', () {
      final out = spreadActivities([part(PartRole.sprint), part(PartRole.sprint)]);
      expect(out, hasLength(2));
    });

    test('generated classes never repeat a kind across a recovery', () {
      for (final style in ClassStyle.values) {
        for (var seed = 0; seed < 5; seed++) {
          final prog = generateProgram(minutes: 60, style: style, random: Random(seed));
          final acts = [for (final p in prog.parts) if (isActivity(p)) p];
          final repeats = [
            for (var i = 1; i < acts.length; i++)
              if (acts[i].kind == acts[i - 1].kind) i
          ];
          final kindsUsed = {for (final p in acts) p.kind};
          if (kindsUsed.length >= 3) expect(repeats, isEmpty, reason: '$style seed $seed');
        }
      }
    });
  });
  /// Between warm-up and cool-down: a recovery after every second activity
  /// (none after the last, shorter when two or fewer activities are left),
  /// and the half & half in the middle.
  void expectClassRhythm(Program p, String label, {bool halfInMiddle = true}) {
    final main = [
      for (final x in p.parts)
        if (!{PartRole.warmup, PartRole.cooldown, PartRole.stretch}.contains(x.kind)) x
    ];
    final acts = [for (final x in main) if (isActivity(x)) x];
    final plan = recoveryPlan(acts.length);
    var a = 0;
    for (var i = 0; i < main.length; i++) {
      expect(isActivity(main[i]), isTrue, reason: '$label: part $i should be an activity');
      final rest = plan[a++];
      if (rest > 0) {
        expect(main[++i].kind, PartRole.recovery, reason: '$label: recovery after activity $a');
        expect(main[i].minutes, inInclusiveRange(1, 2.5), reason: label);
        if (acts.length - a <= 2) {
          expect(main[i].minutes, lessThanOrEqualTo(1.5), reason: '$label: short near the end');
        }
      }
    }
    final half = acts.indexWhere((x) => x.kind == PartRole.halfAndHalf);
    if (half >= 0 && halfInMiddle) {
      expect(half, (acts.length) ~/ 2, reason: '$label: half & half in the middle');
    }
  }

  group('genre codes', () {
    test('ID3 codes become names; real names are untouched', () {
      expect(cleanGenre('(108)'), 'Unknown'); // Winamp "Primus" is junk
      expect(cleanGenre('(17)Rock'), 'Rock');
      expect(cleanGenre('(17)(18)'), 'Rock');
      expect(cleanGenre('17'), 'Rock');
      expect(cleanGenre('(RX)'), 'Remix');
      expect(cleanGenre('(999)'), '');
      expect(cleanGenre('80s'), '80s');
      expect(cleanGenre('Hip-Hop'), 'Hip-Hop');
    });

    test('stored codes are cleaned in the database', () async {
      final db = await MusicDb.open(':memory:');
      await db.upsertSong(Song(path: 'a', title: 'a', genre: '(17)'));
      await db.upsertSong(Song(path: 'b', title: 'b', genre: '(999)'));
      await db.upsertSong(Song(path: 'c', title: 'c', genre: '80s'));
      await db.cleanGenreCodes();
      expect(await db.genres(), ['80s', 'Rock']);
      await db.close();
    });
  });

  group('generateProgram', () {
    test('every style and length adds up, with warm-up first and cool-down after the main block',
        () {
      for (final style in ClassStyle.values) {
        for (final intensity in Intensity.values) {
          for (final m in [20, 30, 45, 60, 75]) {
            final p = generateProgram(
                minutes: m, style: style, intensity: intensity, random: Random(m));
            final label = '${style.name}/${intensity.name}/$m';
            expect(p.minutes, closeTo(m, 0.01), reason: label);
            expect(p.parts.first.kind, PartRole.warmup, reason: label);
            final half = p.parts.where((x) => x.kind == PartRole.halfAndHalf);
            expect(half, hasLength(1), reason: label);
            expect(half.single.minutes, 3, reason: label);
            expect(p.parts.any((x) => x.kind == PartRole.climb), isFalse, reason: label);
            expect(p.parts.any((x) => x.kind == PartRole.cooldown), isTrue, reason: label);
            expect(p.parts.every((x) => x.minutes >= 1), isTrue, reason: label);
            expect(p.parts.every((x) => x.minRpm < x.maxRpm), isTrue, reason: label);
            expect(p.parts.last.kind, PartRole.stretch, reason: label);
            expectClassRhythm(p, label);
          }
        }
      }
    });

    test('recoveries come after every second activity, lighter near the cool-down', () {
      expect(recoveryPlan(1), [0]);
      expect(recoveryPlan(3), [0, 1, 0]);
      expect(recoveryPlan(4), [0, 1, 0, 0]);
      expect(recoveryPlan(5), [0, 2, 0, 1, 0]);
      expect(recoveryPlan(7), [0, 2, 0, 2, 0, 1, 0]);
      expect(recoveryPlan(8, full: 2.5, short: 1.5), [0, 2.5, 0, 2.5, 0, 1.5, 0, 0]);
    });

    test('every built-in program follows the rhythm', () {
      for (final p in [...builtinPrograms, ...themedBuiltins]) {
        expectClassRhythm(p, p.name);
      }
      expect(builtinPrograms.where((p) => p.parts.any((x) => x.kind == PartRole.halfAndHalf)),
          hasLength(2));
    });

    test('themed built-ins: 6 themes + 2 mixed at 30/45/55, right length, unique names', () {
      expect(themedBuiltins, hasLength(24));
      expect({for (final p in themedBuiltins) p.name}, hasLength(24));
      for (final p in themedBuiltins) {
        final m = int.parse(RegExp(r'(\d+) min').firstMatch(p.name)!.group(1)!);
        expect(p.minutes, closeTo(m, 0.01), reason: p.name);
        expect(p.builtin, isTrue);
      }
      final speed = themedBuiltins.firstWhere((p) => p.name == 'Speed / sprint · 30 min');
      expect(speed.parts.any((x) => x.minRpm >= 110 && x.maxRpm <= 120), isTrue);
    });

    test('names show style, part count and minutes', () {
      final p = generateProgram(
          minutes: 45, style: ClassStyle.pyramid, random: Random(3));
      expect(p.name, 'Pyramid · ${p.parts.length} parts · 45 min');
      expect(uniqueProgramName(p.name, [p.name.toUpperCase()]), '${p.name} (2)');
      expect(uniqueProgramName('x', ['y']), 'x');
    });

    test('out-of-range lengths are clamped; same seed repeats, harder is faster', () {
      expect(generateProgram(minutes: 5, style: ClassStyle.endurance).minutes, 20);
      expect(generateProgram(minutes: 200, style: ClassStyle.endurance).minutes, 75);
      List<String> names(int seed) => [
            for (final x in generateProgram(
                    minutes: 40, style: ClassStyle.rhythm, random: Random(seed))
                .parts)
              x.name
          ];
      expect(names(7), names(7));
      double sprintTop(Intensity i) => generateProgram(
              minutes: 40, style: ClassStyle.tabata, intensity: i, random: Random(1))
          .parts
          .firstWhere((x) => x.kind == PartRole.tabata)
          .maxRpm;
      expect(sprintTop(Intensity.hard), greaterThan(sprintTop(Intensity.easy)));
    });

    test('roles survive JSON, and are inferred from names otherwise', () {
      final p = generateProgram(minutes: 30, style: ClassStyle.hills, random: Random(2));
      final back = Program.fromJson(p.toJson());
      expect([for (final x in back.parts) x.kind], [for (final x in p.parts) x.kind]);
      expect(classicProgram.parts.first.kind, PartRole.warmup);
      expect(classicProgram.parts[6].kind, PartRole.cooldown);
      expect(classicProgram.parts.last.kind, PartRole.stretch);
    });

    test('the 45 and 55 minute built-ins are exactly what they always were', () {
      final was = (jsonDecode(File('test/builtin_programs.json').readAsStringSync()) as Map)
          .cast<String, dynamic>();
      final now = {
        for (final p in themedBuiltins)
          if (!p.name.contains('30 min'))
            p.name: [for (final x in p.parts) '${x.name}|${x.minutes}|${x.minRpm}|${x.maxRpm}']
      };
      expect(now.keys, was.keys);
      for (final name in was.keys) {
        expect(now[name], was[name], reason: name);
      }
    });
  });

  group('optional warm-up, cool-down and stretch', () {
    const all = [PartRole.warmup, PartRole.cooldown, PartRole.stretch];
    const combos = [
      Bookends(),
      Bookends(warmUp: false),
      Bookends(coolDown: false),
      Bookends(stretch: false),
      Bookends(warmUp: false, coolDown: false),
      Bookends(coolDown: false, stretch: false),
      Bookends(warmUp: false, coolDown: false, stretch: false),
    ];

    test('the stretch grows with the class, and 45+ keeps its 2 minutes', () {
      expect(bookendMinutes(PartRole.stretch, 20), 1);
      expect(bookendMinutes(PartRole.stretch, 30), 1);
      expect(bookendMinutes(PartRole.stretch, 35), 1.5);
      expect(bookendMinutes(PartRole.stretch, 43), 1.5);
      expect(bookendMinutes(PartRole.stretch, 44), 2);
      for (final m in [45, 55, 60, 75]) {
        expect(bookendMinutes(PartRole.stretch, m), 2, reason: '$m');
      }
      expect(bookendMinutes(PartRole.warmup, 20), 4);
      expect(bookendMinutes(PartRole.cooldown, 20), 3);
    });

    test('every combination keeps the class length, rhythm and order', () {
      for (final b in combos) {
        for (final style in [ClassStyle.intervals, ClassStyle.tabata, ClassStyle.mixed]) {
          for (final m in [20, 30, 45, 75]) {
            final p = generateProgram(
                minutes: m, style: style, bookends: b, random: Random(m));
            final label = '$b/${style.name}/$m';
            expect(p.minutes, closeTo(m, 0.01), reason: label);
            expect(p.parts.every((x) => x.minutes >= 1), isTrue, reason: label);
            for (final r in all) {
              expect(p.parts.where((x) => x.kind == r), hasLength(b.includes(r) ? 1 : 0),
                  reason: '$label/${r.name}');
            }
            if (b.warmUp) expect(p.parts.first.kind, PartRole.warmup, reason: label);
            if (b.stretch) {
              expect(p.parts.last.kind, PartRole.stretch, reason: label);
            } else if (b.coolDown) {
              expect(p.parts.last.kind, PartRole.cooldown, reason: label);
            } else {
              expect(isActivity(p.parts.last), isTrue, reason: label);
            }
            expectClassRhythm(p, label);
          }
        }
      }
    });

    test('a part left out gives its minutes to the main block', () {
      double main(Bookends b) {
        final p = generateProgram(
            minutes: 45, style: ClassStyle.intervals, bookends: b, random: Random(1));
        return p.parts
            .where((x) => !all.contains(x.kind))
            .fold<double>(0, (a, x) => a + x.minutes);
      }

      expect(main(const Bookends(warmUp: false)), closeTo(main(const Bookends()) + 5, 0.01));
      expect(main(const Bookends(coolDown: false)), closeTo(main(const Bookends()) + 4, 0.01));
      expect(main(const Bookends(stretch: false)), closeTo(main(const Bookends()) + 2, 0.01));
      expect(main(const Bookends(warmUp: false, coolDown: false, stretch: false)),
          closeTo(45, 0.01));
    });

    test('Bookends survives JSON and reports what it includes', () {
      for (final b in combos) {
        expect(Bookends.fromJson(b.toJson()), b);
      }
      expect(const Bookends().includes(PartRole.steady), isTrue);
      expect(const Bookends(stretch: false).withRole(PartRole.stretch, true), const Bookends());
      expect(Bookends.fromJson(const {}), const Bookends());
    });

    test('a draft switch keeps the activities and the class length', () {
      final p = generateProgram(minutes: 45, style: ClassStyle.hills, random: Random(5));
      final d = ProgramDraft.of(p, style: ClassStyle.hills);
      final acts = [for (final x in d.activities) x.name];
      expect(d.bookends, const Bookends());

      expect(d.setIncluded(PartRole.warmup, false), isTrue);
      expect(d.setIncluded(PartRole.stretch, false), isTrue);
      expect(d.bookends, const Bookends(warmUp: false, stretch: false));
      expect([for (final x in d.activities) x.name], acts, reason: 'activities are kept');
      var back = d.build();
      expect(back.minutes, closeTo(45, 0.01));
      expect(back.parts.any((x) => x.kind == PartRole.warmup), isFalse);
      expect(back.parts.last.kind, PartRole.cooldown);
      expectClassRhythm(back, 'off');

      expect(d.setIncluded(PartRole.warmup, true), isTrue);
      expect(d.setIncluded(PartRole.stretch, true), isTrue);
      back = d.build();
      expect([for (final x in back.parts) '${x.name} ${x.minutes}'],
          [for (final x in p.parts) '${x.name} ${x.minutes}'],
          reason: 'switching back gives the program it started with');
    });

    test('a part can always be switched off, and back on only if it fits', () {
      final d = ProgramDraft.of(
          generateProgram(
              minutes: 20,
              style: ClassStyle.tabata,
              bookends: const Bookends(warmUp: false),
              random: Random(3)),
          style: ClassStyle.tabata);
      expect(d.included(PartRole.warmup), isFalse);
      final sprint = activityCatalog().firstWhere((x) => x.name == 'Sprint');
      while (d.insert(d.activities.length, sprint)) {}

      expect(d.canSetIncluded(PartRole.warmup, true), isFalse);
      expect(d.setIncluded(PartRole.warmup, true), isFalse);
      expect(d.included(PartRole.warmup), isFalse);
      expect(d.build().minutes, closeTo(20, 0.01));

      expect(d.setIncluded(PartRole.cooldown, false), isTrue, reason: 'off always fits');
      expect(d.canSetIncluded(PartRole.warmup, true), isTrue, reason: 'now there is room');
      expect(d.setIncluded(PartRole.warmup, true), isTrue);
      final back = d.build();
      expect(back.minutes, closeTo(20, 0.01));
      expect(back.parts.first.kind, PartRole.warmup);
      expect(back.parts.any((x) => x.kind == PartRole.cooldown), isFalse);
      expect(back.parts.every((x) => x.minutes >= 1), isTrue);
    });

    test('a draft keeps the parts a hand-edited program already has', () {
      final p = Program('Mine', const [
        ProgramPart('Easy start', 6, 80, 90, role: PartRole.warmup),
        ProgramPart('Sprint', 10, 95, 110, role: PartRole.sprint),
        ProgramPart('Spin down', 4, 60, 70, role: PartRole.cooldown),
      ]);
      final d = ProgramDraft.of(p);
      expect(d.bookend(PartRole.warmup).name, 'Easy start');
      expect(d.bookend(PartRole.cooldown).name, 'Spin down');
      expect(d.included(PartRole.stretch), isFalse);
      expect(d.bookend(PartRole.stretch).name, 'Stretch');
      expect(d.bookend(PartRole.stretch).minutes, 1, reason: '20 min class');

      expect(d.setIncluded(PartRole.stretch, true), isTrue);
      final back = d.build();
      expect(back.minutes, closeTo(20, 0.01));
      expect(back.parts.first.name, 'Easy start');
      expect(back.parts.last.name, 'Stretch');
    });
  });

  group('ProgramDraft', () {
    bool isHalf(ProgramPart p) => p.kind == PartRole.halfAndHalf;
    ProgramDraft draftOf(ClassStyle s, int m) =>
        ProgramDraft.of(generateProgram(minutes: m, style: s, random: Random(m)), style: s);
    final sprint = activityCatalog().firstWhere((x) => x.name == 'Sprint');

    test('an untouched draft rebuilds the generated program', () {
      for (final s in ClassStyle.values) {
        for (final m in [20, 45, 75]) {
          final p = generateProgram(minutes: m, style: s, random: Random(m));
          final d = ProgramDraft.of(p, style: s);
          expect(d.head.single.kind, PartRole.warmup);
          expect(d.activities.every(isActivity), isTrue);
          final back = d.build();
          expect(back.name, p.name);
          expect([for (final x in back.parts) '${x.name} ${x.minutes}'],
              [for (final x in p.parts) '${x.name} ${x.minutes}'],
              reason: '${s.name}/$m');
        }
      }
    });

    test('moving, adding and removing keep the class length and the recovery rhythm', () {
      final d = draftOf(ClassStyle.intervals, 45);
      final n = d.activities.length;
      d.move(d.activities.indexWhere(isHalf), 0);
      var p = d.build();
      expect(p.parts[1].kind, PartRole.halfAndHalf, reason: 'a moved half & half stays put');
      expect(p.minutes, closeTo(45, 0.01));
      expectClassRhythm(p, 'moved', halfInMiddle: false);

      expect(d.insert(1, sprint), isTrue);
      expect(d.activities, hasLength(n + 1));
      expect(d.activities[1].name, 'Sprint');
      p = d.build();
      expect(p.minutes, closeTo(45, 0.01));
      expect(p.name, contains('${p.parts.length} parts'));
      expectClassRhythm(p, 'added', halfInMiddle: false);

      expect(d.removeAt(0)?.kind, PartRole.halfAndHalf);
      p = d.build();
      expect(p.parts.any(isHalf), isFalse);
      expect(p.minutes, closeTo(45, 0.01));
      expectClassRhythm(p, 'removed');
    });

    test('a full class takes no more activities, and keeps at least one', () {
      final d = draftOf(ClassStyle.tabata, 20);
      while (d.insert(d.activities.length, sprint)) {}
      expect(d.canAdd(sprint), isFalse);
      expect(d.insert(0, sprint), isFalse);
      var p = d.build();
      expect(p.minutes, closeTo(20, 0.01));
      expect(p.parts.every((x) => x.minutes >= 1), isTrue);
      expectClassRhythm(p, 'full', halfInMiddle: false);

      for (var i = d.activities.length - 1; i >= 0; i--) {
        d.removeAt(i);
      }
      expect(d.activities.where((x) => !isHalf(x)), hasLength(1));
      expect(d.canRemove(d.activities.indexWhere((x) => !isHalf(x))), isFalse);
      p = d.build();
      expect(p.minutes, closeTo(20, 0.01));
    });

    test('a new length keeps the activities, dropping from the end when they no longer fit', () {
      final d = draftOf(ClassStyle.intervals, 45);
      d.insert(0, sprint);
      final names = [for (final a in d.activities) a.name];
      expect(d.setMinutes(60), 0);
      expect([for (final a in d.activities) a.name], names);
      expect(d.build().minutes, closeTo(60, 0.01));
      final dropped = d.setMinutes(20);
      expect(dropped, greaterThan(0));
      expect([for (final a in d.activities) a.name], names.take(names.length - dropped));
      expect(d.build().minutes, closeTo(20, 0.01));
    });

    test('the catalog offers every activity type, faster when harder', () {
      final c = activityCatalog();
      expect(c.every(isActivity), isTrue);
      expect(c.any((x) => x.kind == PartRole.climb), isFalse);
      expect({for (final x in c) x.name}, hasLength(c.length));
      expect(c.where((x) => x.kind == PartRole.tabata), hasLength(tabataVariants.length));
      expect(c.where(isHalf), hasLength(1));
      double top(Intensity i) => activityCatalog(i).firstWhere((x) => x.name == 'Sprint').maxRpm;
      expect(top(Intensity.hard), greaterThan(top(Intensity.easy)));
    });
  });

  group('mix filters', () {
    late MusicDb db;
    setUp(() async => db = await MusicDb.open(':memory:'));
    tearDown(() => db.close());

    Song song(String n, double bpm, String genre, String artist, int year) => Song(
        path: 'C:\\m\\$n.mp3',
        title: n,
        artist: artist,
        genre: genre,
        year: year,
        medianBpm: bpm,
        bpmStddev: 1,
        duration: 240);

    test('genre, artist and year narrow auto-fill, per role and overall', () async {
      for (final s in [
        song('calmOld', 85, 'Folk', 'Ann', 1975),
        song('calmNew', 85, 'Folk', 'Bob', 2015),
        song('edmNew', 85, 'EDM', 'Cy', 2018),
      ]) {
        await db.upsertSong(s);
      }
      final st = AppState(db, random: Random(1)).mixer;
      const prog = Program('t', [ProgramPart('Warm-up', 4, 80, 90)]);

      await st.setMixFilter(const MixFilter(genre: 'Folk'));
      await st.fillProgram(prog);
      expect(st.mix.single.genre, 'Folk');

      await st.setMixFilter(const MixFilter(minYear: 2000));
      await st.setRoleFilter(PartRole.warmup, const MixFilter(genre: 'EDM'));
      await st.fillProgram(prog);
      expect(st.mix.single.title, 'edmNew');

      await st.setRoleFilter(PartRole.warmup, const MixFilter());
      await st.setMixFilter(const MixFilter(artist: 'Ann', maxYear: 1980));
      await st.fillProgram(prog);
      expect(st.mix.single.title, 'calmOld');

      await st.setMixFilter(const MixFilter(maxYear: 1970));
      expect(await st.fillProgram(prog), 1);
    });

    test('the mix is named after the filter unless the user named it', () async {
      await db.upsertSong(song('a', 85, 'Folk', 'Ann', 1975));
      final st = AppState(db, random: Random(1)).mixer;
      const prog = Program('Pyramid', [ProgramPart('Warm-up', 4, 80, 90)]);
      await st.fillProgram(prog);
      expect(st.mixName, 'New mix');

      await st.setMixFilter(const MixFilter(genre: 'Folk', artist: 'Ann'));
      await st.fillProgram(prog);
      expect(st.mixName, 'Folk · Ann · Pyramid');

      await st.setMixFilter(const MixFilter(genre: 'Folk'));
      await st.fillProgram(prog);
      expect(st.mixName, 'Folk · Pyramid');

      st.setMixName('My ride');
      await st.fillProgram(prog);
      expect(st.mixName, 'My ride');
      await st.setMixFilter(const MixFilter());
      expect(st.mixName, 'My ride');

      st.setMixName('');
      await st.setMixFilter(const MixFilter(genre: 'Rock'));
      expect(st.mixName, 'Rock · Pyramid');
      await st.setMixFilter(const MixFilter());
      expect(st.mixName, 'New mix');
    });

    test('an artist with off-tempo, unanalysed-length songs still fills', () async {
      for (var i = 0; i < 6; i++) {
        await db.upsertSong(Song(
            path: 'C:\\r\\$i.mp3', title: 'r$i', artist: 'Radiohead', medianBpm: 160, bpmStddev: 30));
      }
      final st = AppState(db, random: Random(1)).mixer;
      await st.setMixFilter(const MixFilter(artist: 'radiohead'));
      const prog = Program('t', [ProgramPart('Warm-up', 8, 80, 90), ProgramPart('Climb', 8, 60, 70)]);
      expect(await st.fillProgram(prog), 0);
      expect(st.mix.length, 4);
      expect(st.lastFillRelaxed, 2); // the warm-up matches at double time
    });

    test('filters are saved, and role suggestions respect them', () async {
      for (final s in [
        song('warmFolk', 105, 'Folk', 'Ann', 1990),
        song('warmRock', 105, 'Rock', 'Bob', 1990),
      ]) {
        await db.upsertSong(s);
      }
      final st = AppState(db).mixer;
      await st.setMixFilter(const MixFilter(genre: 'Rock', minYear: 1980));
      await st.setRoleFilter(PartRole.cooldown, const MixFilter(artist: 'Zed'));
      final st2 = AppState(db).mixer;
      await st2.loadMixFilters();
      expect(st2.mixFilter.summary, 'Rock · from 1980');
      expect(st2.filterFor(PartRole.cooldown).summary, 'Rock · Zed · from 1980');
      final warm = await st2.suggestForRole(PartRole.warmup);
      expect(warm.map((s) => s.title), ['warmRock']);
    });
  });
}
