import 'dart:math';

import 'db.dart';
import 'planner.dart';

/// Pure helpers behind program auto-fill: which candidate to pick, and how to
/// order a part's songs so the tempo chain stays smooth. Randomness only
/// comes from the [Random] passed in, so results are reproducible in tests.

/// A part counts as filled once less than this many seconds are left.
const fillSlackSeconds = 45.0;

/// Seconds assumed for a song without a known length.
const defaultSongSeconds = 240.0;

double songSeconds(Song s) => s.playSeconds ?? defaultSongSeconds;

String _artistKey(Song s) => (s.artist ?? '').trim().toLowerCase();

/// Whether [a] and [b] are by the same (known) artist.
bool sameArtist(Song? a, Song? b) {
  if (a == null || b == null) return false;
  final k = _artistKey(a);
  return k.isNotEmpty && k == _artistKey(b);
}

/// The candidates auto-fill should choose from: all of [cands] minus the
/// ones it would rather avoid, in tiers: first drop the same artist as
/// [previous], then songs in [recentlyTaught] (paths taught in a recent
/// class). A tier that would leave nothing is skipped, so a song is only
/// ever ruled out when something else fits. This is the one place fill-time
/// preferences live; add further soft filters here.
List<Song> preferCandidates(List<Song> cands,
    {Song? previous, Set<String> recentlyTaught = const {}}) {
  final other = [for (final s in cands) if (!sameArtist(s, previous)) s];
  final pool = other.isEmpty ? cands : other;
  if (recentlyTaught.isEmpty) return pool;
  final fresh = [for (final s in pool) if (!recentlyTaught.contains(s.path)) s];
  return fresh.isEmpty ? pool : fresh;
}

/// [cands] with the songs in [recentlyTaught] moved to the end (stable).
List<Song> rankNotRecent(List<Song> cands, Set<String> recentlyTaught) => recentlyTaught.isEmpty
    ? cands
    : [
        for (final s in cands) if (!recentlyTaught.contains(s.path)) s,
        for (final s in cands) if (recentlyTaught.contains(s.path)) s,
      ];

/// Picks the next song for a part with [need] seconds left. Songs that would
/// finish the part (leave under [fillSlackSeconds]) are "last song" options;
/// when there are any, the one whose length is closest to [need] wins.
/// Otherwise a rating-weighted random pick keeps fills varied.
Song? pickFill(List<Song> cands, Random random,
    {Song? previous, required double need, Set<String> recentlyTaught = const {}}) {
  final pool = preferCandidates(cands, previous: previous, recentlyTaught: recentlyTaught);
  if (pool.isEmpty) return null;
  final finishers = [
    for (final s in pool)
      if (need - songSeconds(s) <= fillSlackSeconds) s
  ];
  if (finishers.isEmpty) return pickWeighted(pool, random);
  Song? best;
  for (final s in finishers) {
    if (best == null || (songSeconds(s) - need).abs() < (songSeconds(best) - need).abs()) {
      best = s;
    }
  }
  return best;
}

/// Cost of playing [b] right after [a]: the half/double-aware tempo jump,
/// plus a [bigJumpBpm] penalty for the same artist twice in a row (so an
/// artist repeat is only accepted when every alternative is a big jump).
double chainCost(Song? a, Song b) {
  final x = a?.medianBpm, y = b.medianBpm;
  final jump = x == null || y == null ? 0.0 : bpmJump(x, y);
  return jump + (sameArtist(a, b) ? bigJumpBpm : 0);
}

/// [songs] reordered greedily: starting after [previous] (the song before
/// them in the mix, if any), always play next the remaining song with the
/// lowest [chainCost]. Ties keep the input order.
List<Song> orderChain(List<Song> songs, {Song? previous}) {
  final left = [...songs];
  final out = <Song>[];
  var cur = previous;
  while (left.isNotEmpty) {
    var bi = 0;
    var bc = double.infinity;
    for (var i = 0; i < left.length; i++) {
      final c = chainCost(cur, left[i]);
      if (c < bc) {
        bc = c;
        bi = i;
      }
    }
    cur = left.removeAt(bi);
    out.add(cur);
  }
  return out;
}

/// Snackbar text after an auto-fill, e.g. "Filled 12 songs · 1 relaxed · 2 big jumps".
String fillReport(int songs, int relaxed, int bigJumps, {int uneven = 0}) => [
      'Filled $songs song${songs == 1 ? '' : 's'}',
      if (relaxed > 0) '$relaxed relaxed',
      if (uneven > 0) '$uneven uneven part${uneven == 1 ? '' : 's'}',
      if (bigJumps > 0) '$bigJumps big jump${bigJumps == 1 ? '' : 's'}',
    ].join(' · ');

