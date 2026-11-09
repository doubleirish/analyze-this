import 'package:shared_core/shared_core.dart';

import 'db.dart';

/// What a logged play or rating says about its song, used to find the
/// library file it refers to.
class TrackRef {
  const TrackRef({this.path, this.origPath, this.sha256, this.title, this.artist, this.duration});

  factory TrackRef.fromEntry(JournalEntry e) => TrackRef(
      path: e.path,
      origPath: e.origPath,
      sha256: e.sha256,
      title: e.title,
      artist: e.artist,
      duration: e.duration);

  /// From a shared plays-log row (`path`, `origPath`, `sha256`, `title`,
  /// `artist`, `duration`).
  factory TrackRef.fromMap(Map<String, Object?> m) {
    String? s(String k) => m[k] is String && (m[k] as String).isNotEmpty ? m[k] as String : null;
    return TrackRef(
        path: s('path'),
        origPath: s('origPath'),
        sha256: s('sha256'),
        title: s('title'),
        artist: s('artist'),
        duration: (m['duration'] as num?)?.toDouble());
  }

  final String? path, origPath, sha256, title, artist;
  final double? duration;

  String get dupKey => dupKeyFor(artist, title);
}

/// Maps phone/other-app tracks to library paths. Tried in order: the logged
/// path or `origPath` when it is a library song; the sent copy's sha256 (see
/// [MusicDb.recordSentTracks]); title + artist with duration within
/// [durationSlack] seconds, only when exactly one song matches.
///
/// Lookups are cached; call [prime] with many refs first to batch queries.
class PathResolver {
  PathResolver(this.db);
  final MusicDb db;

  static const durationSlack = 2.0;

  final _songs = <String, bool>{};
  final _sha = <String, String?>{};
  final _keys = <String, List<({String path, double? duration})>>{};

  Future<void> prime(Iterable<TrackRef> refs) async {
    final paths = <String>{}, shas = <String>{}, keys = <String>{};
    for (final r in refs) {
      for (final p in [r.path, r.origPath]) {
        if (p != null && !_songs.containsKey(p)) paths.add(p);
      }
      if (r.sha256 case final h? when !_sha.containsKey(h)) shas.add(h);
      final k = r.dupKey;
      if (k.isNotEmpty && !_keys.containsKey(k)) keys.add(k);
    }
    if (paths.isNotEmpty) {
      final found = await db.existingSongPaths(paths);
      for (final p in paths) {
        _songs[p] = found.contains(p);
      }
    }
    if (shas.isNotEmpty) {
      final found = await db.sentTrackPaths(shas);
      for (final h in shas) {
        _sha[h] = found[h];
      }
    }
    if (keys.isNotEmpty) {
      final found = await db.songsByDupKey(keys);
      for (final k in keys) {
        _keys[k] = found[k] ?? const [];
      }
    }
  }

  /// The library path for [r], or null when it can't be matched safely.
  Future<String?> resolve(TrackRef r) async {
    await prime([r]);
    for (final p in [r.path, r.origPath]) {
      if (p != null && _songs[p] == true) return p;
    }
    if (r.sha256 case final h?) {
      if (_sha[h] case final p?) return p;
    }
    final k = r.dupKey;
    if (k.isEmpty) return null;
    final cands = _keys[k] ?? const [];
    final d = r.duration;
    final hits = d == null
        ? cands
        : [
            for (final c in cands)
              if (c.duration != null && (c.duration! - d).abs() <= durationSlack) c
          ];
    final paths = {for (final c in hits) c.path};
    return paths.length == 1 ? paths.first : null;
  }

  Future<String?> resolveEntry(JournalEntry e) => resolve(TrackRef.fromEntry(e));
}

class PhoneSyncResult {
  const PhoneSyncResult({
    this.plays = 0,
    this.ratings = 0,
    this.unmatched = 0,
    this.ackSeq = 0,
    this.playedPaths = const [],
  });

  /// New plays added to the history.
  final int plays;

  /// Rating/favourite entries applied.
  final int ratings;

  /// Entries whose song couldn't be found (counted, not retried).
  final int unmatched;

  /// Highest journal seq processed; the phone may trim up to this.
  final int ackSeq;

  /// Library paths of the newly imported plays.
  final List<String> playedPaths;

  PhoneSyncResult operator +(PhoneSyncResult o) => PhoneSyncResult(
      plays: plays + o.plays,
      ratings: ratings + o.ratings,
      unmatched: unmatched + o.unmatched,
      ackSeq: ackSeq > o.ackSeq ? ackSeq : o.ackSeq,
      playedPaths: [...playedPaths, ...o.playedPaths]);

