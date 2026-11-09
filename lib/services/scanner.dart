import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:shared_core/shared_core.dart';

import 'db.dart';
import 'deezer_genre.dart';
import 'genre_names.dart';
import 'musicbrainz.dart';
import 'tempo_stats.dart';

class ScanOptions {
  const ScanOptions({
    this.analyzeBpm = true,
    this.fetchLyrics = true,
    this.lookupMusicBrainz = true,
    this.lookupYear = false,
    this.quickLyrics = true,
    this.checkAudio = true,
    this.forceFull = false,
    this.localOnly = false,
    this.refreshOnline = false,
  });
  final bool analyzeBpm;

  /// Look at every file again, ignoring which artist folders earlier scans
  /// finished (see `scan_dirs`).
  final bool forceFull;
  final bool localOnly;

  /// Retry missing online data, including previous misses and recent failures.
  /// Existing lyrics, genres and years are never overwritten.
  final bool refreshOnline;
  final bool fetchLyrics;
  final bool lookupMusicBrainz;

  /// Quick damage check of new and changed files (see [quickCheckFile]).
  final bool checkAudio;

  /// Only ask the fast, high-yield lyrics sources (LRCLIB, NetEase) instead of
  /// trying all seven for every song that has no lyrics.
  final bool quickLyrics;

  /// Also look up missing years. One MusicBrainz request per album (songs
  /// without an album: per song).
  final bool lookupYear;

  ScanOptions copyWith({
    bool? analyzeBpm,
    bool? fetchLyrics,
    bool? lookupMusicBrainz,
    bool? lookupYear,
    bool? quickLyrics,
    bool? checkAudio,
    bool? forceFull,
    bool? localOnly,
    bool? refreshOnline,
  }) => ScanOptions(
    analyzeBpm: analyzeBpm ?? this.analyzeBpm,
    fetchLyrics: fetchLyrics ?? this.fetchLyrics,
    lookupMusicBrainz: lookupMusicBrainz ?? this.lookupMusicBrainz,
    lookupYear: lookupYear ?? this.lookupYear,
    quickLyrics: quickLyrics ?? this.quickLyrics,
    checkAudio: checkAudio ?? this.checkAudio,
    forceFull: forceFull ?? this.forceFull,
    localOnly: localOnly ?? this.localOnly,
    refreshOnline: refreshOnline ?? this.refreshOnline,
  );
}

/// Kinds of work a full scan can finish for a folder (bits of
/// `scan_dirs.done_ops`).
abstract final class ScanOps {
  static const bpm = 1, lyrics = 2, genre = 4, year = 8, audio = 16;

  static int of(ScanOptions o) =>
      (o.analyzeBpm ? bpm : 0) |
      (o.fetchLyrics ? lyrics : 0) |
      (o.lookupMusicBrainz ? genre : 0) |
      (o.lookupMusicBrainz && o.lookupYear ? year : 0) |
      (o.checkAudio ? audio : 0);
}

/// Progress and throughput of one kind of work (items per second, recent).
class OpStat {
  const OpStat(this.done, this.total, this.perSec, {this.pending, this.smoothedEta});
  static const none = OpStat(0, 0, 0);
  final int done;
  final int total;
  final double perSec;

  /// Items still needing real work (excludes already-processed ones that
  /// finish instantly); defaults to everything not yet done.
  final int? pending;

  /// The steadied estimate shown to the user (see [EtaSmoother]); when null
  /// the estimate comes straight from [perSec].
  final Duration? smoothedEta;

  int get remaining => total > done ? total - done : 0;

  int get _left => math.min(remaining, pending ?? remaining);

  /// Straight from the current rate; null while the rate is still unknown.
  Duration? get rawEta => _left == 0
      ? Duration.zero
      : perSec <= 0
      ? null
      : Duration(seconds: (_left / perSec).ceil());

  /// Null while the rate is still unknown.
  Duration? get eta => _left == 0 ? Duration.zero : smoothedEta ?? rawEta;
}

int _wallMs() => _wall.elapsedMilliseconds;
final _wall = Stopwatch()..start();

/// Throughput over the last [window] of wall-clock time, idle gaps included,
/// so a burst of completions after a pause doesn't look like a fast rate and
/// a pause doesn't look like a stall. Unknown (0) until [warmUp] has passed
/// and [minSamples] items finished.
class RateMeter {
  RateMeter({
    int Function()? nowMs,
    this.window = const Duration(minutes: 5),
    this.warmUp = const Duration(seconds: 30),
    this.minSamples = 5,
  }) : _now = nowMs ?? _wallMs {
    _start = _now();
  }

  final int Function() _now;
  final Duration window;
  final Duration warmUp;
  final int minSamples;
  late final int _start;
  final _times = ListQueue<int>();
  int _count = 0;

  int get count => _count;

  void tick() {
    final t = _now();
    _times.add(t);
    _count++;
    _trim(t);
  }

  void _trim(int t) {
    while (_times.isNotEmpty && t - _times.first > window.inMilliseconds) {
      _times.removeFirst();
    }
  }

  double get perSec {
    final t = _now();
    final elapsed = t - _start;
    if (_count < minSamples || elapsed < warmUp.inMilliseconds || elapsed <= 0) return 0;
    _trim(t);
    // nothing in the window (a long pause): fall back to the whole-run average
    if (_times.isEmpty) return _count * 1000 / elapsed;
    return _times.length * 1000 / math.min(elapsed, window.inMilliseconds);
  }
}

/// Steadies a displayed ETA: it counts down by itself between updates, takes
/// a new estimate at most every [every], and moves at most [maxStep] (as a
/// fraction) towards it per update so noise can't make it jump around.
class EtaSmoother {
  EtaSmoother({int Function()? nowMs, this.every = const Duration(seconds: 5), this.maxStep = 0.15})
    : _now = nowMs ?? _wallMs;

