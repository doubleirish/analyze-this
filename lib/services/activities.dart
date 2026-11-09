import 'dart:math';

import 'package:shared_core/shared_core.dart';

import 'planner.dart';

/// Steady riding at the start and end of every patterned song.
const leadSeconds = 15.0;

/// Songs shorter than this get a single segment instead of a pattern.
const minPatternSeconds = 60.0;

const _restLo = 70.0, _restHi = 85.0;

/// Work/rest pairs (seconds) of a Tabata preset; the list repeats to fill a song.
class TabataVariant {
  const TabataVariant(this.id, this.label, this.rounds);
  final String id;
  final String label;
  final List<(double, double)> rounds;
}

const tabataVariants = [
  TabataVariant('20-20', '20 s on / 20 s off', [(20, 20)]),
  TabataVariant('30-30', '30 s on / 30 s off', [(30, 30)]),
  TabataVariant('20-10', '20 s on / 10 s off', [(20, 10)]),
  TabataVariant('ladder', 'Ladder: 20/10, 30/20, 40/20', [(20, 10), (30, 20), (40, 20)]),
];

TabataVariant tabataVariant(String? id) =>
    tabataVariants.firstWhere((v) => v.id == id, orElse: () => tabataVariants[2]);

/// Roles whose songs are split into timed sub-activities.
const patternedRoles = {
  PartRole.halfAndHalf,
  PartRole.tabata,
  PartRole.hillClimb,
  PartRole.standSitHover,
  PartRole.pyramid,
  PartRole.surge,
  PartRole.stepPyramid,
};

String roleIconKey(PartRole r) => switch (r) {
      PartRole.warmup => 'warmup',
      PartRole.climb => 'climb',
      PartRole.sprint => 'sprint',
      PartRole.recovery => 'recovery',
      PartRole.cooldown => 'cooldown',
      PartRole.stretch => 'stretch',
      PartRole.steady => 'steady',
      PartRole.halfAndHalf => 'half',
      PartRole.tabata => 'tabata',
      PartRole.hillClimb => 'hill',
      PartRole.standSitHover => 'standsit',
      PartRole.pyramid => 'pyramid',
      PartRole.surge => 'surge',
      PartRole.stepPyramid => 'steppyramid',
    };

class _Item {
  const _Item(this.label, this.icon, this.len, this.lo, this.hi, {this.cue, this.gear = 0});
  final String label, icon;
  final double len, lo, hi;
  final String? cue;

  /// Gears above the base gear.
  final int gear;
}

/// Gears above base for a single-segment song of [role].
int wholeGear(PartRole role) =>
    role == PartRole.cooldown || role == PartRole.stretch ? -2 : 0;

/// [segs] with their gears stretched so the hardest lands [top] gears above base.
List<StepSegment> scaleGears(List<StepSegment> segs, int? top) {
  if (top == null) return segs;
  final m = segs.fold<int>(0, (a, s) => max(a, s.gear ?? 0));
  if (m <= 0) return segs;
  return [
    for (final s in segs)
      (s.gear ?? 0) > 0
          ? StepSegment(
              label: s.label,
              icon: s.icon,
              start: s.start,
              end: s.end,
              minRpm: s.minRpm,
              maxRpm: s.maxRpm,
              lead: s.lead,
              cue: s.cue,
              gear: (s.gear! * top / m).round())
          : s
  ];
}

double _cap(double v) => v.clamp(40.0, 125.0).toDouble();

/// Lays [items] end to end over [start]..[end], scaling their lengths to fit.
List<StepSegment> _lay(double start, double end, List<_Item> items) {
  final total = items.fold<double>(0, (a, i) => a + i.len);
  final scale = (end - start) / total;
  final out = <StepSegment>[];
  var t = start;
  for (var i = 0; i < items.length; i++) {
    final it = items[i];
    final e = i == items.length - 1 ? end : t + it.len * scale;
    out.add(StepSegment(
        label: it.label,
        icon: it.icon,
        start: t,
        end: e,
        minRpm: _cap(it.lo),
        maxRpm: _cap(it.hi),
        cue: it.cue,
        gear: it.gear));
    t = e;
  }
  return out;
}

/// The timed plans for all songs of one activity of [p], played back to back.
/// The pattern is laid once over their summed length, so the activity has a
/// single lead-in (start of the first song) and ease-back (end of the last
/// song), and the songs' ends define where it ends. Each plan's segments are
/// on its own song's clock. With an unknown length the songs fall back to
/// [buildSongPlan] one by one.
List<StepPlan> buildPartPlans(ProgramPart p, List<double?> seconds) {
  if (seconds.length <= 1 || seconds.any((s) => s == null || s <= 0)) {
    return [for (final s in seconds) buildSongPlan(p, s)];
  }
  final whole = buildSongPlan(p, seconds.fold<double>(0, (a, s) => a + s!));
  final out = <StepPlan>[];
  var offset = 0.0;
  for (final s in seconds) {
    final end = offset + s!;
    out.add(StepPlan(
        activity: whole.activity,
        icon: whole.icon,
        minRpm: whole.minRpm,
        maxRpm: whole.maxRpm,
        baseGear: whole.baseGear,
        segments: [
          for (final g in whole.segments)
            if (g.end > offset + 0.01 && g.start < end - 0.01)
              StepSegment(
                  label: g.label,
                  icon: g.icon,
                  start: max(g.start, offset) - offset,
                  end: min(g.end, end) - offset,
                  minRpm: g.minRpm,
                  maxRpm: g.maxRpm,
                  lead: g.lead,
                  cue: g.start >= offset ? g.cue : null,
                  gear: g.gear)
        ]));
    offset = end;
  }
  return out;
}

