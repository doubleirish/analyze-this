import 'dart:math';

import 'activities.dart';
import 'planner.dart';

/// Typical indoor-cycling class formats.
enum ClassStyle {
  endurance('Endurance', 'Long steady aerobic work with short surges.'),
  intervals('Intervals', 'Rounds of climb, sprint and recovery.'),
  hills('Hills', 'Rolling climbs with growing resistance and flat recoveries.'),
  pyramid('Pyramid', 'Efforts that build up in length to a peak, then come back down.'),
  tabata('Tabata', 'Four-minute hard/easy sets separated by recovery.'),
  rhythm('Rhythm', 'Beat-matched riding: flats, jumps and rolling climbs.'),
  raceDay('Race day', 'Tempo and threshold efforts, a long climb and a finishing sprint.'),
  skills('Skills & drills', 'Half & half, stand-sit-hover, pyramid and surge blocks.'),
  aerobic('Beginner aerobic', 'Foundational cardio: steady pace with short, manageable intervals.'),
  fartlek('Cycle fartlek', 'Unstructured speed play: fast and slow efforts of varying length, by feel.'),
  sweetSpot('Sweet spot base', 'Long steady blocks just below threshold to build aerobic base and muscular endurance.'),
  strength('Climbing / strength', 'Heavy resistance at 60–80 RPM, seated and standing climbs.'),
  speed('Speed / sprint', 'Repeated high-cadence sprints (110–120 RPM) with recovery spins.'),
  mixed('Mixed', 'A blend of steady riding, climbs, tabata, skills and surges.');

  const ClassStyle(this.label, this.blurb);
  final String label;
  final String blurb;
}

enum Intensity { easy, moderate, hard }

/// Fixed built-in programs: each themed style at 30/45/55 min, plus two
/// differently seeded mixed programs per length. Seeds are fixed so the
/// programs are identical on every launch.
final themedBuiltins = () {
  const lengths = [30, 45, 55];
  const themes = [
    ClassStyle.aerobic,
    ClassStyle.fartlek,
    ClassStyle.sweetSpot,
    ClassStyle.tabata,
    ClassStyle.strength,
    ClassStyle.speed,
  ];
  Program build(ClassStyle s, int m, int seed, String name) {
    final p = generateProgram(minutes: m, style: s, random: Random(seed));
    return Program(name, p.parts, builtin: true);
  }

  return [
    for (final m in lengths)
      for (final s in themes)
        build(s, m, m * 31 + s.index, '${s == ClassStyle.tabata ? 'Tabata / HIIT' : s.label} · $m min'),
    for (final m in lengths)
      for (var v = 0; v < 2; v++)
        build(ClassStyle.mixed, m, m * 17 + v * 101 + 7, 'Mixed ${'AB'[v]} · $m min'),
  ];
}();

const minGeneratedMinutes = 20;
const maxGeneratedMinutes = 75;

/// The fixed parts that sit around the main block, in class order.
const bookendRoles = [PartRole.warmup, PartRole.cooldown, PartRole.stretch];

/// Which of the fixed parts a generated class includes. A part that is left
/// out gives its minutes to the main block, so the class keeps its length.
class Bookends {
  const Bookends({this.warmUp = true, this.coolDown = true, this.stretch = true});

  factory Bookends.fromJson(Map<String, dynamic> j) => Bookends(
        warmUp: j['warmUp'] as bool? ?? true,
        coolDown: j['coolDown'] as bool? ?? true,
        stretch: j['stretch'] as bool? ?? true,
      );

  final bool warmUp, coolDown, stretch;

  bool includes(PartRole role) => switch (role) {
        PartRole.warmup => warmUp,
        PartRole.cooldown => coolDown,
        PartRole.stretch => stretch,
        _ => true,
      };

  Bookends withRole(PartRole role, bool on) => Bookends(
        warmUp: role == PartRole.warmup ? on : warmUp,
        coolDown: role == PartRole.cooldown ? on : coolDown,
        stretch: role == PartRole.stretch ? on : stretch,
      );

  Map<String, dynamic> toJson() =>
      {'warmUp': warmUp, 'coolDown': coolDown, 'stretch': stretch};

  @override
  bool operator ==(Object other) =>
      other is Bookends &&
      other.warmUp == warmUp &&
      other.coolDown == coolDown &&
      other.stretch == stretch;