  Map<String, Object> toJson() =>
      {'plays': plays, 'ratings': ratings, 'unmatched': unmatched, 'ackSeq': ackSeq};

  String get summary =>
      'Imported $plays plays, $ratings ratings${unmatched > 0 ? ' · $unmatched not matched' : ''}';
}

/// Imports the phone's play/rating journal (beats-me) into the library.
class PhoneSync {
  PhoneSync(this.db, {this.onImported});
  final MusicDb db;

  /// Called after every import that added plays or ratings (e.g. to suggest
  /// class history from the new plays).
  void Function(PhoneSyncResult result)? onImported;

  static const app = 'beats-me';

  /// A beats-me play this close to an existing one of the same song is the
  /// same play logged twice (journal and the Windows shared log).
  static const dupWindowMs = 5000;

  static String cursorKey(String deviceId) => 'phone_journal_seq:$deviceId';

  Future<int> cursor(String deviceId) async =>
      int.tryParse(await db.setting(cursorKey(deviceId)) ?? '') ?? 0;

  /// Imports [entries] newer than the device's cursor; ratings are applied in
  /// seq order (the phone wins). The cursor moves past every processed entry,
  /// matched or not.
  Future<PhoneSyncResult> importJournal(String deviceId, List<JournalEntry> entries) async {
    final from = await cursor(deviceId);
    final todo = [for (final e in entries) if (e.seq > from) e]
      ..sort((a, b) => a.seq.compareTo(b.seq));
    if (todo.isEmpty) return PhoneSyncResult(ackSeq: from);

    final resolver = PathResolver(db);
    await resolver.prime(todo.map(TrackRef.fromEntry));
    var ratings = 0, unmatched = 0;
    final playRows = <Map<String, Object?>>[];
    for (final e in todo) {
      if (!e.isPlay && !e.isRate) continue;
      final path = await resolver.resolveEntry(e);
      if (path == null) {
        unmatched++;
        continue;
      }
      if (e.isPlay) {
        playRows.add({
          'path': path,
          'at': e.at,
          'listened': e.listened ?? 0,
          'done': e.done ?? false,
          'app': app,
        });
      } else {
        if (e.rating != null) await db.setRating(path, e.rating!);
        if (e.fav != null) await db.setFav(path, e.fav!);
        ratings++;
      }
    }
    final added = await importPlayRows(playRows);
    final ack = todo.last.seq > from ? todo.last.seq : from;
    await db.setSetting(cursorKey(deviceId), '$ack');
    final r = PhoneSyncResult(
        plays: added.length,
        ratings: ratings,
        unmatched: unmatched,
        ackSeq: ack,
        playedPaths: added);
    if (r.plays > 0 || r.ratings > 0) onImported?.call(r);
    return r;
  }

  /// Parses JSONL (e.g. read over USB) and imports it for [deviceId].
  Future<PhoneSyncResult> importJournalText(String deviceId, String jsonl) =>
      importJournal(deviceId, parseJournal(jsonl));

  /// Imports a journal file that may hold several devices, using each
  /// entry's `device` field ('unknown' when empty).
  Future<PhoneSyncResult> importJournalByDevice(String jsonl) async {
    final byDevice = <String, List<JournalEntry>>{};
    for (final e in parseJournal(jsonl)) {
      (byDevice[e.device.isEmpty ? 'unknown' : e.device] ??= []).add(e);
    }
    var total = const PhoneSyncResult();
    for (final MapEntry(:key, :value) in byDevice.entries) {
      total += await importJournal(key, value);
    }
    return total;
  }

  /// Adds play rows (`path`, `at`, `listened`, `done`, `app`) via
  /// [MusicDb.importPlays], skipping exact repeats (same path and time) and
  /// beats-me rows within [dupWindowMs] of a beats-me play of the same path.
  /// Returns the paths of the plays added.
  Future<List<String>> importPlayRows(List<Map<String, Object?>> rows) async {
    final paths = {
      for (final r in rows)
        if (r['path'] is String && r['at'] is int) r['path'] as String
    };
    final any = await db.playTimes(paths);
    final ours = await db.playTimes(paths, app: app);
    final keep = <Map<String, Object?>>[];
    for (final r in rows) {
      final path = r['path'], at = r['at'];
      if (path is! String || at is! int) continue;
      final all = any[path] ??= [];
      if (all.contains(at)) continue;
      if (r['app'] == app) {
        final ts = ours[path] ??= [];
        if (ts.any((t) => (t - at).abs() <= dupWindowMs)) continue;
        ts.add(at);
      }
      all.add(at);
      keep.add(r);
    }
    await db.importPlays(keep);
    return [for (final r in keep) r['path'] as String];
  }
}
