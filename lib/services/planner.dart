import 'dart:math';

import 'package:shared_core/shared_core.dart' show absoluteGear, foldToBand;

import 'activities.dart';
import 'db.dart';
export 'package:shared_core/shared_core.dart' show foldToBand;

/// Search settings for one part of a class (BPM is the song's median tempo).
class SectionPreset {
  const SectionPreset(this.name, this.minBpm, this.maxBpm,
      {this.maxStddev, this.minSeconds, this.maxSeconds});
  final String name;
  final double minBpm;
  final double maxBpm;
  final double? maxStddev;
  final double? minSeconds;
  final double? maxSeconds;
}

const sectionPresets = [
  SectionPreset('Warm-up', 100, 120, maxStddev: 6, minSeconds: 150, maxSeconds: 330),
  SectionPreset('Climb', 80, 100, maxStddev: 4, minSeconds: 180, maxSeconds: 420),
  SectionPreset('Sprint', 140, 175, maxStddev: 6, minSeconds: 120, maxSeconds: 300),
  SectionPreset('Recovery', 70, 100, minSeconds: 120, maxSeconds: 270),
  SectionPreset('Cool-down', 60, 95, minSeconds: 150, maxSeconds: 330),
];

SectionPreset presetNamed(String n) => sectionPresets.firstWhere((p) => p.name == n);

/// What a part of a class is for, so music can be chosen by role
/// (warm-up and cool-down music is usually very different from the peak).
enum PartRole {
  warmup('Warm-up', 'Warm-up'),
  climb('Climb', 'Climb'),
  sprint('Sprint / peak', 'Sprint'),
  recovery('Recovery', 'Recovery'),
  cooldown('Cool-down', 'Cool-down'),
  stretch('Stretch', 'Cool-down'),
  steady('Steady', 'Warm-up'),
  halfAndHalf('Half & half', 'Climb'),
  stepPyramid('Step pyramid', 'Climb'),
  tabata('Tabata', 'Sprint'),
  hillClimb('Hill climb', 'Climb'),
  standSitHover('Stand-sit-hover', 'Climb'),
  pyramid('Pyramid', 'Sprint'),
  surge('Surge', 'Sprint');

  const PartRole(this.label, this.preset);
  final String label;

  /// Name of the [sectionPresets] entry giving this role's usual tempo.
  final String preset;

  static PartRole infer(String name) {
    final n = name.toLowerCase();
    if (n.contains('warm')) return warmup;
    if (n.contains('cool')) return cooldown;
    if (n.contains('stretch')) return stretch;
    if (n.contains('half')) return halfAndHalf;
    if (n.contains('step pyramid')) return stepPyramid;
    if (n.contains('tabata')) return tabata;
    if (n.contains('hover') || n.contains('stand-sit') || n.contains('stand sit')) return standSitHover;
    if (n.contains('pyramid')) return pyramid;
    if (n.contains('surge')) return surge;
    if (n.contains('hill climb')) return hillClimb;
    if (n.contains('recover') || n.contains('rest')) return recovery;
    if (n.contains('climb') || n.contains('hill') || n.contains('strength')) return climb;
    if (n.contains('sprint') ||
        n.contains('interval') ||
        n.contains('peak') ||
        n.contains('race')) {
      return sprint;
    }
    return steady;
  }
}

/// Genre / artist / year limits for choosing songs on the Mix page. Empty
/// fields mean "any".
class MixFilter {
  const MixFilter({this.genre = '', this.artist = '', this.minYear, this.maxYear});
  final String genre;
  final String artist;
  final int? minYear;
  final int? maxYear;

  bool get isEmpty => genre.isEmpty && artist.isEmpty && minYear == null && maxYear == null;

  MixFilter copyWith(
          {String? genre,
          String? artist,
          int? minYear,
          int? maxYear,
          bool clearMinYear = false,
          bool clearMaxYear = false}) =>
      MixFilter(
          genre: genre ?? this.genre,
          artist: artist ?? this.artist,
          minYear: clearMinYear ? null : minYear ?? this.minYear,
          maxYear: clearMaxYear ? null : maxYear ?? this.maxYear);