  @override
  int get hashCode => Object.hash(warmUp, coolDown, stretch);

  @override
  String toString() => 'Bookends(warmUp: $warmUp, coolDown: $coolDown, stretch: $stretch)';
}

/// Length of each fixed part for a class of [total] minutes. The stretch grows
/// with the class (1 min on short classes, 2 from 44 minutes up).
double bookendMinutes(PartRole role, int total) => switch (role) {
      PartRole.warmup => (total * 0.1).round().clamp(4, 7).toDouble(),
      PartRole.cooldown => (total * 0.08).round().clamp(3, 5).toDouble(),
      PartRole.stretch => (((total * 0.04) * 2).round() / 2).clamp(1.0, 2.0),
      _ => 0.0,
    };

/// The warm-up, cool-down or stretch for a class of [total] minutes.
ProgramPart bookendPart(PartRole role, int total) {
  final m = bookendMinutes(role, total);
  return switch (role) {
    PartRole.warmup => ProgramPart('Warm-up', m, 80, 90,
        role: PartRole.warmup,
        maxStddev: 8,
        purpose: 'Wake up the muscles and set your focus.',
        feel: 'Flat road, light resistance.',
        execution: 'Easy spin at 80–90 RPM, add a little resistance halfway through.'),
    PartRole.cooldown => ProgramPart('Cool-down', m, 60, 70,
        role: PartRole.cooldown,
        purpose: 'Bring the heart rate down safely.',
        feel: 'Easy, breezy spinning.',
        execution: 'Drop to a light gear at 60–70 RPM and breathe deeply.'),
    PartRole.stretch => ProgramPart('Stretch', m, 55, 70,
        role: PartRole.stretch,
        purpose: 'Prevent tightness off the bike.',
        feel: 'Calm.',
        execution: 'Stretch quads, hamstrings, glutes, calves, chest and shoulders.'),
    _ => throw ArgumentError('$role is not a bookend'),
  };
}

/// What a bookend switch is called in the wizard.
String bookendLabel(PartRole role) => switch (role) {
      PartRole.warmup => 'Warm-up',
      PartRole.cooldown => 'Cool-down',
      _ => 'Stretch',
    };

/// A name that doesn't clash with any of [existing] (case-insensitive).
String uniqueProgramName(String base, Iterable<String> existing) {
  final taken = {for (final e in existing) e.trim().toLowerCase()};
  if (!taken.contains(base.toLowerCase())) return base;
  for (var i = 2;; i++) {
    final n = '$base ($i)';
    if (!taken.contains(n.toLowerCase())) return n;
  }
}

/// Builds a class of [minutes] in the given [style]: warm-up, a main block,
/// cool-down and a stretch. [bookends] chooses which of those fixed parts are
/// included; one left out gives its minutes to the main block. Part lengths
/// always add up to [minutes]. [random] varies round counts, order and lengths.
Program generateProgram({
  required int minutes,
  required ClassStyle style,
  Intensity intensity = Intensity.moderate,
  Bookends bookends = const Bookends(),
  Random? random,
}) {
  final total = minutes.clamp(minGeneratedMinutes, maxGeneratedMinutes);
  final rnd = random ?? Random();
  final fixed = [
    for (final r in bookendRoles)
      if (bookends.includes(r)) bookendPart(r, total)
  ];
  final main = total - fixed.fold<double>(0, (a, p) => a + p.minutes);

  final b = _Builder(intensity, rnd);
  // Every class has one short half & half song (base, a minute per leg, base),
  // placed in the middle of the main block.
  const halfMinutes = 3.0;
  final budget = (main - halfMinutes).floor();
  final body = switch (style) {
    ClassStyle.endurance => _endurance(b, budget),
    ClassStyle.intervals => _intervals(b, budget),
    ClassStyle.hills => _hills(b, budget),
    ClassStyle.pyramid => _pyramid(b, budget),
    ClassStyle.tabata => _tabata(b, budget),
    ClassStyle.rhythm => _rhythm(b, budget),
    ClassStyle.raceDay => _raceDay(b, budget),
    ClassStyle.skills => _skills(b, budget),
    ClassStyle.aerobic => _aerobic(b, budget),
    ClassStyle.fartlek => _fartlek(b, budget),
    ClassStyle.sweetSpot => _sweetSpot(b, budget),
    ClassStyle.strength => _strength(b, budget),
    ClassStyle.speed => _speed(b, budget),
    ClassStyle.mixed => _mixed(b, budget),
  };
  final half = halfAndHalfPart();
  final rest = RecoveryStyle.of(style, intensity);

  final parts = [
    for (final p in fixed)
      if (p.kind == PartRole.warmup) p,
    ...rest.layout([...body, half], main),
    for (final p in fixed)
      if (p.kind != PartRole.warmup) p,
  ];
  final name = generatedProgramName(style, parts.length, total);
  return Program(name, parts);
}