/// Index ranges `(start, end)` (end exclusive) of runs of consecutive equal,
/// non-null entries in [parts]: the songs that make up one activity.
List<(int, int)> activityRuns(List<int?> parts) {
  final out = <(int, int)>[];
  for (var i = 0; i < parts.length;) {
    var j = i + 1;
    while (j < parts.length && parts[j] == parts[i]) {
      j++;
    }
    if (parts[i] != null) out.add((i, j));
    i = j;
  }
  return out;
}

/// The timed plan for one song of [p]. Non-patterned parts, unknown lengths and
/// very short songs get one segment (or none when the length is unknown).
StepPlan buildSongPlan(ProgramPart p, double? seconds) {
  final role = p.kind;
  final dur = seconds ?? 0;
  final lo = p.minRpm, hi = p.maxRpm;
  StepPlan plan(List<StepSegment> segs) => StepPlan(
      activity: p.name,
      icon: roleIconKey(role),
      minRpm: p.minRpm,
      maxRpm: p.maxRpm,
      baseGear: p.baseGear,
      segments: scaleGears(segs, p.gearTop));

  if (dur <= 0) return plan(const []);
  StepSegment whole() => StepSegment(
      label: p.name, icon: roleIconKey(role), start: 0, end: dur, minRpm: lo, maxRpm: hi, gear: wholeGear(role));
  if (!patternedRoles.contains(role) || dur < minPatternSeconds) return plan([whole()]);

  final lead = role == PartRole.halfAndHalf ? (dur / 6).clamp(15.0, 60.0) : leadSeconds;
  final bodyEnd = dur - lead;
  final body = bodyEnd - lead;
  var leadLo = lo, leadHi = hi;
  var leadLabel = 'Steady';
  if (role == PartRole.hillClimb) {
    leadLo = hi - 10;
    leadLabel = 'Flat road';
  } else if (role == PartRole.halfAndHalf) {
    leadLabel = 'Base speed';
  }
  final span = max(0.0, hi - lo);

  final items = switch (role) {
    PartRole.halfAndHalf => _halfAndHalf(body, lo, hi),
    PartRole.tabata => _tabata(body, lo, hi, tabataVariant(p.variant)),
    PartRole.hillClimb => _hillClimb(body, lo, hi, span),
    PartRole.standSitHover => _standSitHover(body, lo, hi),
    PartRole.pyramid => _pyramid(body, lo, hi),
    PartRole.stepPyramid => _stepPyramid(body, lo, hi),
    _ => _surge(body, lo, hi),
  };

  return plan([
    StepSegment(
        label: leadLabel,
        icon: role == PartRole.halfAndHalf ? 'both' : 'steady',
        start: 0,
        end: lead,
        minRpm: _cap(leadLo),
        maxRpm: _cap(leadHi),
        lead: true,
        gear: 0,
        cue: 'Settle into a steady rhythm'),
    ..._lay(lead, bodyEnd, items),
    StepSegment(
        label: leadLabel,
        icon: role == PartRole.halfAndHalf ? 'both' : 'steady',
        start: bodyEnd,
        end: dur,
        minRpm: _cap(leadLo),
        maxRpm: _cap(leadHi),
        lead: true,
        gear: 0,
        cue: 'Ease back and recover'),
  ]);
}

/// Base speed, then a minute per leg (more pairs for longer songs), then back to base.
List<_Item> _halfAndHalf(double body, double lo, double hi) {
  final pairs = max(1, (body / 120).round());
  return [
    for (var i = 0; i < pairs; i++) ...[
      _Item('Right leg', 'right', 1, lo, hi, gear: 1, cue: 'Pedal with the right leg only'),
      _Item('Left leg', 'left', 1, lo, hi, gear: 1, cue: 'Pedal with the left leg only'),
    ],
  ];
}

List<_Item> _tabata(double body, double lo, double hi, TabataVariant v) {
  final items = <_Item>[];
  var t = 0.0, i = 0;
  _Item work(double len, int round) =>
      _Item('Work', 'work', len, lo, hi, gear: 2, cue: 'Round $round · all out');
  _Item rest(double len, int round) =>
      _Item('Rest', 'rest', len, _restLo, _restHi, cue: 'Round $round · easy spin');
  while (true) {
    final (on, off) = v.rounds[i % v.rounds.length];
    if (t + on + off > body + 0.001) break;
    items..add(work(on, i + 1))..add(rest(off, i + 1));
    t += on + off;
    i++;
  }
  final left = body - t;
  if (items.isEmpty) return [work(body, 1)];
  if (left >= 30) {
    items..add(work(left * 2 / 3, i + 1))..add(rest(left / 3, i + 1));
  } else {
    final last = items.removeLast();
    items.add(_Item(last.label, last.icon, last.len + left, last.lo, last.hi,
        cue: last.cue, gear: last.gear));
  }
  return items;
}