  /// This filter with any field set on [o] replaced by [o]'s value.
  MixFilter overlay(MixFilter o) => MixFilter(
      genre: o.genre.isNotEmpty ? o.genre : genre,
      artist: o.artist.isNotEmpty ? o.artist : artist,
      minYear: o.minYear ?? minYear,
      maxYear: o.maxYear ?? maxYear);

  SongQuery applyTo(SongQuery q) => q.copyWith(
      genre: genre.isEmpty ? null : genre,
      artist: artist.isEmpty ? null : artist,
      minYear: minYear,
      maxYear: maxYear);

  /// e.g. "Rock · The Beatles · 1960–1969"
  String get summary {
    final years = minYear == null && maxYear == null
        ? ''
        : minYear != null && maxYear != null
            ? (minYear == maxYear ? '$minYear' : '$minYear–$maxYear')
            : minYear != null
                ? 'from $minYear'
                : 'to $maxYear';
    return [if (genre.isNotEmpty) genre, if (artist.isNotEmpty) artist, if (years.isNotEmpty) years]
        .join(' · ');
  }

  Map<String, Object?> toJson() =>
      {'genre': genre, 'artist': artist, 'minYear': minYear, 'maxYear': maxYear};

  factory MixFilter.fromJson(Map<String, dynamic> j) => MixFilter(
      genre: j['genre'] as String? ?? '',
      artist: j['artist'] as String? ?? '',
      minYear: j['minYear'] as int?,
      maxYear: j['maxYear'] as int?);
}

/// One part of a class program. Cadence is in RPM; songs match when their
/// median BPM is within the range, or at half or double time.
class ProgramPart {
  const ProgramPart(this.name, this.minutes, this.minRpm, this.maxRpm,
      {this.purpose = '',
      this.feel = '',
      this.execution = '',
      this.music = true,
      this.maxStddev,
      this.role,
      this.variant,
      this.baseGear,
      this.gearTop});
  final String name;
  final double minutes;
  final double minRpm;
  final double maxRpm;
  final String purpose;
  final String feel;
  final String execution;

  /// false = no songs are picked (e.g. a silent stretch).
  final bool music;
  final double? maxStddev;

  /// Set by the generator; otherwise worked out from [name].
  final PartRole? role;
  PartRole get kind => role ?? PartRole.infer(name);

  /// Pattern option, e.g. the Tabata work/rest preset id (see `tabataVariants`).
  final String? variant;

  /// This part's own base gear, and the gear the hardest segment should reach; null = automatic.
  final int? baseGear;
  final int? gearTop;

  double get targetRpm => (minRpm + maxRpm) / 2;
  double get rpmTolerance => (maxRpm - minRpm) / 2 + 3;

  ProgramPart copyWith(
          {String? name,
          double? minutes,
          double? minRpm,
          double? maxRpm,
          String? purpose,
          String? feel,
          String? execution,
          bool? music,
          PartRole? role,
          String? variant,
          bool clearVariant = false,
          int? baseGear,
          int? gearTop,
          bool clearGears = false}) =>
      ProgramPart(name ?? this.name, minutes ?? this.minutes, minRpm ?? this.minRpm,
          maxRpm ?? this.maxRpm,
          purpose: purpose ?? this.purpose,
          feel: feel ?? this.feel,
          execution: execution ?? this.execution,
          music: music ?? this.music,
          maxStddev: maxStddev,
          role: role ?? this.role,
          variant: clearVariant ? null : variant ?? this.variant,
          baseGear: clearGears ? null : baseGear ?? this.baseGear,
          gearTop: clearGears ? null : gearTop ?? this.gearTop);

  Map<String, Object?> toJson() => {
        'name': name,
        'minutes': minutes,
        'minRpm': minRpm,
        'maxRpm': maxRpm,
        'purpose': purpose,
        'feel': feel,
        'execution': execution,
        'music': music,
        'maxStddev': maxStddev,
        'role': role?.name,
        if (variant != null) 'variant': variant,
        if (baseGear != null) 'baseGear': baseGear,
        if (gearTop != null) 'gearTop': gearTop,
      };