  final int Function() _now;
  final Duration every;
  final double maxStep;
  Duration? _shown;
  int _at = 0;

  Duration? _set(Duration d, int t) {
    _shown = d;
    _at = t;
    return d;
  }

  Duration? next(Duration? raw) {
    final t = _now();
    if (raw == Duration.zero) return _set(Duration.zero, t);
    final shown = _shown;
    if (shown == null) return raw == null ? null : _set(raw, t);
    final ms = shown.inMilliseconds - (t - _at);
    final expected = Duration(milliseconds: math.max(0, ms));
    if (raw == null || t - _at < every.inMilliseconds) return expected;
    // counted down to nothing while work remains: start again from the estimate
    if (expected == Duration.zero) return _set(raw, t);
    final lo = expected.inMilliseconds * (1 - maxStep);
    final hi = expected.inMilliseconds * (1 + maxStep);
    return _set(Duration(milliseconds: raw.inMilliseconds.toDouble().clamp(lo, hi).round()), t);
  }
}

class ScanProgress {
  const ScanProgress(
    this.done,
    this.total,
    this.current, {
    this.onlineDone = 0,
    this.onlineTotal = 0,
    this.throttled = 0,
    this.skippedDirs = 0,
    this.currentGenre,
    this.analyze = OpStat.none,
    this.lyrics = OpStat.none,
    this.genre = OpStat.none,
  });

  final OpStat analyze;
  final OpStat lyrics;

  /// Counted in lookups (one per album, or per song without an album), not
  /// songs: that's what costs time.
  final OpStat genre;

  /// Artist folders left out because an earlier scan finished them.
  final int skippedDirs;

  /// Main genre of the artist folder being scanned (null: unknown).
  final String? currentGenre;

  List<OpStat> get _ops => [analyze, lyrics, genre];

  /// Time until everything finishes (the slowest operation whose rate is
  /// known); null if nothing is known yet. See [etaIsLowerBound].
  Duration? get eta {
    Duration? worst;
    var unknown = false;
    for (final o in _ops) {
      final e = o.eta;
      if (e == null) {
        unknown = true;
      } else if (worst == null || e > worst) {
        worst = e;
      }
    }
    if (unknown && (worst == null || worst == Duration.zero)) return null;
    return worst;
  }

  /// True when some operation is still estimating, so [eta] is a minimum.
  bool get etaIsLowerBound => eta != null && _ops.any((o) => o.eta == null);

  final int done;
  final int total;
  final String current;

  /// Completed online tasks (one lyrics and/or genre/year task per song).
  final int onlineDone;

  /// Online tasks queued alongside the local pass, not unique songs.
  final int onlineTotal;

  /// 429/503 responses seen so far (the scan slows down by itself when > 0).
  final int throttled;
}

/// Plain text of lyrics for searching (timestamps removed).
String lyricsPlainText(Lyrics l) => l.lines.map((e) => e.text).where((t) => t.isNotEmpty).join('\n');

/// Scans folders and keeps the database in step with the files on disk.
///
/// Local work (tags, sidecars, BPM analysis) runs [localWorkers] files at a
/// time. Lyrics and genre/year have independent queues and worker pools, so
/// one provider cannot hold up the other. Requests still share [PoliteHttp],
/// so each host keeps its own pace and backs off on 429.
class Scanner {
  Scanner(
    this.db, {
    EnrichService? enricher,
    MusicBrainz? musicBrainz,
    DeezerGenres? deezer,
    PoliteHttp? net,
    int? localWorkers,
    DateTime Function()? now,
    int? onlineWorkers,
    int? lyricsWorkers,
    int? genreWorkers,
  }) : net = net ?? enricher?.net ?? PoliteHttp(),
       _now = now ?? DateTime.now,
       lyricsWorkers = lyricsWorkers ?? onlineWorkers ?? 8,
       genreWorkers = genreWorkers ?? onlineWorkers ?? 6,
       localWorkers = localWorkers ?? math.max(1, math.min(4, Platform.numberOfProcessors - 1)) {
    this.enricher = enricher ?? EnrichService(net: this.net);
    mb = musicBrainz ?? MusicBrainz(net: this.net);
    this.deezer = deezer ?? DeezerGenres(net: this.net);
  }

  final MusicDb db;
  final PoliteHttp net;
  final DateTime Function() _now;
  static const retryCooldown = Duration(days: 30);
  late final EnrichService enricher;
  late final MusicBrainz mb;
  late final DeezerGenres deezer;
  int localWorkers;
  int lyricsWorkers;
  int genreWorkers;

  /// Legacy worker setting; setting it applies the limit to both pools.
  int get onlineWorkers => lyricsWorkers;
  set onlineWorkers(int value) {
    lyricsWorkers = value;
    genreWorkers = value;
  }

  bool cancelled = false;
  List<String> explicitWords = [...defaultExplicitWords];
  final Map<String, Future<LyricsHit?>> _lyricsCache = {};
  final Set<String> _freshlyAnalyzed = {};
  RateMeter _lyricsMeter = RateMeter();
  RateMeter _genreMeter = RateMeter();

  /// Songs whose lyrics this scan expects to look up, and those done.
  final Set<String> _lyricsWanted = {};
  final Set<String> _lyricsFinished = {};

  /// Genre/year lookups (see [_mbKey]) this scan expects, with how many songs
  /// share each, the key each song uses, and the lookups that finished.
  final Map<String, int> _genreWanted = {};
  final Map<String, String> _genreKeyOf = {};
  final Set<String> _genreResolved = {};
  void Function()? _onOpDone;