String generatedProgramName(ClassStyle style, int parts, int minutes) =>
    '${style.label} · $parts parts · $minutes min';

/// One short half & half song: base, a minute per leg, back to base.
ProgramPart halfAndHalfPart() => const ProgramPart('Half & half', 3, 70, 85,
    role: PartRole.halfAndHalf,
    purpose: 'Smooth pedal stroke and single-leg strength.',
    feel: 'Light to moderate resistance; one leg at a time.',
    execution: 'Base speed, one minute right leg, one minute left leg, back to base.');

/// How a class style recovers between activities: about 2 minutes after every
/// second activity (longer on easy classes, shorter on hard ones).
class RecoveryStyle {
  RecoveryStyle._(this._b, this.name);

  factory RecoveryStyle.of(ClassStyle style, Intensity intensity) =>
      RecoveryStyle._(
          _Builder(intensity, Random(0)),
          switch (style) {
            ClassStyle.hills => 'Flat road',
            ClassStyle.tabata => 'Tabata rest',
            ClassStyle.aerobic => 'Easy spin',
            ClassStyle.strength => 'Flat recovery',
            ClassStyle.speed => 'Recovery spin',
            _ => 'Recovery',
          });

  final _Builder _b;
  final String name;
  double get minutes => max(1.0, (2 * _b.restScale * 2).round() / 2);
  double get shortMinutes => max(1.0, minutes.round() / 2);

  /// The main block for [activities] lasting [total] minutes, see [layoutMainBlock].
  List<ProgramPart> layout(List<ProgramPart> activities, double total, {bool keepOrder = false}) =>
      layoutMainBlock(activities,
          minutes: total,
          keepOrder: keepOrder,
          recoveryMinutes: minutes,
          shortRecoveryMinutes: shortMinutes,
          recovery: (m) => _b.recover(1, name).copyWith(minutes: m));

  /// Whether [activities] fit in [total] minutes with their recoveries
  /// (every activity needs at least a minute).
  bool fits(List<ProgramPart> activities, double total) {
    final plan = recoveryPlan(activities.length, full: minutes, short: shortMinutes);
    var need = plan.fold<double>(0, (a, m) => a + m);
    var flexible = 0;
    for (final p in activities) {
      if (p.kind == PartRole.halfAndHalf) {
        need += p.minutes;
      } else {
        need += 1;
        flexible++;
      }
    }
    return flexible > 0 && need <= total + 0.01;
  }
}