  factory ProgramPart.fromJson(Map<String, dynamic> j) => ProgramPart(
        j['name'] as String? ?? 'Part',
        (j['minutes'] as num?)?.toDouble() ?? 5,
        (j['minRpm'] as num?)?.toDouble() ?? 80,
        (j['maxRpm'] as num?)?.toDouble() ?? 90,
        purpose: j['purpose'] as String? ?? '',
        feel: j['feel'] as String? ?? '',
        execution: j['execution'] as String? ?? '',
        music: j['music'] as bool? ?? true,
        maxStddev: (j['maxStddev'] as num?)?.toDouble(),
        role: [for (final r in PartRole.values) if (r.name == j['role']) r].firstOrNull,
        variant: j['variant'] as String?,
        baseGear: (j['baseGear'] as num?)?.toInt(),
        gearTop: (j['gearTop'] as num?)?.toInt(),
      );
}

class Program {
  const Program(this.name, this.parts, {this.builtin = false});
  final String name;
  final List<ProgramPart> parts;
  final bool builtin;
  double get minutes => parts.fold(0, (a, p) => a + p.minutes);

  Program copyWith({String? name, List<ProgramPart>? parts}) =>
      Program(name ?? this.name, parts ?? this.parts);

  Map<String, Object?> toJson() => {'name': name, 'parts': [for (final p in parts) p.toJson()]};

  factory Program.fromJson(Map<String, dynamic> j) => Program(j['name'] as String? ?? 'Program', [
        for (final p in (j['parts'] as List? ?? [])) ProgramPart.fromJson(p as Map<String, dynamic>)
      ]);
}

/// Whether [p] is one of a class's activities (not the warm-up, cool-down,
/// stretch or a recovery).
bool isActivity(ProgramPart p) => switch (p.kind) {
      PartRole.warmup || PartRole.cooldown || PartRole.stretch || PartRole.recovery => false,
      _ => true,
    };

/// Recovery minutes after each of [n] activities (0 = none): one after every
/// second activity, shortened to [short] when two or fewer activities are
/// left before the cool-down, and none after the last.
List<double> recoveryPlan(int n, {double full = 2, double short = 1}) => [
      for (var i = 0; i < n; i++)
        i.isOdd && i < n - 1 ? (n - 1 - i <= 2 ? short : full) : 0,
    ];

/// [activities] with any half & half moved to the middle.
List<ProgramPart> halfAndHalfInMiddle(List<ProgramPart> activities) {
  final halves = [for (final p in activities) if (p.kind == PartRole.halfAndHalf) p];
  if (halves.isEmpty) return activities;
  final rest = [for (final p in activities) if (p.kind != PartRole.halfAndHalf) p];
  final at = (rest.length + 1) ~/ 2;
  return [...rest.sublist(0, at), ...halves, ...rest.sublist(at)];
}

/// Whether [acts] has two neighbouring activities of the same kind (a
/// recovery between them doesn't help, so neighbours in the list are enough).
bool hasRepeatedNeighbour(List<ProgramPart> acts) {
  for (var i = 1; i < acts.length; i++) {
    if (activityFamily(acts[i].kind) == activityFamily(acts[i - 1].kind)) return true;
  }
  return false;
}

/// Roles that feel alike to ride (climb and hill climb, sprint and surge);
/// auto-fill keeps members of one family apart.
PartRole activityFamily(PartRole r) => switch (r) {
      PartRole.hillClimb || PartRole.stepPyramid => PartRole.climb,
      PartRole.surge || PartRole.tabata || PartRole.pyramid => PartRole.sprint,
      _ => r,
    };