// ------------------------------------------------- balanced part planning --

/// How far an activity may run over or under its planned length: the songs'
/// ends define where it really ends, and the next part absorbs the drift.
const partToleranceSeconds = 60.0;

/// Balance rules for the songs of one activity, strictest first. A stage
/// is only used when no choice of songs passes the stricter ones.
/// [lengthRatio] = longest / shortest song; [bpmSpread] = widest
/// (half/double aware) tempo gap between any two of them.
class BalanceStage {
  const BalanceStage(this.lengthRatio, this.bpmSpread, this.tolerance);
  final double lengthRatio, bpmSpread, tolerance;
}

const balanceStages = [
  BalanceStage(1.25, 6, partToleranceSeconds),
  BalanceStage(1.5, 10, partToleranceSeconds),
  BalanceStage(2.0, 20, partToleranceSeconds * 1.5),
];

/// Songs chosen for one activity, and the [stage] of [balanceStages] they
/// meet ([balanceStages.length] = no balanced choice; picked one at a time).
class PartPick {
  const PartPick(this.songs, this.stage);
  final List<Song> songs;
  final int stage;
  bool get uneven => stage >= 2;
}

/// Candidates considered per song count, nearest in length to the target first.
const _poolSize = 40;
const _beamWidth = 80;

/// Chooses the songs for one activity lasting about [need] seconds.
///
/// Rather than adding songs until the time is nearly used and then tacking a
/// short one on, it decides how many songs to use (1, 2, 3, …) and looks for
/// a set whose total is within the stage's tolerance of [need], whose
/// lengths are similar and whose tempos match, so two 4-minute songs beat a
/// 7-minute song plus a 1-minute filler. Among sets that pass, it prefers
/// totals close to [need], even lengths and tempos, higher ratings, artist
/// variety and songs not [recentlyTaught]; [random] adds a little variety.
///
/// [anchors] are songs already in the activity (locked); [need] is the time
/// left after them, and new songs are balanced against them too. With
/// [single], exactly one song is picked (half & half). [minSeconds] /
/// [maxSeconds] are the role's usual song lengths: song counts whose
/// per-song length falls outside them are tried last.
///
/// Returns null when [need] is too short to be worth a song (and nothing is
/// required) or there are no candidates.
PartPick? planPartSongs(List<Song> cands, double need, Random random,
    {Song? previous,
    Set<String> recentlyTaught = const {},
    List<Song> anchors = const [],
    bool single = false,
    bool required = false,
    double? minSeconds,
    double? maxSeconds}) {
  final pool = {for (final s in cands) s.path: s}.values.toList();
  if (pool.isEmpty) return null;
  if (need <= partToleranceSeconds && !required) return null;
  if (single) {
    final best = _bestSingle(pool, need, random, previous, recentlyTaught, anchors);
    return best;
  }
  final avg = pool.fold<double>(0, (a, s) => a + songSeconds(s)) / pool.length;
  final maxK = max(1, min(8, (need / max(60.0, avg * 0.5)).ceil()));
  for (var stage = 0; stage < balanceStages.length; stage++) {
    final rule = balanceStages[stage];
    _Combo? best;
    for (var k = 1; k <= maxK; k++) {
      final per = need / k;
      if (per < 45) break;
      final c = _searchK(pool, k, need, rule, random, previous, recentlyTaught, anchors,
          outsideUsual: (minSeconds != null && per < minSeconds - 30) ||
              (maxSeconds != null && per > maxSeconds + 30));
      if (c != null && (best == null || c.score < best.score)) best = c;
    }
    if (best != null) return PartPick(best.songs, stage);
  }
  return PartPick(_greedy(pool, need, random, previous, recentlyTaught), balanceStages.length);
}

class _Combo {
  _Combo(this.songs, this.score);
  final List<Song> songs;
  final double score;
}

double _spread(Iterable<double> bpms) {
  final l = bpms.toList();
  var w = 0.0;
  for (var i = 0; i < l.length; i++) {
    for (var j = i + 1; j < l.length; j++) {
      w = max(w, bpmJump(l[i], l[j]));
    }
  }
  return w;
}

