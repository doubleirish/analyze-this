import 'db.dart';

enum MixSort {
  name('Name'),
  date('Saved date'),
  lastOpened('Last opened'),
  lastTaught('Last taught'),
  length('Length');

  const MixSort(this.label);
  final String label;
}

/// Class-length buckets for filtering saved mixes.
enum MixLength {
  any('Any length', 0, double.infinity),
  short('Under 40 min', 0, 40 * 60),
  medium('40–55 min', 40 * 60, 55 * 60),
  long('55–70 min', 55 * 60, 70 * 60),
  extraLong('Over 70 min', 70 * 60, double.infinity);

  const MixLength(this.label, this.min, this.max);
  final String label;
  final double min, max;

  bool fits(double seconds) => seconds >= min && seconds < max;
}

/// What the saved-mixes manager shows: search text (name, program or tag),
/// a tag, a length bucket, pinned only, and archived mixes instead of active.
class MixFilter {
  const MixFilter(
      {this.query = '', this.tag, this.length = MixLength.any, this.pinnedOnly = false, this.archived = false});

  final String query;
  final String? tag;
  final MixLength length;
  final bool pinnedOnly, archived;

  bool matches(MixSummary m) {
    if (m.archived != archived) return false;
    if (pinnedOnly && !m.pinned) return false;
    if (tag != null && !m.tags.contains(tag)) return false;
    if (!length.fits(m.totalSeconds)) return false;
    final words = query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
    final hay = [m.name, m.programName ?? '', ...m.tags].join(' ').toLowerCase();
    return words.every(hay.contains);
  }
}

/// Filters and sorts [mixes]; pinned mixes always come first. [taught] is
/// the last-taught time per mix id (for [MixSort.lastTaught]).
List<MixSummary> arrangeMixes(List<MixSummary> mixes, MixFilter filter, MixSort sort,
    {Map<int, DateTime> taught = const {}}) {
  final list = [for (final m in mixes) if (filter.matches(m)) m];
  int byName(MixSummary a, MixSummary b) => a.name.toLowerCase().compareTo(b.name.toLowerCase());
  int newestFirst(int? a, int? b) => (b ?? -1).compareTo(a ?? -1);
  int key(MixSummary a, MixSummary b) => switch (sort) {
        MixSort.name => 0,
        MixSort.date => newestFirst(a.savedAt, b.savedAt),
        MixSort.lastOpened => newestFirst(a.lastOpened, b.lastOpened),
        MixSort.lastTaught =>
          newestFirst(taught[a.id]?.millisecondsSinceEpoch, taught[b.id]?.millisecondsSinceEpoch),
        MixSort.length => b.totalSeconds.compareTo(a.totalSeconds),
      };
  list.sort((a, b) {
    if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
    final c = key(a, b);
    return c != 0 ? c : byName(a, b);
  });
  return list;
}