/// [activities] (half & half in the middle) reordered so that, where
/// possible, no two neighbouring activities are the same kind, e.g. never two
/// sprints back to back or with only a recovery between them. The order is
/// kept when it is already fine; if repeats can't be avoided (say, only
/// sprints) the fewest are left.
List<ProgramPart> spreadActivities(List<ProgramPart> activities) {
  final placed = halfAndHalfInMiddle(activities);
  if (!hasRepeatedNeighbour(placed)) return placed;
  final pinned = <int, ProgramPart>{
    for (var i = 0; i < placed.length; i++)
      if (placed[i].kind == PartRole.halfAndHalf) i: placed[i],
  };
  final pool = [for (final p in placed) if (p.kind != PartRole.halfAndHalf) p];
  final out = List<ProgramPart?>.filled(placed.length, null);
  pinned.forEach((i, p) => out[i] = p);
  for (var i = 0; i < out.length; i++) {
    if (out[i] != null) continue;
    final prevPart = i > 0 ? out[i - 1] : null;
    final nextPart = i + 1 < out.length ? out[i + 1] : null;
    final prev = prevPart == null ? null : activityFamily(prevPart.kind);
    final next = nextPart == null ? null : activityFamily(nextPart.kind);
    final counts = <PartRole, int>{};
    for (final p in pool) {
      final f = activityFamily(p.kind);
      counts[f] = (counts[f] ?? 0) + 1;
    }
    // Most plentiful kind first (so the commonest can still be separated),
    // earliest in the original order on ties; kinds clashing with a neighbour last.
    var best = -1;
    var bestScore = -1 << 30;
    for (var k = 0; k < pool.length; k++) {
      final kind = activityFamily(pool[k].kind);
      final clash = (kind == prev ? 1 : 0) + (kind == next ? 1 : 0);
      final score = -clash * 1000 + counts[kind]!;
      if (score > bestScore) {
        bestScore = score;
        best = k;
      }
    }
    out[i] = pool.removeAt(best);
  }
  return [for (final p in out) p!];
}

/// The main block of a class (between warm-up and cool-down): the activities
/// in [parts] (any recoveries in it are dropped) with the half & half in the
/// middle (unless [keepOrder]) and a [recovery] after every two activities,
/// see [recoveryPlan]. With [minutes], the activities other than the half &
/// half are scaled (their minutes act as weights) so the block lasts exactly
/// that long.
List<ProgramPart> layoutMainBlock(List<ProgramPart> parts,
    {required ProgramPart Function(double minutes) recovery,
    double recoveryMinutes = 2,
    double shortRecoveryMinutes = 1,
    double? minutes,
    bool keepOrder = false}) {
  var acts = [for (final p in parts) if (isActivity(p)) p];
  if (!keepOrder) acts = spreadActivities(acts);
  final plan = recoveryPlan(acts.length, full: recoveryMinutes, short: shortRecoveryMinutes);
  if (minutes != null) {
    bool half(ProgramPart p) => p.kind == PartRole.halfAndHalf;
    final fixed = plan.fold<double>(0, (a, m) => a + m) +
        acts.where(half).fold<double>(0, (a, p) => a + p.minutes);
    final fitted = fitMinutes([for (final p in acts) if (!half(p)) p], minutes - fixed);
    var k = 0;
    acts = [for (final p in acts) half(p) ? p : fitted[k++]];
  }
  return [
    for (var i = 0; i < acts.length; i++) ...[
      acts[i],
      if (plan[i] > 0) recovery(plan[i]),
    ],
  ];
}

/// [parts] with their minutes (used as weights) scaled to add up to
/// [target], each rounded to the nearest half minute and at least 1.
List<ProgramPart> fitMinutes(List<ProgramPart> parts, double target) {
  if (parts.isEmpty) return parts;
  final sum = parts.fold<double>(0, (a, p) => a + p.minutes);
  final mins = [for (final p in parts) max(1.0, (p.minutes * target / sum * 2).round() / 2)];
  var diff = target - mins.fold<double>(0, (a, m) => a + m);
  while (diff.abs() >= 0.25) {
    // nudge the longest part (or the shortest above the 1 min floor when trimming)
    final step = diff > 0 ? 0.5 : -0.5;
    var at = 0;
    for (var i = 1; i < mins.length; i++) {
      if (mins[i] > mins[at]) at = i;
    }
    if (mins[at] + step < 1) break;
    mins[at] += step;
    diff -= step;
  }
  return [for (var i = 0; i < parts.length; i++) parts[i].copyWith(minutes: mins[i])];
}

const classicProgramName = 'Classic 8-part class';

