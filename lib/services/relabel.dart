import 'dart:math' as math;

import 'db.dart';
import 'discography.dart' show albumKey;
import 'musicbrainz.dart';

/// Below this an album match isn't offered at all.
const relabelMinConfidence = 0.6;

/// At or above this a match is badged as high confidence.
const relabelHighConfidence = 0.8;

/// One proposed tag edit; [field] is 'title', 'artist' or 'album'.
class TrackChange {
  const TrackChange(this.path, this.field, this.from, this.to);
  final String path;
  final String field;
  final String? from;
  final String to;
}

class RelabelSuggestion {
  const RelabelSuggestion({
    required this.key,
    required this.songs,
    required this.release,
    required this.confidence,
    required this.matched,
    required this.changes,
  });

  /// The album group's key (see `groupAlbums`).
  final String key;
  final List<Song> songs;
  final MbRelease release;

  /// 0-1: how well the library's tracks line up with the release.
  final double confidence;

  /// Songs paired with a release track.
  final int matched;
  final List<TrackChange> changes;

  bool get high => confidence >= relabelHighConfidence;
}

String _norm(String s) => albumKey(s);

/// 0-1 similarity of two titles: 1 when they normalise equal, otherwise the
/// Dice coefficient of their character bigrams.
double titleSimilarity(String a, String b) {
  final x = _norm(a), y = _norm(b);
  if (x.isEmpty || y.isEmpty) return 0;
  if (x == y) return 1;
  if (x.length < 2 || y.length < 2) return 0;
  Map<String, int> grams(String s) {
    final m = <String, int>{};
    for (var i = 0; i < s.length - 1; i++) {
      m.update(s.substring(i, i + 2), (v) => v + 1, ifAbsent: () => 1);
    }
    return m;
  }

  final ga = grams(x), gb = grams(y);
  var common = 0;
  for (final e in ga.entries) {
    common += math.min(e.value, gb[e.key] ?? 0);
  }
  return 2 * common / ((x.length - 1) + (y.length - 1));
}

/// How well one song fits one release track: title 50%, length 30%, track number 20%.
/// Length and number carry weight so a track with a wrong title can still pair up.
double _pairScore(Song s, MbTrack t) {
  final title = titleSimilarity(s.title ?? '', t.title);
  var dur = 0.5;
  if (s.duration != null && t.lengthMs != null) {
    final d = (s.duration! - t.lengthMs! / 1000).abs();
    dur = d <= 3 ? 1 : (d >= 15 ? 0 : 1 - (d - 3) / 12);
  }
  var pos = 0.5;
  if (s.trackNo != null) {
    pos = s.trackNo == t.position && (s.discNo == null || s.discNo == t.disc) ? 1 : 0;
  }
  return 0.5 * title + 0.3 * dur + 0.2 * pos;
}

bool _sameName(String? a, String b) {
  final x = _norm(a ?? ''), y = _norm(b);
  return x.isEmpty ? y.isEmpty : (x == y || (y.isNotEmpty && (x.contains(y) || y.contains(x))));
}

/// Pairs the album's songs with [release]'s tracks and lists the edits that
/// would make the tags match (none when the album is already right). Returns
/// null when the fit is below [relabelMinConfidence].
///
/// [searchScore] (0-100) is MusicBrainz's own text-match score for the release.
RelabelSuggestion? planRelabel(String key, List<Song> songs, MbRelease release, {int searchScore = 100}) {
  final tracks = release.tracks;
  if (songs.isEmpty || tracks.isEmpty) return null;

  final pairs = <(double, int, int)>[
    for (var i = 0; i < songs.length; i++)
      for (var j = 0; j < tracks.length; j++) (_pairScore(songs[i], tracks[j]), i, j),
  ]..sort((a, b) => b.$1.compareTo(a.$1));

  final songTrack = <int, int>{};
  final usedTracks = <int>{};
  var total = 0.0;
  for (final p in pairs) {
    if (p.$1 < 0.5) break;
    if (songTrack.containsKey(p.$2) || usedTracks.contains(p.$3)) continue;
    songTrack[p.$2] = p.$3;
    usedTracks.add(p.$3);
    total += p.$1;
  }
  if (songTrack.isEmpty) return null;

  final slots = math.max(songs.length, tracks.length);
  final confidence = (total / slots) * (0.7 + 0.3 * searchScore.clamp(0, 100) / 100);
  if (confidence < relabelMinConfidence) return null;

  final changes = <TrackChange>[];
  for (final e in songTrack.entries) {
    final s = songs[e.key];
    final t = tracks[e.value];
    if (_norm(s.title ?? '') != _norm(t.title)) changes.add(TrackChange(s.path, 'title', s.title, t.title));
    if (_norm(s.album ?? '') != _norm(release.title)) {
      changes.add(TrackChange(s.path, 'album', s.album, release.title));
    }
    if (t.artist.isNotEmpty && !_sameName(s.artist, t.artist)) {
      changes.add(TrackChange(s.path, 'artist', s.artist, t.artist));
    }
  }
  return RelabelSuggestion(
    key: key,
    songs: songs,
    release: release,
    confidence: confidence,
    matched: songTrack.length,
    changes: changes,
  );
}