/// Every activity the wizard can add, with the cadence for [intensity]. The
/// minutes are a typical length; the program is re-fitted when one is added.
List<ProgramPart> activityCatalog([Intensity intensity = Intensity.moderate]) {
  final b = _Builder(intensity, Random(0));
  return [
    b.part('Steady flat', 5, 85, 95, PartRole.steady,
        purpose: 'Hold a solid aerobic pace.',
        feel: 'Comfortably hard.',
        execution: 'Steady flat road, stay seated.'),
    b.part('Sweet spot', 8, 85, 92, PartRole.steady,
        purpose: 'Build aerobic base and muscular endurance.',
        feel: 'Comfortably hard; short sentences only.',
        execution: 'Hold a strong, even effort just below threshold.'),
    b.part('Hill climb', 5, 60, 90, PartRole.hillClimb,
        maxStddev: 6,
        purpose: 'Resistance up, cadence down, then spin back up.',
        feel: 'Heavy, then light and fast.',
        execution: 'Add resistance in steps; after the summit drop the load and spin up.'),
    b.part('Heavy climb', 6, 60, 80, PartRole.hillClimb,
        maxStddev: 6,
        purpose: 'Build lower-body strength with heavy resistance.',
        feel: 'Heavy, slow and deliberate.',
        execution: 'Heavy resistance at 60–80 RPM; alternate seated and standing climbs.'),
    b.pyramidClimb('Step pyramid', 7),
    b.part('Stand-sit-hover', 5, 65, 80, PartRole.standSitHover,
        maxStddev: 6,
        purpose: 'Body position control at moderate resistance.',
        feel: 'Controlled and balanced.',
        execution: 'Rotate stand, sit and hover; keep the resistance steady.'),
    halfAndHalfPart(),
    b.sprint('Sprint', 3),
    b.sprint('High-cadence sprint', 3,
        lo: 110,
        hi: 120,
        execution: 'High-cadence sprints at 110–120 RPM, light-to-moderate resistance.'),
    b.sprint('Jumps', 4,
        lo: 90, hi: 110, execution: 'Jumps: stand and sit every 4 or 8 beats.'),
    b.part('Surge', 4, 90, 100, PartRole.surge,
        purpose: 'Repeated bursts of speed.',
        feel: 'Steady with sharp lifts.',
        execution: 'Surge, then settle back to your base cadence.'),
    b.part('Pyramid', 5, 85, 100, PartRole.pyramid,
        purpose: 'Build to a peak effort and back down.',
        feel: 'Hard at the top, controlled on the way down.',
        execution: 'Efforts grow to a peak, then shrink, with short recoveries between.'),
    for (final v in tabataVariants)
      b.part('Tabata (${v.label})', 4, 95, 110, PartRole.tabata,
          variant: v.id,
          purpose: 'Short, hard work/rest intervals.',
          feel: 'All out, then just enough rest.',
          execution: '${v.label}, repeated to the end of the song.'),
  ];
}

/// A generated program being rearranged: the warm-up, cool-down and stretch
/// stay put around [activities], which can be moved, added and removed. Each
/// of those fixed parts can also be switched off, giving its minutes to the
/// main block. The main block is laid out again on every [build], so a
/// recovery still follows every second activity and the class keeps its length.
class ProgramDraft {
  ProgramDraft._(this.style, this.rest, this._templates, this._on, this.activities, this.minutes);

  factory ProgramDraft.of(Program p,
      {ClassStyle style = ClassStyle.mixed, Intensity intensity = Intensity.moderate}) {
    final parts = p.parts;
    var start = 0;
    while (start < parts.length && parts[start].kind == PartRole.warmup) {
      start++;
    }
    var end = parts.length;
    while (end > start &&
        (parts[end - 1].kind == PartRole.cooldown || parts[end - 1].kind == PartRole.stretch)) {
      end--;
    }
    final fixed = [...parts.sublist(0, start), ...parts.sublist(end)];
    final total = p.minutes.round().clamp(minGeneratedMinutes, maxGeneratedMinutes);
    ProgramPart template(PartRole r) {
      for (final x in fixed) {
        if (x.kind == r) return x;
      }
      return bookendPart(r, total);
    }

    return ProgramDraft._(
        style,
        RecoveryStyle.of(style, intensity),
        {for (final r in bookendRoles) r: template(r)},
        {for (final r in bookendRoles) r: fixed.any((x) => x.kind == r)},
        [for (final x in parts.sublist(start, end)) if (isActivity(x)) x],
        p.minutes);
  }

  final ClassStyle style;
  final RecoveryStyle rest;

  /// The part used for each bookend role, whether it is switched on or not.
  final Map<PartRole, ProgramPart> _templates;
  final Map<PartRole, bool> _on;

  /// In class order; their minutes are weights for fitting the main block.
  final List<ProgramPart> activities;

  /// Length of the whole class.
  double minutes;

  /// Changes the class length, keeping the activities (their minutes are
  /// fitted again); activities are dropped from the end while they no longer
  /// fit. Returns how many were dropped.
  int setMinutes(double m) {
    minutes = m;
    var dropped = 0;
    while (activities.length > 1 && !rest.fits(activities, mainMinutes)) {
      activities.removeLast();
      dropped++;
    }
    return dropped;
  }

  List<ProgramPart> get head =>
      [if (_on[PartRole.warmup]!) _templates[PartRole.warmup]!];

  List<ProgramPart> get tail => [
        for (final r in [PartRole.cooldown, PartRole.stretch])
          if (_on[r]!) _templates[r]!
      ];