final classicProgram = Program(classicProgramName, const [
  ProgramPart('The Warm-Up', 4.5, 80, 90,
      purpose: 'Wake up the muscles, lubricate joints, set mental focus.',
      feel: 'Flat road, light-to-moderate resistance.',
      execution:
          'Easy spin at 80–90 RPM, add a touch of resistance (base gear) halfway through.',
      maxStddev: 8),
  ProgramPart('The Transition / Seated Flat', 4.5, 85, 95,
      purpose: 'Establish the baseline working zone.',
      feel: 'Moderate effort; breathing quickens but talking is still easy.',
      execution: 'Steady flat road, moderate resistance. Add short 15-second accelerations.'),
  ProgramPart('The First Climb: Strength & Power', 8.5, 60, 70,
      purpose: 'Build muscular endurance and torch calories.',
      feel: 'Heavy, slow and deliberate.',
      execution:
          'Load heavy resistance at 60–70 RPM. Alternate 1 min seated / 1 min standing (Position 3).',
      maxStddev: 6),
  ProgramPart('Recovery', 1, 70, 85,
      role: PartRole.recovery,
      purpose: 'A quick breather before the final push.',
      feel: 'Easy, flat road.',
      execution: 'Drop the resistance, sit down and breathe.'),
  ProgramPart('High-Intensity Intervals: Speed & Breathlessness', 7, 90, 105,
      purpose: 'Spike the heart rate and trigger the anaerobic system.',
      feel: 'Fast, breathless and challenging.',
      execution: 'Moderate working flat. 30 s on (90–100+ RPM) / 30 s off, repeat 4–6 times.',
      role: PartRole.tabata,
      variant: '30-30'),
  ProgramPart('The Mixed Terrain / The Peak', 8.5, 70, 100,
      purpose: 'Climax of the class, combining strength and speed.',
      feel: 'Maximum effort; the hardest part of the ride.',
      execution:
          'Rolling hills and jumps (sit/stand every 4 or 8 counts). Finish with a 60-second all-out sprint.',
      role: PartRole.standSitHover),
  ProgramPart('Cool-Down & Active Recovery', 3.5, 60, 70,
      purpose: 'Flush out lactic acid and safely lower the heart rate.',
      feel: 'Easy, breezy spinning.',
      execution: 'Drop resistance to a tiny safety gear, 60–70 RPM, deep belly breathing.'),
  ProgramPart('Post-Ride Stretch', 2.5, 55, 70,
      purpose: 'Prevent tightness and improve flexibility off the bike.',
      feel: 'Calm.',
      execution: 'Dismount; stretch quads, hamstrings, glutes, calves, chest and shoulders.',
      music: true),
]);

Program _intervals(String name, int minutes, int rounds, double climbMin, double sprintMin) {
  const warm = ProgramPart('Warm-up', 5, 80, 90, maxStddev: 8);
  const cool = ProgramPart('Cool-down', 5, 60, 70);
  // Each round swaps in different activities so no two rounds repeat.
  final climbs = [
    ProgramPart('Climb', climbMin, 60, 70, maxStddev: 6),
    ProgramPart('Hill Climb', climbMin, 60, 90, role: PartRole.hillClimb),
    // one short song (see partQuery)
    const ProgramPart('Half & Half', 3, 70, 85, role: PartRole.halfAndHalf),
    ProgramPart('Stand-Sit-Hover', climbMin, 60, 75, role: PartRole.standSitHover),
  ];
  final sprints = [
    ProgramPart('Sprint', sprintMin, 90, 105),
    ProgramPart('Tabata', sprintMin, 90, 110, role: PartRole.tabata, variant: '20-10'),
    ProgramPart('Pyramid', sprintMin, 85, 105, role: PartRole.pyramid),
    ProgramPart('Surge', sprintMin, 90, 110, role: PartRole.surge),
  ];
  return Program(name, [
    warm,
    ...layoutMainBlock([
      for (var i = 0; i < rounds; i++) ...[
        climbs[i % climbs.length],
        sprints[i % sprints.length],
      ],
    ],
        minutes: minutes - warm.minutes - cool.minutes,
        recovery: (m) => ProgramPart('Recovery', m, 70, 85, role: PartRole.recovery)),
    cool,
  ], builtin: true);
}

