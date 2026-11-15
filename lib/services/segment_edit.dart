import 'package:shared_core/shared_core.dart';

/// One hand-set sub-exercise of a song (e.g. a pyramid level), replacing the
/// automatic pattern so its length can match a part of the song.
class SegmentEdit {
  const SegmentEdit({
    required this.label,
    required this.seconds,
    required this.minRpm,
    required this.maxRpm,
    this.icon = '',
    this.gear,
    this.note = '',
    this.lead = false,
  });

  final String label;
  final double seconds;
  final double minRpm, maxRpm;
  final String icon;
  final int? gear;

  /// Trainer's reminder for this sub-exercise.
  final String note;
  final bool lead;

  SegmentEdit copyWith({String? label, double? seconds, String? note}) => SegmentEdit(
      label: label ?? this.label,
      seconds: seconds ?? this.seconds,
      minRpm: minRpm,
      maxRpm: maxRpm,
      icon: icon,
      gear: gear,
      note: note ?? this.note,
      lead: lead);

  Map<String, Object?> toJson() => {
        'label': label,
        'seconds': seconds,
        'minRpm': minRpm,
        'maxRpm': maxRpm,
        if (icon.isNotEmpty) 'icon': icon,
        if (gear != null) 'gear': gear,
        if (note.isNotEmpty) 'note': note,
        if (lead) 'lead': true,
      };

  factory SegmentEdit.fromJson(Map<String, dynamic> j) => SegmentEdit(
        label: j['label'] as String? ?? '',
        seconds: (j['seconds'] as num?)?.toDouble() ?? 0,
        minRpm: (j['minRpm'] as num?)?.toDouble() ?? 80,
        maxRpm: (j['maxRpm'] as num?)?.toDouble() ?? 90,
        icon: j['icon'] as String? ?? '',
        gear: (j['gear'] as num?)?.toInt(),
        note: j['note'] as String? ?? '',
        lead: j['lead'] == true,
      );

  /// Starting point for editing: the automatic segments of [plan].
  static List<SegmentEdit> fromPlan(StepPlan plan) => [
        for (final s in plan.segments)
          SegmentEdit(
              label: s.label,
              seconds: s.length,
              minRpm: s.minRpm,
              maxRpm: s.maxRpm,
              icon: s.icon,
              gear: s.gear,
              note: s.note ?? '',
              lead: s.lead)
      ];

  @override
  bool operator ==(Object other) =>
      other is SegmentEdit && _same(this, other);

  @override
  int get hashCode => Object.hash(label, seconds, note);

  static bool _same(SegmentEdit a, SegmentEdit b) =>
      a.label == b.label &&
      a.seconds == b.seconds &&
      a.minRpm == b.minRpm &&
      a.maxRpm == b.maxRpm &&
      a.icon == b.icon &&
      a.gear == b.gear &&
      a.note == b.note &&
      a.lead == b.lead;
}

/// [edits] laid end to end on a song of [songSeconds]: lengths beyond the end
/// are cut and a shortfall is given to the last segment. With an unknown
/// length ([songSeconds] <= 0) the lengths are used as set.
List<StepSegment> applySegmentEdits(List<SegmentEdit> edits, double songSeconds) {
  final out = <StepSegment>[];
  var t = 0.0;
  for (var i = 0; i < edits.length; i++) {
    final e = edits[i];
    if (songSeconds > 0 && t >= songSeconds - 0.01) break;
    var end = t + e.seconds;
    if (songSeconds > 0) {
      end = i == edits.length - 1 ? songSeconds : end.clamp(t, songSeconds).toDouble();
    }
    if (end - t < 0.01) continue;
    out.add(StepSegment(
        label: e.label,
        icon: e.icon,
        start: t,
        end: end,
        minRpm: e.minRpm,
        maxRpm: e.maxRpm,
        lead: e.lead,
        gear: e.gear,
        note: e.note.isEmpty ? null : e.note));
    t = end;
  }
  return out;
}

/// Seconds not yet given to a segment (negative = over the song's length).
double unallocatedSeconds(List<SegmentEdit> edits, double songSeconds) =>
    songSeconds - edits.fold<double>(0, (a, e) => a + e.seconds);

/// [edits] with their lengths taken from tapped [marks]: seconds into the song
/// at which each segment ends. The last segment runs to [songSeconds]; extra
/// marks are ignored and missing marks leave those segments unchanged.
List<SegmentEdit> editsFromMarks(List<SegmentEdit> edits, List<double> marks, double songSeconds) {
  final out = <SegmentEdit>[];
  var t = 0.0;
  for (var i = 0; i < edits.length; i++) {
    final last = i == edits.length - 1;
    if (last && marks.length >= i) {
      out.add(edits[i].copyWith(seconds: (songSeconds - t).clamp(0.0, songSeconds).toDouble()));
    } else if (i < marks.length) {
      final end = marks[i].clamp(t, songSeconds).toDouble();
      out.add(edits[i].copyWith(seconds: end - t));
      t = end;
    } else {
      out.add(edits[i]);
      t += edits[i].seconds;
    }
  }
  return out;
}