  /// Fast tags-only pass: lists every audio file, reads tags and stores songs
  /// that are not in the database yet (no BPM, lyrics or online lookups), so
  /// artists and albums are searchable straight away. Songs whose files are
  /// gone are dropped and changed files (size/mtime) get their tags re-read;
  /// other rows are kept. Folders whose root is missing (e.g. an unplugged
  /// drive) are skipped entirely so their songs aren't forgotten.
  Future<List<String>> quickScan(
    List<String> folders, {
    void Function(ScanProgress)? onProgress,
    void Function()? onBatch,
  }) async {
    cancelled = false;
    final errors = <String>[];
    final files = <String>[];
    final scanned = <String>[];
    for (final f in folders) {
      onProgress?.call(ScanProgress(0, 0, 'Finding files in ${baseName(f)}…'));
      await Future<void>.delayed(Duration.zero);
      try {
        if (!await Directory(f).exists()) continue;
        files.addAll(await scanMp3s(f));
        scanned.add(f);
      } catch (e) {
        errors.add('$f: $e');
      }
    }
    final known = await db.knownSongStamps();
    final present = files.toSet();
    await db.deleteSongs(known.keys.where((p) => scanned.any((f) => _isUnder(p, f)) && !present.contains(p)).toList());
    var done = 0;
    final touched = <String>{};
    for (final p in files) {
      if (cancelled) break;
      done++;
      final old = known[p];
      if (old != null) {
        try {
          final stat = await File(p).stat();
          if (stat.size != old.$1 || stat.modified.millisecondsSinceEpoch != old.$2) {
            await processLocal(p, const ScanOptions(analyzeBpm: false, checkAudio: false));
            touched.add(p);
          }
        } catch (e) {
          errors.add('${baseName(p)}: $e');
        }
      } else {
        try {
          await _quickAdd(p);
          touched.add(p);
        } catch (e) {
          errors.add('${baseName(p)}: $e');
        }
      }
      if (done % 50 == 0) {
        onProgress?.call(ScanProgress(done, files.length, baseName(p)));
        onBatch?.call();
        await Future<void>.delayed(Duration.zero);
      }
    }
    onProgress?.call(ScanProgress(done, files.length, ''));
    // new or re-tagged files need the full scan again in their artist folder
    await db.forgetScanDirs([
      for (final p in touched)
        for (final f in scanned)
          if (_isUnder(p, f)) _groupKey(p, f),
    ]);
    return errors;
  }

  /// The artist folder [path] belongs to: the first folder below [root], or
  /// [root] itself for files lying directly in it.
  static String _groupKey(String path, String root) {
    final r = _withSep(root);
    final rel = path.substring(r.length);
    final i = rel.indexOf(RegExp(r'[\\/]'));
    return i < 0 ? root : '$r${rel.substring(0, i)}';
  }

  static String _withSep(String dir) => dir.endsWith('\\') || dir.endsWith('/') ? dir : '$dir${Platform.pathSeparator}';

  /// Changes when a file is added, removed or renamed under the folder.
  static String _fingerprint(String dir, List<String> files) {
    final skip = _withSep(dir).length;
    // FNV-1a; int arithmetic wraps at 64 bits on the VM
    var h = 0xcbf29ce484222325;
    for (final f in files) {
      final rel = f.length > skip ? f.substring(skip).toLowerCase() : f.toLowerCase();
      for (final c in [...rel.codeUnits, 10]) {
        h = (h ^ c) * 0x100000001b3;
      }
    }
    return '${files.length}:${h.toUnsigned(64).toRadixString(16)}';
  }

  /// Stores a new file from its tags alone.
  Future<void> _quickAdd(String p) async {
    final stat = await File(p).stat();
    final t = await readTags(p);
    final ov = await db.override(p);
    final artist = (ov?['artist'] as String?) ?? t.artist;
    final title = t.title;
    await db.upsertSong(
      Song(
        path: p,
        size: stat.size,
        mtime: stat.modified.millisecondsSinceEpoch,
        title: title,
        artist: artist,
        album: (ov?['album'] as String?) ?? t.album,
        year: (ov?['year'] as int?) ?? t.year,
        genre: (ov?['genre'] as String?) ?? _tagGenre(t.genre),
        addedAt: DateTime.now().millisecondsSinceEpoch,
        dupKey: dupKeyFor(artist, title),
        trackNo: t.trackNo,
        trackTotal: t.trackTotal,
        discNo: t.discNo,
        discTotal: t.discTotal,
        tagsV: 1,
      ),
    );
  }

  static const _algosKey = 'scan_algos';