final builtinPrograms = [
  Program(classicProgramName, classicProgram.parts, builtin: true),
  _intervals('30 min intervals', 30, 2, 5, 3),
  _intervals('45 min intervals', 45, 3, 5, 3),
  _intervals('60 min intervals', 60, 4, 6, 3),
];

/// Search for one part on top of [base] (the Mix filters for the part's
/// role): its RPM range matched against song BPM, also half and double time.
SongQuery partQuery(ProgramPart p, SongQuery base,
    {Set<String> exclude = const {}, int limit = 200}) {
  final q = base.copyWith(
      targetRpm: p.targetRpm,
      rpmTolerance: p.rpmTolerance,
      maxStddev: p.maxStddev,
      exclude: exclude,
      limit: limit);
  // half & half works best on one short song (about 3 minutes)
  return p.kind == PartRole.halfAndHalf ? q.copyWith(minSeconds: 150, maxSeconds: 240) : q;
}

/// Tempo distance between two songs; half and double time count as a match.
double bpmJump(double a, double b) =>
    [(a - b).abs(), (a - b * 2).abs(), (a - b / 2).abs()].reduce(min);

const bigJumpBpm = 15.0;

/// Indexes i where song i+1 is a big tempo jump from song i.
List<int> bigJumps(List<Song> mix, {double threshold = bigJumpBpm}) => [
      for (var i = 0; i + 1 < mix.length; i++)
        if (mix[i].medianBpm != null &&
            mix[i + 1].medianBpm != null &&
            bpmJump(mix[i].medianBpm!, mix[i + 1].medianBpm!) > threshold)
          i
    ];

/// Random pick where higher-rated songs are more likely; null if none.
Song? pickWeighted(List<Song> candidates, Random random) {
  if (candidates.isEmpty) return null;
  final total = candidates.fold<int>(0, (a, s) => a + 1 + s.rating);
  var n = random.nextInt(total);
  for (final s in candidates) {
    n -= 1 + s.rating;
    if (n < 0) return s;
  }
  return candidates.last;
}