  /// The warm-up, cool-down or stretch for [role], switched on or not.
  ProgramPart bookend(PartRole role) => _templates[role]!;

  bool included(PartRole role) => _on[role] ?? false;

  Bookends get bookends => Bookends(
        warmUp: included(PartRole.warmup),
        coolDown: included(PartRole.cooldown),
        stretch: included(PartRole.stretch),
      );

  double _mainFor(Map<PartRole, bool> on) =>
      minutes -
      [
        for (final r in bookendRoles)
          if (on[r]!) _templates[r]!.minutes
      ].fold<double>(0, (a, m) => a + m);

  /// Whether [role] can be switched [on]: switching one on takes minutes away
  /// from the main block, so the activities have to still fit.
  bool canSetIncluded(PartRole role, bool on) {
    if (!_on.containsKey(role)) return false;
    if (_on[role] == on || !on) return true;
    return rest.fits(activities, _mainFor({..._on, role: true}));
  }

  /// Switches the warm-up, cool-down or stretch on or off, keeping the
  /// activities; false if there is no room for it.
  bool setIncluded(PartRole role, bool on) {
    if (!canSetIncluded(role, on)) return false;
    _on[role] = on;
    return true;
  }

  double get mainMinutes => _mainFor(_on);

  bool canAdd(ProgramPart p) => rest.fits([...activities, p], mainMinutes);

  bool canRemove(int i) =>
      rest.fits([...activities.sublist(0, i), ...activities.sublist(i + 1)], mainMinutes);

  /// Adds [p] before activity [at] (or at the end); false if it doesn't fit.
  bool insert(int at, ProgramPart p) {
    if (!canAdd(p)) return false;
    activities.insert(at.clamp(0, activities.length), p);
    return true;
  }

  ProgramPart? removeAt(int i) => canRemove(i) ? activities.removeAt(i) : null;

  /// Moves activity [from] so it ends up at index [to].
  void move(int from, int to) => activities.insert(to, activities.removeAt(from));

  /// The main block: activities with their fitted minutes and recoveries.
  List<ProgramPart> get mainBlock => rest.layout(activities, mainMinutes, keepOrder: true);

  Program build() {
    final parts = [...head, ...mainBlock, ...tail];
    return Program(generatedProgramName(style, parts.length, minutes.round()), parts);
  }
}

class _Builder {
  _Builder(this.intensity, this.rnd);
  final Intensity intensity;
  final Random rnd;

  // cadence shifts: efforts go faster and climbs heavier (slower) when harder
  int get _fast => switch (intensity) { Intensity.easy => -8, Intensity.moderate => 0, Intensity.hard => 5 };
  int get _slow => switch (intensity) { Intensity.easy => 5, Intensity.moderate => 0, Intensity.hard => -5 };
  double get restScale => switch (intensity) { Intensity.easy => 1.3, Intensity.moderate => 1.0, Intensity.hard => 0.75 };

  /// [weight] is a relative length; [fitMinutes] turns weights into minutes.
  ProgramPart part(String name, double weight, double lo, double hi, PartRole role,
      {String purpose = '',
      String feel = '',
      String execution = '',
      double? maxStddev,
      String? variant}) {
    final shift = switch (role) {
      PartRole.sprint || PartRole.tabata || PartRole.pyramid || PartRole.surge => _fast,
      PartRole.steady => _fast ~/ 2,
      PartRole.climb || PartRole.hillClimb || PartRole.standSitHover || PartRole.stepPyramid => _slow,
      _ => 0,
    };
    final w = role == PartRole.recovery ? weight * restScale : weight;
    return ProgramPart(name, w, (lo + shift).clamp(50, 120).toDouble(),
        (hi + shift).clamp(50, 125).toDouble(),
        role: role,
        purpose: purpose,
        feel: feel,
        execution: execution,
        maxStddev: maxStddev,
        variant: variant);
  }

  ProgramPart recover(double weight, [String name = 'Recovery']) => part(
      name, weight, 70, 85, PartRole.recovery,
      purpose: 'Let the heart rate drop before the next effort.',
      feel: 'Easy, flat road.',
      execution: 'Drop the resistance, sit down and breathe.');