  /// Full scan: tempo analysis, lyrics and genre/year per [options].
  ///
  /// Artist folders an earlier scan finished (every requested kind of work,
  /// same files) are skipped unless [ScanOptions.forceFull]. Files whose stored
  /// data is already complete skip the local pass and go straight to the
  /// online lookups they still need. With [onlyFiles] just those songs are
  /// processed, nothing is skipped and nothing is deleted.
  Future<List<String>> scanAll(
    List<String> folders, {
    ScanOptions options = const ScanOptions(),
    void Function(ScanProgress)? onProgress,
    List<String>? onlyFiles,
  }) async {
    if (options.localOnly) {
      options = options.copyWith(fetchLyrics: false, lookupMusicBrainz: false);
    }
    cancelled = false;
    explicitWords = await db.explicitWords();
    _mbGenres.clear();
    _mbAlbumInfo.clear();
    _lyricsCache.clear();
    enricher.resetSourceFailures();
    final errors = <String>[];
    final files = <String>[];
    final scanned = <String>[];
    if (onlyFiles != null) files.addAll(onlyFiles);
    for (final f in onlyFiles != null ? const <String>[] : folders) {
      onProgress?.call(ScanProgress(0, 0, 'Finding files in ${baseName(f)}…'));
      await Future<void>.delayed(Duration.zero);
      try {
        files.addAll(await scanMp3s(f));
        scanned.add(f);
      } catch (e) {
        errors.add('$f: $e');
      }
    }
    final present = files.toSet();
    // forget songs that were under a successfully scanned folder but are gone
    final known = await db.knownSongSizes();
    final gone = known.keys.where((p) => scanned.any((f) => _isUnder(p, f)) && !present.contains(p));
    await db.deleteSongs(gone);

    final ops = ScanOps.of(options);
    // new tempo algorithms need every file analysed again
    final algos = allAlgorithms.map((a) => a.id).join(',');
    final algosSame = !options.analyzeBpm || await db.setting(_algosKey) == algos;
    final incremental = onlyFiles == null && !options.forceFull && !options.refreshOnline && algosSame;
    if (onlyFiles == null && options.forceFull) await db.clearScanDirs(scanned);

    // ---- group by artist folder and leave out the finished ones ----
    final work = <String>[];
    final dirs = <String, _DirTrack>{};
    final dirOf = <String, String>{};
    var skippedDirs = 0;
    if (onlyFiles != null) {
      work.addAll(files);
    } else {
      final groups = <String, List<String>>{};
      final rootOf = <String, String>{};
      for (final p in files) {
        final root = scanned.firstWhere((f) => _isUnder(p, f), orElse: () => '');
        if (root.isEmpty) {
          work.add(p);
          continue;
        }
        final k = _groupKey(p, root);
        (groups[k] ??= []).add(p);
        rootOf[k] = root;
      }
      final saved = incremental ? await db.scanDirs() : const <String, (String, int)>{};
      final todo = <String, List<String>>{};
      for (final MapEntry(key: dir, value: list) in groups.entries) {
        final fp = _fingerprint(dir, list);
        final prev = saved[dir];
        final sameFiles = prev != null && prev.$1 == fp;
        if (sameFiles && prev.$2 & ops == ops) {
          skippedDirs++;
          continue;
        }
        dirs[dir] = _DirTrack(rootOf[dir]!, fp, list.length, sameFiles ? prev.$2 : 0, ops);
        for (final p in list) {
          dirOf[p] = dir;
        }
        todo[dir] = list;
      }
      for (final dir in await _genreOrder(todo)) {
        work.addAll(todo[dir]!);
      }
    }

    /// One file is through; saves its folder once all of its files are.
    Future<void> finish(String p, int ok) async {
      final dir = dirOf[p];
      if (dir == null) return;
      final t = dirs[dir]!;
      t.ok &= ok;
      if (--t.pending == 0 && !cancelled) {
        try {
          await db.saveScanDir(dir, t.root, t.fingerprint, t.before | t.ok);
        } catch (e) {
          errors.add('$dir: $e');
        }
      }
    }

    // ---- which files still need the local pass ----
    onProgress?.call(ScanProgress(0, 0, 'Checking ${work.length} files…', skippedDirs: skippedDirs));
    final snap = await db.scanSnapshot();
    final health = options.checkAudio ? await db.healthStamps() : const <String, (int, int)>{};
    final local = <String>[];
    final direct = <Song>[];
    for (var i = 0; i < work.length && !cancelled; i += 64) {
      final chunk = work.sublist(i, math.min(i + 64, work.length));
      final ready = await Future.wait([for (final p in chunk) _localDone(p, snap[p], options, health, algosSame)]);
      for (var j = 0; j < chunk.length; j++) {
        if (ready[j]) {
          direct.add(snap[chunk[j]]!);
        } else {
          local.add(chunk[j]);
        }
      }
      if (i % 1024 == 0) {
        onProgress?.call(ScanProgress(0, 0, 'Checking files… $i/${work.length}', skippedDirs: skippedDirs));
      }
    }

    var done = 0, onlineDone = 0, onlineTotal = 0;
    var current = '';
    String? currentGenre;
    final analyzeMeter = RateMeter();
    _lyricsMeter = RateMeter();
    _genreMeter = RateMeter();
    _lyricsWanted.clear();
    _lyricsFinished.clear();
    _genreWanted.clear();
    _genreKeyOf.clear();
    _genreResolved.clear();
    var localFinished = false;
    var freshDone = 0;
    _freshlyAnalyzed.clear();

    // Totals up front (from what the database knows) so the ETAs don't keep
    // growing; corrected per song as the local pass reads each file.
    var analyzeExpected = 0;
    for (final p in local) {
      final row = snap[p];
      if (options.analyzeBpm && row?.medianBpm == null) analyzeExpected++;
      if (row != null) {
        _expect(row, options);
      } else if (options.fetchLyrics) {
        _lyricsWanted.add(p);
      }
    }

    final analyzeEta = EtaSmoother(), lyricsEta = EtaSmoother(), genreEta = EtaSmoother();
    OpStat stat(int done, int total, RateMeter m, EtaSmoother s, {int? pending}) {
      final raw = OpStat(done, total, m.perSec, pending: pending);
      return OpStat(done, total, raw.perSec, pending: pending, smoothedEta: s.next(raw.rawEta));
    }

    void report() {
      onProgress?.call(
        ScanProgress(
          done,
          local.length,
          current,
          onlineDone: onlineDone,
          onlineTotal: onlineTotal,
          throttled: net.throttled,
          skippedDirs: skippedDirs,
          currentGenre: currentGenre,
          analyze: stat(
            done,
            local.length,
            analyzeMeter,
            analyzeEta,
            pending: localFinished ? 0 : math.max(0, analyzeExpected - freshDone),
          ),
          lyrics: stat(
            _lyricsFinished.length,
            math.max(_lyricsWanted.length, _lyricsFinished.length),
            _lyricsMeter,
            lyricsEta,
          ),
          genre: stat(
            _genreResolved.length,
            math.max(_genreWanted.length, _genreResolved.length),
            _genreMeter,
            genreEta,
          ),
        ),
      );
    }

    _onOpDone = report;

    final lyricsQueue = _OnlineQueue();
    final genreQueue = _OnlineQueue();
    void enqueue(Song s) {
      final lyrics = _wantsLyrics(s, options);
      final genre = _wantsMb(s, options);
      final job = _OnlineSong(s, (lyrics ? 1 : 0) + (genre ? 1 : 0), ops);
      onlineTotal += job.pending;
      if (lyrics) lyricsQueue.add(job);
      if (genre) genreQueue.add(job);
    }

    // complete locally: online lookups can start right away
    for (final s in direct) {
      _expect(s, options);
      if (needsOnline(s, options)) {
        enqueue(s);
      } else {
        await finish(s.path, ops);
      }
    }

    Future<void> onlineWorker(_OnlineQueue queue, {required bool lyrics}) async {
      while (!cancelled) {
        if (queue.jobs.isEmpty) {
          if (localFinished) return;
          final w = Completer<void>();
          queue.waiters.add(w);
          await w.future;
          continue;
        }
        final job = queue.jobs.removeFirst();
        final s = job.song;
        final stageOps = lyrics ? ScanOps.lyrics : ScanOps.genre | ScanOps.year;
        var ok = ops & ~stageOps;
        try {
          void onError(Object e) => errors.add('${baseName(s.path)}: $e');
          ok = await (lyrics
              ? _onlineLyrics(s, options, onError: onError)
              : _onlineGenre(s, options, onError: onError));
        } catch (e) {
          errors.add('${baseName(s.path)}: $e');
        }
        onlineDone++;
        job.ok &= ok;
        if (--job.pending == 0) await finish(s.path, job.ok);
        report();
      }
    }

    var next = 0;
    Future<void> localWorker() async {
      while (!cancelled) {
        final start = next;
        next += 16;
        if (start >= local.length) return;
        final batch = <(Song, List<TempoSeg>)>[];
        final batchClock = Stopwatch()..start();
        Future<void> flush() async {
          if (batch.isEmpty) return;
          try {
            await db.upsertSongs(batch);
          } catch (e) {
            errors.add('Saving local scan batch: $e');
            for (final (s, _) in batch) {
              await finish(s.path, 0);
            }
            batch.clear();
            batchClock.reset();
            return;
          }
          for (final (s, _) in batch) {
            _expect(s, options);
            if (needsOnline(s, options)) {
              enqueue(s);
            } else {
              await finish(s.path, ops);
            }
          }
          batch.clear();
          batchClock.reset();
        }

        for (final p in local.sublist(start, math.min(start + 16, local.length))) {
          if (cancelled) break;
          current = baseName(p);
          currentGenre = _dirGenre[dirOf[p]];
          report();
          Song? s;
          try {
            s = await processLocal(p, options, store: (song, segments) async => batch.add((song, segments)));
          } catch (e) {
            errors.add('${baseName(p)}: $e');
          }
          done++;
          if (_freshlyAnalyzed.remove(p)) {
            freshDone++;
            analyzeMeter.tick();
          }
          if (s == null) {
            await finish(p, 0);
          }
          // Slow BPM analysis should not hold up the online queue.
          if (batchClock.elapsedMilliseconds >= 250) await flush();
          report();
        }
        await flush();
        report();
      }
    }

    final online = [
      for (var i = 0; i < math.max(1, lyricsWorkers); i++) onlineWorker(lyricsQueue, lyrics: true),
      for (var i = 0; i < math.max(1, genreWorkers); i++) onlineWorker(genreQueue, lyrics: false),
    ];
    await Future.wait([for (var i = 0; i < localWorkers; i++) localWorker()]);
    localFinished = true;
    lyricsQueue.poke();
    genreQueue.poke();
    await Future.wait(online);
    if (!cancelled && onlyFiles == null && options.analyzeBpm) {
      await db.setSetting(_algosKey, algos);
    }
    current = '';
    done = local.length;
    report();
    _onOpDone = null;
    return errors;
  }

