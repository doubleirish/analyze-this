import 'planner.dart';
import 'song_models.dart';

/// Usual cadence (RPM low, high) of each exercise role.
const _roleRpm = <PartRole, (double, double)>{
  PartRole.warmup: (80, 90),
  PartRole.climb: (60, 70),
  PartRole.sprint: (90, 105),
  PartRole.recovery: (70, 85),
  PartRole.cooldown: (60, 70),
  PartRole.stretch: (55, 70),
  PartRole.steady: (80, 90),
  PartRole.halfAndHalf: (70, 85),
  PartRole.stepPyramid: (65, 85),
  PartRole.tabata: (90, 110),
  PartRole.hillClimb: (60, 90),
  PartRole.standSitHover: (60, 75),
  PartRole.pyramid: (85, 105),
  PartRole.surge: (90, 110),
};

/// A part for exercise [role] riding [song]: the role's usual cadence and a
/// length that follows the song (4 min with no song).
ProgramPart exerciseFor(PartRole role, Song? song, {String? name}) {
  final (lo, hi) = _roleRpm[role]!;
  return ProgramPart(name ?? role.label, (song?.playSeconds ?? 240) / 60, lo, hi,
      role: role, variant: role == PartRole.tabata ? '20-10' : null);
}

/// What a track gets before an exercise is chosen: steady riding at the
/// cadence its tempo suggests (half or double time folded into 60–110).
ProgramPart defaultTrackPart(Song song) {
  final bpm = song.medianBpm;
  if (bpm == null || bpm <= 0) return exerciseFor(PartRole.steady, song);
  final rpm = foldToBand(bpm, 60, 110).clamp(50.0, 120.0).toDouble();
  return ProgramPart('Steady', (song.playSeconds ?? 240) / 60, rpm - 5, rpm + 5,
      role: PartRole.steady);
}