  ProgramPart climb(String name, double weight, {double lo = 60, double hi = 70, String? execution}) =>
      part(name, weight, lo, hi, PartRole.climb,
          maxStddev: 6,
          purpose: 'Build strength and muscular endurance.',
          feel: 'Heavy, slow and deliberate.',
          execution: execution ?? 'Add resistance; alternate seated and standing every minute.');

  ProgramPart sprint(String name, double weight, {double lo = 90, double hi = 105, String? execution}) =>
      part(name, weight, lo, hi, PartRole.sprint,
          purpose: 'Spike the heart rate and build speed.',
          feel: 'Fast, breathless and challenging.',
          execution: execution ?? 'Moderate resistance, fast legs, stay controlled.');

  /// Strength work as a step pyramid: resistance goes up a step at a time to
  /// a peak, then a full drop-off into a sprint; longer than a plain climb.
  ProgramPart pyramidClimb(String name, double weight, {double lo = 65, double hi = 85, String? execution}) =>
      part(name, weight, lo, hi, PartRole.stepPyramid,
          maxStddev: 6,
          purpose: 'Build strength with progressive resistance, then release it in a sprint.',
          feel: 'Heavier and harder with every step, then a burst of speed.',
          execution: execution ??
              'Add resistance every step up to the peak; then drop it all off and sprint.');
}

List<ProgramPart> _endurance(_Builder b, int main) {
  final blocks = main >= 25 ? 2 + b.rnd.nextInt(2) : 2;
  return [
    for (var i = 0; i < blocks; i++) ...[
      b.part('Endurance flat ${i + 1}', 6, 85, 95, PartRole.steady,
          purpose: 'Build your aerobic base.',
          feel: 'Comfortably hard; you can speak in short sentences.',
          execution: 'Steady flat road, moderate resistance, stay seated.'),
      b.part('Surge ${i + 1}', 2, 90, 100, PartRole.surge,
          purpose: 'Short bursts of speed on top of a steady base.',
          feel: 'Steady with sharp lifts.',
          execution: 'Short surges: speed up, then settle back.'),
    ],
  ];
}

List<ProgramPart> _intervals(_Builder b, int main) {
  final rounds = (main ~/ 14).clamp(1, 5);
  return [
    for (var i = 0; i < rounds; i++) ...[
      b.pyramidClimb('Step pyramid ${i + 1}', 7 + b.rnd.nextInt(3) * 0.5),
      b.sprint('Sprint ${i + 1}', 3),
    ],
  ];
}

List<ProgramPart> _hills(_Builder b, int main) {
  final hills = (main ~/ 7).clamp(2, 6);
  return [
    for (var i = 0; i < hills; i++)
      b.part(i == hills - 1 ? 'Summit hill climb' : 'Hill climb ${i + 1}',
          i == hills - 1 ? 7 : 5, 60 + (b.intensity == Intensity.easy ? 5 : 0), 90, PartRole.hillClimb,
          maxStddev: 6,
          purpose: 'Build strength: resistance up, cadence down, then spin back up.',
          feel: 'Heavy, slow and deliberate, then light and fast.',
          execution:
              'Add resistance in steps while the cadence drops. After the summit, drop the load and spin up.'),
  ];
}

List<ProgramPart> _pyramid(_Builder b, int main) {
  // ladder 2,3,..,peak,..3,2 plus the half & half and recoveries; use the biggest that fits
  var peak = 3;
  for (var p = 3; p <= 7; p++) {
    final steps = [for (var i = 2; i <= p; i++) i, for (var i = p - 1; i >= 2; i--) i];
    final len = steps.fold<double>(0, (a, e) => a + e) +
        recoveryPlan(steps.length + 1).fold<double>(0, (a, m) => a + m);
    if (len <= main) peak = p;
  }
  final steps = [for (var i = 2; i <= peak; i++) i, for (var i = peak - 1; i >= 2; i--) i];
  final climbing = b.rnd.nextBool();
  return [
    for (var i = 0; i < steps.length; i++)
      climbing
          ? b.pyramidClimb('Step pyramid ${i + 1} (${steps[i]} min)', steps[i].toDouble())
          : b.sprint('Pyramid sprint ${i + 1} (${steps[i]} min)', steps[i].toDouble()),
  ];
}