  /// True when the stored row of an unchanged file already has everything
  /// the local pass would produce, so the file can skip it.
  Future<bool> _localDone(String p, Song? row, ScanOptions o, Map<String, (int, int)> health, bool incremental) async {
    // no BPM yet: a sidecar may have appeared, or analysis is wanted
    if (!incremental || row == null || row.tagsV < 1 || row.medianBpm == null) {
      return false;
    }
    try {
      final st = await File(p).stat();
      final mtime = st.modified.millisecondsSinceEpoch;
      if (st.size != row.size || mtime != row.mtime) return false;
      return !o.checkAudio || health[p] == (st.size, mtime);
    } catch (_) {
      return false;
    }
  }

  /// Artist folders in scan order: those whose main genre has the most songs
  /// in the library first, then late genres (see [isLateGenre]), then folders
  /// with no known genre. A folder's main genre is its most common one.
  Future<List<String>> _genreOrder(Map<String, List<String>> dirs) async {
    final genreOf = await db.songGenres();
    final canon = <String, String>{};
    String? name(String? raw) {
      if (raw == null) return null;
      final g = canon[raw] ??= cleanGenre(raw);
      return g.isEmpty || g.toLowerCase() == unknownGenre.toLowerCase() ? null : g;
    }

    final total = <String, int>{};
    for (final raw in genreOf.values) {
      final g = name(raw);
      if (g != null) total[g] = (total[g] ?? 0) + 1;
    }
    final main = <String, String?>{};
    for (final MapEntry(key: dir, value: list) in dirs.entries) {
      final own = <String, int>{};
      for (final p in list) {
        final g = name(genreOf[p]);
        if (g != null) own[g] = (own[g] ?? 0) + 1;
      }
      String? best;
      for (final g in own.keys) {
        if (best == null || own[g]! > own[best]! || (own[g] == own[best] && (total[g]! > total[best]!))) {
          best = g;
        }
      }
      main[dir] = best;
    }
    int rank(String d) {
      final g = main[d];
      return g == null ? 2 : (isLateGenre(g) ? 1 : 0);
    }

    final order = dirs.keys.toList()
      ..sort((a, b) {
        final r = rank(a).compareTo(rank(b));
        if (r != 0) return r;
        final ga = main[a], gb = main[b];
        if (ga != null && gb != null && ga != gb) {
          final c = total[gb]!.compareTo(total[ga]!);
          return c != 0 ? c : ga.compareTo(gb);
        }
        return a.toLowerCase().compareTo(b.toLowerCase());
      });
    _dirGenre = main;
    return order;
  }