List<_Item> _hillClimb(double body, double lo, double hi, double span) {
  final returnLen = min(max(10.0, body * 0.2), body - 20);
  final climbLen = body - returnLen;
  final n = (climbLen / 30).round().clamp(2, 6);
  final w = min(span, max(6.0, span / n));
  return [
    for (var k = 0; k < n; k++)
      () {
        final top = n == 1 ? hi : hi - (span - w) * k / (n - 1);
        final last = k == n - 1;
        return _Item(last ? 'Summit' : 'Climb ${k + 1}/$n', last ? 'summit' : 'resistance',
            climbLen / n, top - w, top,
            gear: k + 1,
            cue: last
                ? 'Heaviest gear: hold it to the top'
                : 'Add a turn of resistance, slower legs');
      }(),
    _Item('Return to speed', 'spin', returnLen, hi, hi + 15,
        cue: 'Drop the resistance and spin up'),
  ];
}

List<_Item> _standSitHover(double body, double lo, double hi) {
  final n = 3 * max(1, (body / 72).round());
  return [
    for (var i = 0; i < n; i++)
      switch (i % 3) {
        0 => _Item('Stand', 'stand', 1, lo - 5, hi - 5, gear: 2, cue: 'Out of the saddle, hands on the bars'),
        1 => _Item('Sit', 'sit', 1, lo, hi, cue: 'Back in the saddle'),
        _ => _Item('Hover', 'hover', 1, lo + 5, hi + 10, gear: 1, cue: 'Hips just above the saddle'),
      },
  ];
}

List<_Item> _pyramid(double body, double lo, double hi) {
  final k = body < 90 ? 2 : (body < 200 ? 3 : 4);
  final levels = [for (var i = 1; i <= k; i++) i, for (var i = k - 1; i >= 1; i--) i];
  const recLen = 8.0;
  final recTotal = recLen * (levels.length - 1);
  final effort = body - recTotal;
  final sumW = levels.fold<int>(0, (a, e) => a + e);
  final items = <_Item>[];
  var descend = 0;
  for (var i = 0; i < levels.length; i++) {
    final peak = i == k - 1;
    final up = i < k - 1;
    if (!peak && !up) descend++;
    final len = effort * levels[i] / sumW;
    items.add(peak
        ? _Item('Peak', 'peak', len, (lo + hi) / 2, hi + 5,
            gear: levels[i], cue: 'Hardest effort: everything you have')
        : up
            ? _Item('Build ${i + 1}', 'build', len, lo, hi, gear: levels[i], cue: 'Add resistance')
            : _Item('Descend $descend', 'descend', len, lo, hi, gear: levels[i], cue: 'Ease the resistance back'));
    if (i < levels.length - 1) {
      items.add(const _Item('Recover', 'rest', recLen, _restLo, _restHi, cue: 'Sit and breathe'));
    }
  }
  return items;
}

/// Stepped climb: resistance (and intensity) goes up a step at a time to a
/// peak, then a full drop-off: all the load comes off and the rider sprints.
List<_Item> _stepPyramid(double body, double lo, double hi) {
  final dropLen = min(max(20.0, body * 0.3), max(10.0, body - 30));
  final climbLen = body - dropLen;
  final n = (climbLen / 30).round().clamp(3, 8);
  final span = max(0.0, hi - lo);
  final w = min(span, max(6.0, span / n));
  return [
    for (var k = 0; k < n; k++)
      () {
        final top = hi - (span - w) * k / (n - 1);
        final last = k == n - 1;
        return _Item(last ? 'Peak' : 'Step ${k + 1}/$n', last ? 'peak' : 'resistance',
            climbLen / n, top - w, top,
            gear: last ? 2 * n : 2 * (k + 1),
            cue: last ? 'Heaviest step: hold it' : 'Add a turn of resistance, steady legs');
      }(),
    _Item('Drop off: sprint', 'sprint', dropLen, hi + 10, hi + 25,
        cue: 'Full drop-off: take the load right off and sprint'),
  ];
}

List<_Item> _surge(double body, double lo, double hi) {
  final k = max(1, (body / 50).floor());
  final unit = body / k;
  final burst = min(15.0, unit * 0.4);
  return [
    for (var i = 0; i < k; i++) ...[
      _Item('Surge!', 'surge', burst, hi, hi + 10, gear: 1, cue: 'Speed up, stay in control'),
      _Item('Settle back', 'settle', unit - burst, lo, hi, cue: 'Back to your base cadence'),
    ],
  ];
}
