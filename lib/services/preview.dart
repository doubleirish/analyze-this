import 'db.dart';

/// Rules for auditioning a song: 30 seconds from its most energetic section.
class PreviewService {
  static const length = Duration(seconds: 30);

  /// Start of the fastest tempo segment, else 30% into the song.
  static Duration startFor(Song s, List<TempoSeg> segs) {
    if (segs.isNotEmpty) {
      final best = segs.reduce((a, b) => b.bpm > a.bpm ? b : a);
      return Duration(milliseconds: (best.start * 1000).round());
    }
    return Duration(milliseconds: ((s.duration ?? 0) * 300).round());
  }
}