  Map<String, String?> _dirGenre = {};

  /// Records the online work [s] is expected to need (see [_lyricsWanted],
  /// [_genreWanted]), replacing what an earlier guess for it said.
  void _expect(Song s, ScanOptions o) {
    if (_wantsLyrics(s, o)) {
      _lyricsWanted.add(s.path);
    } else if (!_lyricsFinished.contains(s.path)) {
      _lyricsWanted.remove(s.path);
    }
    final k = _wantsMb(s, o) ? _mbKey(s, o) : null;
    final old = _genreKeyOf[s.path];
    if (old == k) return;
    if (old != null) {
      final n = (_genreWanted[old] ?? 1) - 1;
      if (n <= 0 && !_genreResolved.contains(old)) {
        _genreWanted.remove(old);
      } else {
        _genreWanted[old] = math.max(0, n);
      }
    }
    if (k == null) {
      _genreKeyOf.remove(s.path);
    } else {
      _genreWanted[k] = (_genreWanted[k] ?? 0) + 1;
      _genreKeyOf[s.path] = k;
    }
  }

  static bool _isUnder(String path, String dir) {
    final d = dir.endsWith('\\') || dir.endsWith('/') ? dir : '$dir${Platform.pathSeparator}';
    return path.toLowerCase().startsWith(d.toLowerCase());
  }

  /// Local and online work for one file, one after the other.
  Future<Song> processFile(String path, ScanOptions o) async {
    final s = await processLocal(path, o);
    return needsOnline(s, o) ? processOnline(s, o) : s;
  }

  bool _wantsLyrics(Song s, ScanOptions o) =>
      !o.localOnly && o.fetchLyrics && (s.lyrics ?? '').trim().isEmpty && (!s.lyricsChecked || o.refreshOnline);

  bool _wantsMb(Song s, ScanOptions o) =>
      !o.localOnly &&
      o.lookupMusicBrainz &&
      s.artist != null &&
      s.title != null &&
      (_wantsGenre(s, o) || _wantsYear(s, o));

  bool _wantsGenre(Song s, ScanOptions o) => (!s.mbChecked || o.refreshOnline) && _noGenre(s);

  bool _wantsYear(Song s, ScanOptions o) => o.lookupYear && s.year == null && (!s.yearChecked || o.refreshOnline);

  // a genre inherited from the album/artist lists counts as having one
  static String? _tagGenre(String? g) {
    final c = cleanGenre(g);
    return c.isEmpty ? null : c;
  }

  static bool _noGenre(Song s) => (s.genre ?? '').trim().isEmpty;

  /// Genres found this scan, one lookup per album (or per song without an album).
  final Map<String, Future<String?>> _mbGenres = {};

  bool needsOnline(Song s, ScanOptions o) => _wantsLyrics(s, o) || _wantsMb(s, o);

  /// Reads one file (no network) and stores what it finds.
  Future<Song> processLocal(String path, ScanOptions o, {Future<void> Function(Song, List<TempoSeg>)? store}) async {
    final stat = await File(path).stat();
    final old = await db.song(path);
    final same =
        old != null && old.size == stat.size && old.mtime == stat.modified.millisecondsSinceEpoch && old.tagsV >= 1;
    final tags = same ? null : await readTags(path);

    final ov = await db.override(path);
    var tempo = await BpmStore.load(path);
    // The DB's manual BPM fix wins; a fix only found in the sidecar (e.g. a
    // rebuilt library) is adopted.
    final fix = MusicDb.bpmFixOf(ov) ?? tempo?.manual;
    final incomplete = tempo != null && !allAlgorithms.every((a) => tempo!.byAlgo.containsKey(a.id));
    String? decodeError;
    if ((tempo == null || incomplete) && o.analyzeBpm) {
      try {
        tempo = (await analyzeFile(path)).withManual(fix);
        await BpmStore.save(path, tempo);
        _freshlyAnalyzed.add(path);
      } on UnsupportedError {
        // no decoder for this format (m4a/wma need ffmpeg): keep it without BPM
      } on FormatException catch (e) {
        // undecodable file: keep it without BPM, and flag it as damaged
        decodeError = e.message;
      }
    }
    if (tempo != null && tempo.manual != fix) {
      tempo = tempo.withManual(fix);
      try {
        await BpmStore.save(path, tempo);
      } catch (_) {
        // read-only folder: the DB keeps the fix
      }
    }
    if (fix != null && MusicDb.bpmFixOf(ov) == null) {
      await db.setBpmFix(path, scale: fix.scale, bpm: fix.bpm);
    }
    final stats = TempoStats.of(tempo?.mapFor(baselineId));
    final title = same ? old.title : tags!.title;
    final artist = (ov?['artist'] as String?) ?? (same ? old.artist : tags!.artist);
    final album = (ov?['album'] as String?) ?? (same ? old.album : tags!.album);
    final year = (ov?['year'] as int?) ?? (same ? old.year : tags!.year);
    final genre = (ov?['genre'] as String?) ?? (same ? old.ownGenre : _tagGenre(tags!.genre));

    var lyricsText = same ? old.lyrics : null;
    var lyricsChecked = same && old.lyricsChecked;
    if (!same || !lyricsChecked) {
      final t = tags ?? await readTags(path);
      final local = await EnrichService.localLyrics(path, embedded: t.lyrics);
      if (local != null) {
        lyricsText = lyricsPlainText(local);
        lyricsChecked = true;
      }
    }

    final song = Song(
      path: path,
      size: stat.size,
      mtime: stat.modified.millisecondsSinceEpoch,
      title: title,
      artist: artist,
      album: album,
      year: year,
      genre: genre,
      duration: tempo?.durationSec ?? old?.duration,
      avgBpm: stats.avg,
      medianBpm: stats.median,
      minBpm: stats.min,
      maxBpm: stats.max,
      bpmStddev: stats.stddev,
      lyrics: lyricsText,
      lyricsChecked: lyricsChecked,
      mbChecked: same && old.mbChecked,
      yearChecked: same && old.yearChecked,
      rating: old?.rating ?? 0,
      fav: old?.fav ?? false,
      addedAt: old?.addedAt ?? DateTime.now().millisecondsSinceEpoch,
      explicit: containsExplicit(lyricsText, explicitWords),
      dupKey: dupKeyFor(artist, title),
      trackNo: same ? old.trackNo : tags!.trackNo,
      trackTotal: same ? old.trackTotal : tags!.trackTotal,
      discNo: same ? old.discNo : tags!.discNo,
      discTotal: same ? old.discTotal : tags!.discTotal,
      tagsV: 1,
      loudness: tempo?.loudness ?? old?.loudness,
    );
    if (o.checkAudio) await _checkAudio(path, stat, decodeError);
    if (store == null) {
      await db.upsertSong(song, segments: stats.segments);
    } else {
      await store(song, stats.segments);
    }
    return song;
  }

