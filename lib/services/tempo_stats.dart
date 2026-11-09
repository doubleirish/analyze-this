import 'dart:math' as math;

import 'package:shared_core/shared_core.dart';

import 'db.dart';

/// The per-song BPM summary stored in the songs table, derived from a tempo map.
class TempoStats {
  const TempoStats({this.avg, this.median, this.min, this.max, this.stddev, this.segments = const []});

  factory TempoStats.of(TempoMap? m) {
    if (m == null || m.segments.isEmpty) return const TempoStats();
    final bpms = m.segments.map((s) => s.bpm);
    return TempoStats(
      avg: m.averageBpm,
      median: m.medianBpm,
      min: bpms.reduce(math.min),
      max: bpms.reduce(math.max),
      stddev: stddevOf(m),
      segments: [for (final s in m.segments) TempoSeg(s.startSec, s.endSec, s.bpm)],
    );
  }

  final double? avg;
  final double? median;
  final double? min;
  final double? max;
  final double? stddev;
  final List<TempoSeg> segments;

  Map<String, Object?> toRow() => {
        'avg_bpm': avg,
        'median_bpm': median,
        'min_bpm': min,
        'max_bpm': max,
        'bpm_stddev': stddev,
      };

  /// Duration-weighted standard deviation of the segment tempos.
  static double? stddevOf(TempoMap? m) {
    if (m == null || m.segments.isEmpty) return null;
    final mean = m.averageBpm!;
    var sum = 0.0, total = 0.0;
    for (final s in m.segments) {
      final len = s.endSec - s.startSec;
      sum += len * (s.bpm - mean) * (s.bpm - mean);
      total += len;
    }
    return total == 0 ? 0 : math.sqrt(sum / total);
  }
}