String _esc(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

String _clock(double sec) {
  final s = sec.round();
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

String _rpm(double lo, double hi) =>
    lo.round() == hi.round() ? '${lo.round()} RPM' : '${lo.round()}–${hi.round()} RPM';

String _date(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// Printable HTML run sheet for the instructor: a header, an overview of the
/// program's parts, then every song with its start time, tempo and (for
/// patterned parts) the timed cue list from [buildPartPlans].
String buildClassSheet(String name, List<Song> mix,
    {Program? program,
    List<int?>? parts,
    DateTime? date,
    int baseGear = 12,
    Map<String, String> notes = const {}}) {
  int? partOf(int i) {
    final pi = parts != null && i < parts.length ? parts[i] : null;
    return program != null && pi != null && pi >= 0 && pi < program.parts.length ? pi : null;
  }

  final total = mix.fold<double>(0, (a, s) => a + (s.playSeconds ?? 0));
  final b = StringBuffer()
    ..writeln('<!DOCTYPE html><html><head><meta charset="utf-8">')
    ..writeln('<title>${_esc(name)}</title><style>')
    ..writeln('body{font-family:sans-serif;margin:2em}table{border-collapse:collapse;width:100%}')
    ..writeln('th,td{border-bottom:1px solid #999;padding:6px;text-align:left;vertical-align:top}')
    ..writeln('h2{background:#eee;padding:6px;margin-bottom:0}.exec{margin:4px 6px}')
    ..writeln('ul.cues{margin:4px 0 0 0;padding-left:1.2em;font-size:90%}.cue{color:#555}')
    ..writeln('.note{font-style:italic;margin-top:2px}')
    ..writeln('@media print{body{margin:0;color:#000;background:#fff;font-size:12pt}'
        'h2{background:none;border-bottom:2px solid #000}.cue{color:#000}'
        'th,td{border-bottom:1px solid #000}'
        'section.part+section.part{page-break-before:always;break-before:page}'
        'tbody.song{page-break-inside:avoid;break-inside:avoid}}')
    ..writeln('</style></head><body>')
    ..writeln('<header><h1>${_esc(name)}</h1><p class="meta">')
    ..writeln([
      if (program != null) 'Program: ${_esc(program.name)}',
      'Total class time: ${_clock(total)}',
      'Base gear: $baseGear',
      'Date: ${_date(date ?? DateTime.now())}',
    ].join(' · '))
    ..writeln('</p></header>');

  if (program != null) {
    final count = List.filled(program.parts.length, 0);
    final secs = List.filled(program.parts.length, 0.0);
    for (var i = 0; i < mix.length; i++) {
      final pi = partOf(i);
      if (pi == null) continue;
      count[pi]++;
      secs[pi] += mix[i].playSeconds ?? 0;
    }
    b.writeln('<table class="overview"><tr><th>Part</th><th>Role</th><th>Planned</th>'
        '<th>RPM</th><th>Gear</th><th>Songs</th><th>Time</th></tr>');
    for (var pi = 0; pi < program.parts.length; pi++) {
      final p = program.parts[pi];
      b.writeln('<tr class="ov-part"><td>${_esc(p.name)}</td><td>${_esc(p.kind.label)}</td>'
          '<td>${_clock(p.minutes * 60)}</td><td>${_rpm(p.minRpm, p.maxRpm)}</td>'
          '<td>base ${p.baseGear ?? baseGear}${p.gearTop == null ? '' : ', top +${p.gearTop}'}</td>'
          '<td>${count[pi]}</td><td>${_clock(secs[pi])}</td></tr>');
    }
    b.writeln('</table>');
  }

  var t = 0.0;
  for (var i = 0; i < mix.length;) {
    final pi = partOf(i);
    final p = pi == null ? null : program!.parts[pi];
    b.writeln('<section class="part">');
    if (p != null) {
      b.writeln('<h2>${_esc(p.name)} — ${_rpm(p.minRpm, p.maxRpm)}, '
          '${p.minutes.toStringAsFixed(1)} min</h2>');
      if (p.execution.isNotEmpty) b.writeln('<p class="exec">${_esc(p.execution)}</p>');
    }
    b.writeln('<table><thead><tr><th>#</th><th>Start</th><th>Song</th><th>BPM</th>'
        '<th>Length</th></tr></thead>');
    var runEnd = i;
    while (runEnd < mix.length && partOf(runEnd) == pi) {
      runEnd++;
    }
    final runStart = i;
    final plans = p == null
        ? null
        : buildPartPlans(p, [for (var k = i; k < runEnd; k++) mix[k].playSeconds]);
    do {
      final s = mix[i];
      final bpm = s.medianBpm == null ? '-' : s.medianBpm!.round().toString();
      final segs = plans?[i - runStart].segments;
      final cues = segs == null || segs.length < 2
          ? ''
          : '<ul class="cues">${[
              for (final g in segs)
                '<li>${_clock(g.start)} ${_esc(g.label)} · ${_rpm(g.minRpm, g.maxRpm)}'
                    '${g.gear == null ? '' : ' · Gear ${absoluteGear(p!.baseGear ?? baseGear, g.gear!)}'}'
                    '${g.cue == null ? '' : ' <span class="cue">— ${_esc(g.cue!)}</span>'}</li>'
            ].join()}</ul>';
      final note = notes[s.path];
      final noteHtml = note == null || note.isEmpty ? '' : '<div class="note">💬 ${_esc(note)}</div>';
      b.writeln('<tbody class="song"><tr><td>${i + 1}</td><td>${_clock(t)}</td>'
          '<td>${_esc(s.display)}$noteHtml$cues</td><td>$bpm</td>'
          '<td>${s.playSeconds == null ? '' : _clock(s.playSeconds!)}</td></tr></tbody>');
      t += s.playSeconds ?? 0;
      i++;
    } while (i < mix.length && partOf(i) == pi);
    b.writeln('</table></section>');
  }
  b.writeln('<p>Total: ${_clock(total)}</p></body></html>');
  return b.toString();
}

/// Whether [bpm], folded by half/double time, falls within [lo]..[hi].
bool bpmInBand(double bpm, double lo, double hi) {
  final f = foldToBand(bpm, lo, hi);
  return f >= lo && f <= hi;
}