  /// Quick damage check of a new or changed file (see [quickCheckFile]); a
  /// file the tempo analyser could not decode is flagged directly.
  Future<void> _checkAudio(String path, FileStat stat, String? decodeError) async {
    final size = stat.size, mtime = stat.modified.millisecondsSinceEpoch;
    if (decodeError != null) {
      final msg = decodeError.length > 160 ? '${decodeError.substring(0, 160)}…' : decodeError;
      await db.recordHealth(
        path,
        damaged: true,
        reason: 'could not decode: $msg',
        depth: 'decode',
        size: size,
        mtime: mtime,
      );
      return;
    }
    final prev = (await db.healthOf([path]))[path];
    if (prev != null && prev.size == size && prev.mtime == mtime) return;
    try {
      final r = await quickCheckFile(path);
      await db.recordHealth(path, damaged: r.damaged, reason: r.reason, depth: 'quick', size: size, mtime: mtime);
    } on FileSystemException {
      // unreadable right now (locked, offline drive): try again next scan
    }
  }

  /// Fetches missing lyrics and genre/year. Lyrics and MusicBrainz are different
  /// hosts, so they run side by side. A network failure leaves the song
  /// unchecked so a later scan retries it.
  Future<Song> processOnline(Song s, ScanOptions o) async {
    await Future.wait([_onlineLyrics(s, o), _onlineGenre(s, o)]);
    return s;
  }

  /// Each stage returns all requested bits except its own failed operations.
  Future<int> _onlineLyrics(Song s, ScanOptions o, {void Function(Object)? onError}) async {
    if (!_wantsLyrics(s, o)) return ScanOps.of(o);
    String? lyricsText;
    var lyricsChecked = s.lyricsChecked;

    var fromCache = false;
    try {
      final t = await readTags(s.path);
      // a lyrics file dropped next to the song since the last scan
      final local = await EnrichService.localLyrics(s.path, embedded: t.lyrics);
      if (local != null) {
        lyricsText = lyricsPlainText(local);
        fromCache = true;
      } else {
        final key =
            'lyrics|${o.quickLyrics}|${dupKeyFor(s.artist, s.title).isEmpty ? s.path : dupKeyFor(s.artist, s.title)}';
        fromCache = _lyricsCache.containsKey(key);
        final hit = await _lyricsCache.putIfAbsent(
          key,
          () => _persistedLookup<LyricsHit?>(
            key,
            o,
            () => enricher.fetchLyricsHit(t, durationSec: s.duration, quick: o.quickLyrics),
            (hit) => hit == null
                ? null
                : jsonEncode({'text': hit.text, 'id': hit.sourceId, 'name': hit.sourceName, 'synced': hit.synced}),
            (text) {
              if (text == null) return null;
              final j = jsonDecode(text) as Map<String, dynamic>;
              return LyricsHit(j['text'] as String, j['id'] as String, j['name'] as String, j['synced'] as bool);
            },
          ),
        );
        if (hit != null) {
          await EnrichService.lyricsFile(s.path).writeAsString(hit.text);
          lyricsText = lyricsPlainText(Lyrics.parse(hit.text));
        }
      }
      lyricsChecked = true;
    } catch (e) {
      lyricsChecked = false;
      onError?.call(e);
      if (onError == null) rethrow;
    }
    _lyricsFinished.add(s.path);
    if (!fromCache) _lyricsMeter.tick();
    _onOpDone?.call();
    await db.updateOnline(
      s.path,
      lyrics: lyricsText,
      lyricsChecked: lyricsChecked,
      explicit: lyricsText == null ? null : containsExplicit(lyricsText, explicitWords),
    );
    return lyricsChecked ? ScanOps.of(o) : ScanOps.of(o) & ~ScanOps.lyrics;
  }