/// Best set of exactly [k] songs under [rule] (beam search over the songs
/// nearest in length to need/k), or null.
_Combo? _searchK(List<Song> pool, int k, double need, BalanceStage rule, Random random,
    Song? previous, Set<String> recent, List<Song> anchors,
    {bool outsideUsual = false}) {
  final per = need / k;
  // Recently used songs rank as if 30 s further off, so fresh songs of a
  // similar length make the shortlist first.
  double off(Song s) => (songSeconds(s) - per).abs() + (recent.contains(s.path) ? 30 : 0);
  final near = [...pool]..sort((a, b) => off(a).compareTo(off(b)));
  final c = near.take(_poolSize).toList();
  final anchorLens = [for (final a in anchors) songSeconds(a)];
  final anchorBpms = _bpms(anchors);

  bool ok(List<int> idx) {
    final lens = [...anchorLens, for (final i in idx) songSeconds(c[i])];
    if (lens.reduce(max) / lens.reduce(min) > rule.lengthRatio) return false;
    final bpms = [...anchorBpms, ..._bpms([for (final i in idx) c[i]])];
    return _spread(bpms) <= rule.bpmSpread;
  }

  double sum(List<int> idx) => idx.fold(0.0, (a, i) => a + songSeconds(c[i]));

  var beam = <List<int>>[[]];
  for (var depth = 0; depth < k; depth++) {
    final next = <(List<int>, double)>[];
    for (final st in beam) {
      final from = st.isEmpty ? 0 : st.last + 1;
      for (var i = from; i < c.length; i++) {
        final idx = [...st, i];
        if (sum(idx) > need + rule.tolerance) continue;
        if (!ok(idx)) continue;
        // On track for the total: each song should be about need/k long.
        next.add((idx, (sum(idx) - per * idx.length).abs()));
      }
    }
    if (next.isEmpty) return null;
    next.sort((a, b) => a.$2.compareTo(b.$2));
    beam = [for (final n in next.take(_beamWidth)) n.$1];
  }
  _Combo? best;
  for (final idx in beam) {
    final total = sum(idx);
    final dev = (total - need).abs();
    if (dev > rule.tolerance) continue;
    final songs = [for (final i in idx) c[i]];
    final score = _score(songs, anchors, dev, rule, random, previous, recent) + (outsideUsual ? 2 : 0);
    if (best == null || score < best.score) best = _Combo(songs, score);
  }
  return best;
}

/// Lower is better. Weighted so the total length and balance matter most,
/// then freshness and variety, then rating; a little noise for variety.
double _score(List<Song> songs, List<Song> anchors, double dev, BalanceStage rule, Random random,
    Song? previous, Set<String> recent) {
  final all = [...anchors, ...songs];
  final lens = [for (final s in all) songSeconds(s)];
  final ratio = lens.reduce(max) / lens.reduce(min);
  final spread = _spread(_bpms(all));
  var dupes = 0;
  for (var i = 0; i < all.length; i++) {
    for (var j = i + 1; j < all.length; j++) {
      if (sameArtist(all[i], all[j])) dupes++;
    }
  }
  if (songs.any((s) => sameArtist(s, previous))) dupes++;
  final stale = songs.where((s) => recent.contains(s.path)).length;
  final rating = songs.fold<double>(0, (a, s) => a + s.rating) / songs.length;
  return dev / partToleranceSeconds +
      (ratio - 1) * 4 +
      spread / max(rule.bpmSpread, 1) +
      dupes * 1.5 +
      stale * 2 -
      rating * 0.2 +
      random.nextDouble() * 0.4;
}

List<double> _bpms(Iterable<Song> songs) => [
      for (final s in songs)
        if (s.medianBpm != null) s.medianBpm!
    ];

PartPick _bestSingle(List<Song> pool, double need, Random random, Song? previous,
    Set<String> recent, List<Song> anchors) {
  for (var stage = 0; stage < balanceStages.length; stage++) {
    final rule = balanceStages[stage];
    _Combo? best;
    for (final s in pool) {
      final dev = (songSeconds(s) - need).abs();
      if (anchors.isEmpty && dev > rule.tolerance) continue;
      final score = _score([s], anchors, dev, rule, random, previous, recent);
      if (best == null || score < best.score) best = _Combo([s], score);
    }
    if (best != null) return PartPick(best.songs, stage);
  }
  Song? best;
  for (final s in preferCandidates(pool, previous: previous, recentlyTaught: recent)) {
    if (best == null || (songSeconds(s) - need).abs() < (songSeconds(best) - need).abs()) best = s;
  }
  return PartPick([best ?? pool.first], balanceStages.length);
}

/// The old one-at-a-time fill, used when no balanced set exists: random
/// (rating-weighted) songs until the last one can close the gap.
List<Song> _greedy(List<Song> pool, double need, Random random, Song? previous, Set<String> recent) {
  final left = [...pool];
  final out = <Song>[];
  var t = need;
  var prev = previous;
  while (t > fillSlackSeconds && left.isNotEmpty) {
    final s = pickFill(left, random, previous: prev, need: t, recentlyTaught: recent);
    if (s == null) break;
    left.remove(s);
    out.add(s);
    prev = s;
    t -= songSeconds(s);
  }
  return out;
}
