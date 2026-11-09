import 'db.dart';

/// A saved mix as the class detector sees it.
typedef MixSongs = ({int id, String name, List<String> paths});

/// "Looks like you taught this mix": most of its songs were played together.
class ClassSuggestion {
  ClassSuggestion(
      {required this.mixId,
      required this.mixName,
      required this.paths,
      required this.start,
      required this.end,
      required this.matched});
  final int mixId;
  final String mixName;

  /// The mix's songs (in order) when the suggestion was made.
  final List<String> paths;

  /// First and last counted play of the window.
  final DateTime start, end;

  /// Distinct songs of the mix with a counted play in the window.
  final int matched;

  int get total => paths.toSet().length;

  /// What a dismissal is remembered by: the mix and the window's start day.
  String get key => dismissKey(mixId, start);

  static String dismissKey(int mixId, DateTime start) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '$mixId:${start.year}-${two(start.month)}-${two(start.day)}';
  }
}

/// Finds classes that were probably taught: for each mix with at least
/// [minSongs] songs, a [window] of counted plays (any app) covering at least
/// [threshold] of its distinct songs, with no session logged for that mix
/// within [guard] of the window and not in [dismissed]. Newest first.
List<ClassSuggestion> detectTaughtClasses({
  required List<MixSongs> mixes,
  required List<PlayRecord> plays,
  required List<ClassSession> sessions,
  Set<String> dismissed = const {},
  Duration window = const Duration(hours: 2),
  double threshold = 0.8,
  int minSongs = 3,
  Duration guard = const Duration(hours: 12),
}) {
  final counted = [
    for (final p in plays)
      if (MusicDb.isCountedPlay(p.listened, p.completed)) p
  ]..sort((a, b) => a.at.compareTo(b.at));
  final out = <ClassSuggestion>[];
  for (final m in mixes) {
    final songs = m.paths.toSet();
    if (songs.length < minSongs) continue;
    final need = (songs.length * threshold - 1e-9).ceil();
    final ps = [for (final p in counted) if (songs.contains(p.path)) p];
    final logged = [
      for (final s in sessions) if (s.mixId == m.id) s.taughtAt
    ];
    final seen = <String, int>{};
    var j = 0;
    for (var i = 0; i < ps.length;) {
      // Grow the window [i, j) as far as it stays within [window] of ps[i].
      while (j < ps.length && ps[j].at.difference(ps[i].at) <= window) {
        seen.update(ps[j].path, (n) => n + 1, ifAbsent: () => 1);
        j++;
      }
      if (seen.length >= need) {
        final start = ps[i].at, end = ps[j - 1].at;
        final nearLogged = logged.any((t) =>
            !t.isBefore(start.subtract(guard)) && !t.isAfter(end.add(guard)));
        final s = ClassSuggestion(
            mixId: m.id,
            mixName: m.name,
            paths: m.paths,
            start: start,
            end: end,
            matched: seen.length);
        if (!nearLogged && !dismissed.contains(s.key)) out.add(s);
        // Continue after this window so one class gives one suggestion.
        seen.clear();
        i = j;
        continue;
      }
      final n = seen[ps[i].path]! - 1;
      n == 0 ? seen.remove(ps[i].path) : seen[ps[i].path] = n;
      i++;
    }
  }
  out.sort((a, b) => b.start.compareTo(a.start));
  return out;
}

/// Runs [detectTaughtClasses] over the saved mixes and the last [days] of
/// play history.
Future<List<ClassSuggestion>> findClassSuggestions(MusicDb db,
    {DateTime? now, int days = 60}) async {
  final since = (now ?? DateTime.now()).subtract(Duration(days: days));
  final plays = await db.playsSince(since);
  if (plays.isEmpty) return const [];
  final paths = await db.allMixPaths();
  return detectTaughtClasses(
    mixes: [
      for (final m in await db.mixSummaries())
        (id: m.id, name: m.name, paths: paths[m.id] ?? const []),
    ],
    plays: plays,
    sessions: await db.classSessions(),
    dismissed: await db.dismissedClassSuggestions(),
  );
}