  Future<int> _onlineGenre(Song s, ScanOptions o, {void Function(Object)? onError}) async {
    if (!_wantsMb(s, o)) return ScanOps.of(o);
    String? genre;
    int? year;
    var mbChecked = s.mbChecked;
    var yearChecked = s.yearChecked;
    var mbDone = false;
    final key = _mbKey(s, o);
    try {
      final needGenre = _wantsGenre(s, o);
      if (_wantsYear(s, o)) {
        final info = await _albumInfo(s, key, o);
        genre = needGenre ? await _albumGenre(s, _genreKey(s), o, fallback: info) : null;
        year = info?.year;
        yearChecked = true;
      } else {
        genre = await _albumGenre(s, key, o);
      }
      mbChecked = true;
      mbDone = true;
      if (genre != null && (s.album ?? '').trim().isNotEmpty) {
        await db.setAlbumGenre(s.artist!, s.album!, genre, source: 'api', apply: false);
      }
    } catch (e) {
      if (_wantsGenre(s, o)) mbChecked = false;
      if (_wantsYear(s, o)) yearChecked = false;
      onError?.call(e);
      if (onError == null) rethrow;
    }
    _onOpDone?.call();
    await db.updateOnline(s.path, genre: genre, year: year, mbChecked: mbChecked, yearChecked: yearChecked);
    var ok = ScanOps.of(o);
    if (!mbDone) ok &= ~(ScanOps.genre | ScanOps.year);
    return ok;
  }

  /// The lookup [s] shares with the rest of its album (or, without an album,
  /// with songs of the same title): one request answers all of them.
  String _mbKey(Song s, ScanOptions o) {
    return '${_wantsYear(s, o) ? 'i' : 'g'}|${_albumKey(s)}';
  }

  String _genreKey(Song s) => 'g|${_albumKey(s)}';

  String _albumKey(Song s) {
    final artist = s.artist!.trim().toLowerCase();
    final album = (s.album ?? '').trim().toLowerCase();
    return album.isNotEmpty ? '$artist|a|$album' : '$artist|t|${s.title!.trim().toLowerCase()}';
  }

  /// Shares both results and failures for the duration of this scan.
  /// Only keys requested by the progress tracker count towards its totals.
  Future<T> _lookup<T>(Map<String, Future<T>> cache, String key, Future<T> Function() fetch) {
    final f = cache.putIfAbsent(key, () async {
      try {
        return await fetch();
      } finally {
        if (_genreWanted.containsKey(key)) {
          _genreMeter.tick();
          _genreResolved.add(key);
        }
      }
    });
    return f;
  }

  Future<T> _persistedLookup<T>(
    String key,
    ScanOptions o,
    Future<T> Function() fetch,
    String? Function(T) encode,
    T Function(String?) decode,
  ) async {
    final saved = o.refreshOnline ? null : await db.onlineCache(key);
    if (saved != null) {
      if (saved.$3 == null) return decode(saved.$1);
      if (_now().millisecondsSinceEpoch - saved.$2 < retryCooldown.inMilliseconds) {
        throw HttpException('Lookup retry deferred for up to 30 days: ${saved.$3}');
      }
    }
    T value;
    try {
      value = await fetch();
    } catch (e) {
      await db.saveOnlineCache(key, null, _now().millisecondsSinceEpoch, error: '$e');
      rethrow;
    }
    await db.saveOnlineCache(key, encode(value), _now().millisecondsSinceEpoch);
    return value;
  }

  /// Year/genre workaround: songs on the same album share the first song's
  /// MusicBrainz answer instead of costing one request each.
  Future<MbInfo?> _albumInfo(Song s, String key, ScanOptions o) => _lookup(
    _mbAlbumInfo,
    key,
    () => _persistedLookup<MbInfo?>(
      key,
      o,
      () => mb.lookup(s.artist!, s.title!, refresh: o.refreshOnline),
      (info) => info == null ? null : jsonEncode({'genre': info.genre, 'year': info.year}),
      (text) {
        if (text == null) return null;
        final j = jsonDecode(text) as Map<String, dynamic>;
        return MbInfo(genre: j['genre'] as String?, year: j['year'] as int?);
      },
    ),
  );

  final Map<String, Future<MbInfo?>> _mbAlbumInfo = {};

  /// One lookup per album; its songs share the answer. Deezer is tried first
  /// (fast, free); MusicBrainz covers albums it doesn't know and songs without
  /// an album.
  Future<String?> _albumGenre(Song s, String key, ScanOptions o, {MbInfo? fallback}) => _lookup(
    _mbGenres,
    key,
    () => _persistedLookup<String?>(
      key,
      o,
      () async {
        if ((s.album ?? '').trim().isNotEmpty) {
          try {
            final g = await deezer.albumGenre(s.artist!, s.album!);
            if (g != null) return g;
          } catch (_) {}
        }
        return (fallback ?? await _albumInfo(s, 'i|${_albumKey(s)}', o))?.genre;
      },
      (genre) => genre,
      (genre) => genre,
    ),
  );
}

class _OnlineSong {
  _OnlineSong(this.song, this.pending, this.ok);
  final Song song;
  int pending;
  int ok;
}

class _OnlineQueue {
  final jobs = ListQueue<_OnlineSong>();
  final waiters = <Completer<void>>[];

  void add(_OnlineSong job) {
    jobs.add(job);
    poke();
  }

  void poke() {
    for (final waiter in waiters) {
      if (!waiter.isCompleted) waiter.complete();
    }
    waiters.clear();
  }
}

class _DirTrack {
  _DirTrack(this.root, this.fingerprint, this.pending, this.before, this.ok);
  final String root;
  final String fingerprint;

  /// Files not through yet.
  int pending;

  /// Work bits an earlier scan already finished for these same files.
  final int before;

  /// Work bits every file so far finished.
  int ok;
}
