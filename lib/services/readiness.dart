import 'db.dart';
import 'planner.dart';

/// How well the library can fill a program part.
///
/// * [empty]: no song matches the part at all.
/// * [thin]: fewer than [thinFactor] × needed songs that weren't taught
///   recently (so the part can be filled, but it will repeat songs soon).
/// * [ok]: at least [thinFactor] × needed fresh songs.
enum ReadinessStatus { ok, thin, empty }

/// A part is thin when it has fewer than this many times the songs it needs.
const thinFactor = 3;

/// Song length assumed when no matching song has a known length.
const fallbackSongSeconds = 240.0;

ReadinessStatus readinessStatus({required int candidates, required int fresh, required int needed}) =>
    candidates == 0
        ? ReadinessStatus.empty
        : fresh < thinFactor * needed
            ? ReadinessStatus.thin
            : ReadinessStatus.ok;

/// Songs needed to cover [minutes] with songs of [avgSeconds] each.
int songsNeeded(double minutes, double avgSeconds) =>
    minutes <= 0 ? 0 : (minutes * 60 / (avgSeconds > 0 ? avgSeconds : fallbackSongSeconds)).ceil();

class PartReadiness {
  const PartReadiness({
    required this.index,
    required this.part,
    required this.query,
    required this.candidates,
    required this.needed,
    required this.fresh,
    required this.avgSeconds,
  });

  /// Index of [part] in the program.
  final int index;
  final ProgramPart part;

  /// The search the Mix page uses for this part (with the Mix filters).
  final SongQuery query;

  /// Songs matching [query].
  final int candidates;

  /// Songs it takes to fill the part's minutes.
  final int needed;

  /// [candidates] not taught in the last few weeks.
  final int fresh;
  final double avgSeconds;

  ReadinessStatus get status =>
      readinessStatus(candidates: candidates, fresh: fresh, needed: needed);
}

/// Readiness of every music part of [program] (parts with `music: false` are
/// skipped). [base] gives the Mix filters for a role (e.g.
/// `MixController.mixBase`); songs taught within [recentWeeks] weeks don't
/// count as fresh. Songs needed per part use [avgSongSeconds] when given,
/// else the average length of the part's candidates, else
/// [fallbackSongSeconds].
Future<List<PartReadiness>> programReadiness(MusicDb db, Program program,
    {SongQuery Function(PartRole role)? base,
    int recentWeeks = defaultRecentWeeks,
    double? avgSongSeconds}) async {
  final out = <PartReadiness>[];
  for (var i = 0; i < program.parts.length; i++) {
    final p = program.parts[i];
    if (!p.music) continue;
    final q = partQuery(p, base?.call(p.kind) ?? const SongQuery());
    final candidates = await db.count(q);
    final fresh = candidates == 0
        ? 0
        : await db.count(q.copyWith(hideTaughtWithinDays: recentWeeks * 7));
    final avg = avgSongSeconds ??
        (candidates == 0 ? null : await db.averageDuration(q)) ??
        fallbackSongSeconds;
    out.add(PartReadiness(
        index: i,
        part: p,
        query: q,
        candidates: candidates,
        needed: songsNeeded(p.minutes, avg),
        fresh: fresh,
        avgSeconds: avg));
  }
  return out;
}

class BandCount {
  const BandCount(this.lo, this.hi, this.songs);
  final double lo;
  final double hi;
  final int songs;
}

/// Songs per RPM band over the RPM span a role covers in a program.
class RoleCoverage {
  const RoleCoverage(this.role, this.minRpm, this.maxRpm, this.bands);
  final PartRole role;
  final double minRpm;
  final double maxRpm;
  final List<BandCount> bands;
}

/// For each role among [program]'s music parts (in order of first use): the
/// role's RPM span (lowest to highest RPM of its parts) cut into [bandWidth]
/// bands, with how many of [bpms] fall in each band once folded by half or
/// double time ([foldToBand]). Songs outside the span after folding are not
/// counted.
List<RoleCoverage> coverageFromBpms(List<double> bpms, Program program, {double bandWidth = 5}) {
  final spans = <PartRole, (double, double)>{};
  for (final p in program.parts) {
    if (!p.music) continue;
    final s = spans[p.kind];
    spans[p.kind] = s == null
        ? (p.minRpm, p.maxRpm)
        : (s.$1 < p.minRpm ? s.$1 : p.minRpm, s.$2 > p.maxRpm ? s.$2 : p.maxRpm);
  }
  return [
    for (final e in spans.entries) _coverage(e.key, e.value.$1, e.value.$2, bpms, bandWidth),
  ];
}

RoleCoverage _coverage(PartRole role, double lo, double hi, List<double> bpms, double width) {
  final start = (lo / width).floor() * width;
  final n = hi <= start ? 1 : ((hi - start) / width).ceil();
  final counts = List.filled(n, 0);
  for (final b in bpms) {
    if (b <= 0 || !bpmInBand(b, lo, hi)) continue;
    final i = ((foldToBand(b, lo, hi) - start) / width).floor();
    counts[i.clamp(0, n - 1)]++;
  }
  return RoleCoverage(role, lo, hi, [
    for (var i = 0; i < n; i++)
      BandCount(i == 0 ? lo : start + i * width, i == n - 1 ? hi : start + (i + 1) * width,
          counts[i]),
  ]);
}

/// [coverageFromBpms] over the whole library (one query of median BPMs).
Future<List<RoleCoverage>> rpmCoverage(MusicDb db, Program program, {double bandWidth = 5}) async =>
    coverageFromBpms(await db.medianBpms(), program, bandWidth: bandWidth);