List<ProgramPart> _tabata(_Builder b, int main) {
  final sets = (main ~/ 6).clamp(2, 6);
  return [
    for (var i = 0; i < sets; i++)
      () {
        final v = tabataVariants[b.rnd.nextInt(tabataVariants.length)];
        return b.part('Tabata ${i + 1} (${v.label})', 4, 95, 110, PartRole.tabata,
            variant: v.id,
            purpose: 'Short, hard work/rest intervals.',
            feel: 'All out, then just enough rest.',
            execution: '${v.label}, repeated to the end of the song.');
      }(),
  ];
}

List<ProgramPart> _skills(_Builder b, int main) {
  final order = [
    b.part('Stand-sit-hover', 5, 65, 80, PartRole.standSitHover,
        maxStddev: 6,
        purpose: 'Body position control at moderate resistance.',
        feel: 'Controlled and balanced.',
        execution: 'Rotate stand, sit and hover; keep the resistance steady.'),
    b.part('Pyramid', 6, 85, 100, PartRole.pyramid,
        purpose: 'Build to a peak effort and back down.',
        feel: 'Hard at the top, controlled on the way down.',
        execution: 'Efforts grow to a peak, then shrink, with short recoveries between.'),
    b.part('Surge', 4, 90, 100, PartRole.surge,
        purpose: 'Repeated bursts of speed.',
        feel: 'Steady with sharp lifts.',
        execution: 'Surge, then settle back to your base cadence.'),
  ];
  final blocks = main >= 25 ? order : order.sublist(0, 2);
  return [
    for (var i = 0; i < blocks.length; i++) ...[
      blocks[i],
    ],
  ];
}

List<ProgramPart> _aerobic(_Builder b, int main) {
  final rounds = (main ~/ 8).clamp(2, 5);
  return [
    for (var i = 0; i < rounds; i++) ...[
      b.part('Aerobic flat ${i + 1}', 5, 80, 90, PartRole.steady,
          purpose: 'Build foundational cardio health.',
          feel: 'Conversational; you can speak in full sentences.',
          execution: 'Steady flat road, light-to-moderate resistance, stay seated.'),
      b.part('Easy lift ${i + 1}', 1.5, 90, 100, PartRole.surge,
          purpose: 'A short, manageable change of pace.',
          feel: 'Slightly breathier, still comfortable.',
          execution: 'Lift the cadence for a few short bursts, then settle back.'),
    ],
  ];
}

List<ProgramPart> _fartlek(_Builder b, int main) {
  final parts = <ProgramPart>[];
  // each fast/steady pair is followed by a ~2 min recovery, so leave room for it
  var left = main * 2 / 3;
  var i = 1;
  while (left > 0) {
    final fast = 1.0 + b.rnd.nextInt(4) * 0.5;
    final slow = 1.5 + b.rnd.nextInt(4) * 0.5;
    parts.add(b.sprint('Fartlek fast $i', fast,
        lo: 90 + b.rnd.nextInt(3) * 5,
        hi: 105 + b.rnd.nextInt(3) * 5,
        execution: 'Speed play: go as fast as feels good, no set pace.'));
    parts.add(b.part('Fartlek steady $i', slow, 80, 90, PartRole.steady,
        purpose: 'Active recovery between efforts.',
        feel: 'Comfortable, ready for the next push.',
        execution: 'Steady spin while your breathing settles.'));
    left -= fast + slow;
    i++;
  }
  return parts;
}

List<ProgramPart> _sweetSpot(_Builder b, int main) {
  final blocks = main >= 40 ? 3 : 2;
  return [
    for (var i = 0; i < blocks; i++) ...[
      b.part('Sweet spot ${i + 1}', 10, 85, 92, PartRole.steady,
          purpose: 'Build aerobic base and muscular endurance.',
          feel: 'Comfortably hard; short sentences only.',
          execution: 'Hold a strong, even effort just below threshold.'),
    ],
  ];
}

List<ProgramPart> _strength(_Builder b, int main) {
  final rounds = (main ~/ 7).clamp(2, 5);
  return [
    for (var i = 0; i < rounds; i++) ...[
      i.isEven
          ? b.part('Heavy climb ${i + 1}', 6, 60, 80, PartRole.hillClimb,
              maxStddev: 6,
              purpose: 'Build lower-body strength with heavy resistance.',
              feel: 'Heavy, slow and deliberate.',
              execution: 'Heavy resistance at 60–80 RPM; alternate seated and standing climbs.')
          : b.part('Stand-sit-hover ${i + 1}', 6, 60, 75, PartRole.standSitHover,
              maxStddev: 6,
              purpose: 'Lower-body strength through changing positions.',
              feel: 'Heavy and controlled.',
              execution: 'Rotate stand, sit and hover under heavy resistance.'),
    ],
  ];
}

