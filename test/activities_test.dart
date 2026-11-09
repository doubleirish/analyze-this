import 'package:analyze_this/services/activities.dart';
import 'package:analyze_this/services/db.dart';
import 'package:analyze_this/services/planner.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_core/shared_core.dart';

ProgramPart part(PartRole role, {String? variant, double lo = 70, double hi = 90}) =>
    ProgramPart(role.label, 5, lo, hi, role: role, variant: variant);

void expectContiguous(StepPlan plan, double dur) {
  final s = plan.segments;
  expect(s.first.start, 0);
  expect(s.last.end, closeTo(dur, 1e-6));
  for (var i = 1; i < s.length; i++) {
    expect(s[i].start, closeTo(s[i - 1].end, 1e-6));
  }
  expect(s.every((x) => x.length > 0 && x.minRpm <= x.maxRpm), isTrue);
}

void main() {
  group('gears', () {
    List<int?> gears(PartRole r, [double dur = 240]) =>
        [for (final s in buildSongPlan(part(r), dur).segments) s.gear];

    test('every segment of every patterned role has a gear, leads at base', () {
      for (final role in patternedRoles) {
        final plan = buildSongPlan(part(role), 240);
        expect(plan.segments.every((s) => s.gear != null), isTrue, reason: role.name);
        expect(plan.segments.first.gear, 0);
        expect(plan.segments.last.gear, 0);
      }
    });

    test('hill climb steps up one gear per climb, tabata work is +2', () {
      final hill = [for (final s in buildSongPlan(part(PartRole.hillClimb), 240).segments) s.gear!];
      expect(hill.first, 0);
      expect(hill.last, 0);
      final climbs = hill.sublist(1, hill.length - 2);
      expect(climbs, [for (var i = 1; i <= climbs.length; i++) i]);
      final tab = buildSongPlan(part(PartRole.tabata), 240).segments;
      expect(tab.where((s) => s.label == 'Work').every((s) => s.gear == 2), isTrue);
      expect(tab.where((s) => s.label == 'Rest').every((s) => s.gear == 0), isTrue);
    });

    test('bookends and plain parts', () {
      expect(buildSongPlan(part(PartRole.warmup), 200).segments.single.gear, 0);
      expect(buildSongPlan(part(PartRole.cooldown), 200).segments.single.gear, -2);
      expect(buildSongPlan(part(PartRole.stretch), 200).segments.single.gear, -2);
    });

    test('gearTop stretches the ladder so the hardest segment lands on it', () {
      final p = part(PartRole.hillClimb).copyWith(baseGear: 10, gearTop: 8);
      final plan = buildSongPlan(p, 240);
      expect(plan.baseGear, 10);
      expect(plan.segments.map((s) => s.gear!).reduce((a, b) => a > b ? a : b), 8);
      expect(ProgramPart.fromJson(p.toJson()).gearTop, 8);
      expect(ProgramPart.fromJson(part(PartRole.climb).toJson()).baseGear, isNull);
    });

    test('class sheet shows gears', () {
      final prog = Program('P', [part(PartRole.hillClimb).copyWith(baseGear: 10)]);
      final html = buildClassSheet('c',
          [Song(path: 'a.mp3', title: 'a', duration: 240, medianBpm: 80)],
          program: prog, parts: [0]);
      expect(html, contains('Gear 11'));
      expect(html, contains('base 10'));
    });

    test('gears helper', () => expect(gears(PartRole.surge).whereType<int>(), isNotEmpty));
  });

  group('buildSongPlan', () {
    test('every patterned role fills the song with 15 s steady lead-in and lead-out', () {
      for (final role in patternedRoles) {
        for (final dur in [60.0, 95.0, 180.0, 240.0, 333.0]) {
          final plan = buildSongPlan(part(role), dur);
          final label = '${role.name}/$dur';
          expectContiguous(plan, dur);
          expect(plan.segments.first.lead, isTrue, reason: label);
          final lead = role == PartRole.halfAndHalf ? (dur / 6).clamp(15.0, 60.0) : leadSeconds;
          expect(plan.segments.first.end, lead, reason: label);
          expect(plan.segments.last.lead, isTrue, reason: label);
          expect(plan.segments.last.start, dur - lead, reason: label);
          expect(plan.segments.length, greaterThan(2), reason: label);
        }
      }
    });

    test('plain parts, short songs and unknown lengths stay simple', () {
      final plain = buildSongPlan(part(PartRole.climb), 200);
      expect(plain.segments, hasLength(1));
      expect(plain.segments.single.end, 200);
      expect(buildSongPlan(part(PartRole.tabata), 40).segments, hasLength(1));
      expect(buildSongPlan(part(PartRole.tabata), null).segments, isEmpty);
    });

    test('half & half alternates right and left legs, ending on the left', () {
      final legs = [
        for (final s in buildSongPlan(part(PartRole.halfAndHalf), 240).segments)
          if (!s.lead) s.label
      ];
      expect(legs.first, 'Right leg');
      expect(legs.last, 'Left leg');
      for (var i = 1; i < legs.length; i++) {
        expect(legs[i], isNot(legs[i - 1]));
      }
    });

    test('a 3 minute half & half is base, a minute per leg, then base', () {
      final s = buildSongPlan(part(PartRole.halfAndHalf), 180).segments;
      expect([for (final x in s) x.label], ['Base speed', 'Right leg', 'Left leg', 'Base speed']);
      expect([for (final x in s) x.length], [30, 60, 60, 30]);
    });

    test('tabata variants use their on/off lengths; the ladder steps up', () {
      List<double> work(String v, double dur) => [
            for (final s in buildSongPlan(part(PartRole.tabata, variant: v), dur).segments)
              if (s.label == 'Work') s.length
          ];
      expect(work('30-30', 255), everyElement(30));
      expect(work('20-20', 255), everyElement(20));
      expect(work('20-10', 255).first, 20);
      final ladder = work('ladder', 255);
      expect(ladder.take(3), [20, 30, 40]);
      final rest = buildSongPlan(part(PartRole.tabata, variant: 'ladder'), 255)
          .segments
          .where((s) => s.label == 'Rest')
          .first;
      expect(rest.length, 10);
    });

    test('hill climb adds resistance as RPM falls, then returns to high RPM', () {
      final segs = buildSongPlan(part(PartRole.hillClimb, lo: 60, hi: 90), 270)
          .segments
          .where((s) => !s.lead)
          .toList();
      final climb = segs.where((s) => s.label.startsWith('Climb') || s.label == 'Summit').toList();
      expect(climb.length, greaterThanOrEqualTo(2));
      for (var i = 1; i < climb.length; i++) {
        expect(climb[i].maxRpm, lessThan(climb[i - 1].maxRpm));
      }
      expect(climb.last.label, 'Summit');
      expect(segs.last.label, 'Return to speed');
      expect(segs.last.minRpm, greaterThan(climb.first.maxRpm - 1));
    });

    test('stand-sit-hover rotates in whole cycles', () {
      final labels = [
        for (final s in buildSongPlan(part(PartRole.standSitHover), 240).segments)
          if (!s.lead) s.label
      ];
      expect(labels.length % 3, 0);
      for (var i = 0; i < labels.length; i++) {
        expect(labels[i], ['Stand', 'Sit', 'Hover'][i % 3]);
      }
    });

    test('pyramid builds to a single peak and back, with recoveries between', () {
      final segs = buildSongPlan(part(PartRole.pyramid), 300).segments.where((s) => !s.lead).toList();
      expect(segs.where((s) => s.label == 'Peak'), hasLength(1));
      final efforts = [for (final s in segs) if (s.label != 'Recover') s];
      final peakAt = efforts.indexWhere((s) => s.label == 'Peak');
      expect(efforts[peakAt].length, efforts.map((s) => s.length).reduce((a, b) => a > b ? a : b));
      expect(efforts.take(peakAt).every((s) => s.label.startsWith('Build')), isTrue);
      expect(efforts.skip(peakAt + 1).every((s) => s.label.startsWith('Descend')), isTrue);
      expect(segs.where((s) => s.label == 'Recover'), hasLength(efforts.length - 1));
    });

    test('step pyramid climbs in steps, then drops off into a sprint', () {
      final segs = buildSongPlan(part(PartRole.stepPyramid), 360).segments.where((s) => !s.lead).toList();
      expect(segs.last.label, 'Drop off: sprint');
      expect(segs.last.minRpm, greaterThan(segs.first.maxRpm));
      final steps = segs.take(segs.length - 1).toList();
      expect(steps.last.label, 'Peak');
      for (var i = 1; i < steps.length; i++) {
        expect(steps[i].maxRpm, lessThanOrEqualTo(steps[i - 1].maxRpm));
      }
    });

    test('surge alternates bursts with settling and ends settled', () {
      final segs = buildSongPlan(part(PartRole.surge), 240).segments.where((s) => !s.lead).toList();
      expect(segs.first.label, 'Surge!');
      expect(segs.last.label, 'Settle back');
      expect(segs.where((s) => s.label == 'Surge!').length, greaterThan(1));
      expect(segs.first.maxRpm, greaterThan(segs[1].maxRpm));
    });

    test('plans round-trip through JSON and resolve the segment at a time', () {
      final plan = buildSongPlan(part(PartRole.tabata, variant: '20-10'), 180);
      final back = StepPlan.fromJson(plan.toJson());
      expect(back.segments.length, plan.segments.length);
      expect(back.activity, plan.activity);
      expect(back.segmentAt(0)!.lead, isTrue);
      expect(back.segmentAt(20)!.label, 'Work');
      expect(back.segmentAt(999)!.lead, isTrue);
      expect(back.segmentAfter(0)!.label, 'Work');
    });
  });

  group('buildPartPlans', () {
    test('one pattern across the songs: a lead-in on the first, ease-back on the last', () {
      final p = part(PartRole.pyramid);
      final plans = buildPartPlans(p, [240, 250]);
      expect(plans, hasLength(2));
      expectContiguous(plans[0], 240);
      expectContiguous(plans[1], 250);
      expect(plans[0].segments.first.lead, isTrue);
      expect(plans[0].segments.last.lead, isFalse);
      expect(plans[1].segments.first.lead, isFalse);
      expect(plans[1].segments.last.lead, isTrue);
      // Same segments as one 490 s song, cut at 240 s.
      final whole = buildSongPlan(p, 490).segments;
      expect({for (final pl in plans) ...pl.segments.map((s) => s.label)},
          whole.map((s) => s.label).toSet());
      expect(plans.expand((pl) => pl.segments).where((s) => s.label == 'Peak'), isNotEmpty);
    });

    test('a single song or an unknown length falls back to per-song plans', () {
      final p = part(PartRole.tabata);
      expect(buildPartPlans(p, [200]).single.segments.length,
          buildSongPlan(p, 200).segments.length);
      final unknown = buildPartPlans(p, [200, null]);
      expect(unknown[0].segments.last.lead, isTrue);
      expect(unknown[1].segments, isEmpty);
    });

    test('activityRuns groups consecutive songs of a part', () {
      expect(activityRuns([0, 0, 1, null, 1, 1]), [(0, 2), (2, 3), (4, 6)]);
    });
  });

  group('programs', () {
    test('new roles are inferred from names and variant survives JSON', () {
      expect(PartRole.infer('Half & half'), PartRole.halfAndHalf);
      expect(PartRole.infer('Tabata 2'), PartRole.tabata);
      expect(PartRole.infer('Stand-sit-hover'), PartRole.standSitHover);
      expect(PartRole.infer('Pyramid'), PartRole.pyramid);
      expect(PartRole.infer('Surge 1'), PartRole.surge);
      expect(PartRole.infer('Hill climb 2'), PartRole.hillClimb);
      final p = ProgramPart.fromJson(part(PartRole.tabata, variant: 'ladder').toJson());
      expect(p.variant, 'ladder');
      expect(p.kind, PartRole.tabata);
    });
  });
}