List<ProgramPart> _speed(_Builder b, int main) {
  final sets = (main ~/ 5).clamp(2, 6);
  return [
    for (var i = 0; i < sets; i++) ...[
      b.sprint('Sprint set ${i + 1}', 3,
          lo: 110,
          hi: 120,
          execution: 'High-cadence sprints at 110–120 RPM, light-to-moderate resistance.'),
    ],
  ];
}

List<ProgramPart> _mixed(_Builder b, int main) {
  final menu = <ProgramPart Function()>[
    () => b.part('Steady flat', 5, 85, 95, PartRole.steady,
        purpose: 'Hold a solid aerobic pace.',
        feel: 'Comfortably hard.',
        execution: 'Steady flat road, stay seated.'),
    () => b.part('Hill climb', 5, 60, 90, PartRole.hillClimb,
        maxStddev: 6,
        purpose: 'Resistance up, cadence down, then spin back up.',
        feel: 'Heavy, then light and fast.',
        execution: 'Add resistance in steps; after the summit drop the load and spin up.'),
    () {
      final v = tabataVariants[b.rnd.nextInt(tabataVariants.length)];
      return b.part('Tabata (${v.label})', 4, 95, 110, PartRole.tabata,
          variant: v.id,
          purpose: 'Short, hard work/rest intervals.',
          feel: 'All out, then just enough rest.',
          execution: '${v.label}, repeated to the end of the song.');
    },
    () => b.part('Stand-sit-hover', 4, 65, 80, PartRole.standSitHover,
        maxStddev: 6,
        purpose: 'Body position control.',
        feel: 'Controlled and balanced.',
        execution: 'Rotate stand, sit and hover.'),
    () => b.part('Surge', 4, 90, 100, PartRole.surge,
        purpose: 'Repeated bursts of speed.',
        feel: 'Steady with sharp lifts.',
        execution: 'Surge, then settle back to base.'),
    () => b.part('Pyramid', 5, 85, 100, PartRole.pyramid,
        purpose: 'Build to a peak effort and back down.',
        feel: 'Hard at the top.',
        execution: 'Efforts grow to a peak, then shrink.'),
  ]..shuffle(b.rnd);
  final blocks = (main ~/ 6).clamp(3, menu.length);
  return [
    for (var i = 0; i < blocks; i++) ...[
      menu[i](),
    ],
  ];
}

List<ProgramPart> _rhythm(_Builder b, int main) {
  final blocks = (main ~/ 5).clamp(3, 8);
  final kinds = [0, 1, 2]..shuffle(b.rnd);
  return [
    for (var i = 0; i < blocks; i++)
      switch (kinds[i % 3]) {
        0 => b.part('Rhythm flat ${i + 1}', 5, 90, 100, PartRole.steady,
            purpose: 'Ride to the beat.',
            feel: 'Smooth and in time with the music.',
            execution: 'Seated flat road, pedal on the beat.'),
        1 => b.sprint('Rhythm jumps ${i + 1}', 4,
            lo: 90,
            hi: 110,
            execution: 'Jumps: stand and sit every 4 or 8 beats.'),
        _ => b.pyramidClimb('Rhythm step pyramid ${i + 1}', 6,
            execution: 'Build the resistance to the peak and back down, pedalling on the beat.'),
      },
  ];
}

List<ProgramPart> _raceDay(_Builder b, int main) => [
      b.part('Tempo effort', 6, 85, 95, PartRole.steady,
          purpose: 'Settle into race pace.',
          feel: 'Hard but sustainable.',
          execution: 'Flat road at a strong tempo, stay seated.'),
      b.pyramidClimb('Threshold step pyramid', 9,
          lo: 65,
          hi: 80,
          execution: 'Long pyramid at threshold; build to the peak, hold it, then come down controlled.'),
      b.sprint('Surges', 4, lo: 95, hi: 105, execution: 'Race surges: attack, then hold the speed.'),
      b.sprint('Final sprint', 3, lo: 100, hi: 110, execution: 'Everything you have left.'),
    ];
