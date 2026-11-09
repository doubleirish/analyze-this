import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_core/shared_core.dart';

import 'album_health_controller.dart';
import 'art_controller.dart';
import 'backup.dart';
import 'best_of.dart';
import 'class_history.dart';
import 'damage_scan.dart';
import 'db.dart';
import 'discography.dart';
import 'mix_controller.dart';
import 'mixtape_export.dart';
import 'phone_link.dart';
import 'phone_sync.dart';
import 'preview.dart';
import 'scanner.dart';
import 'share.dart';

class AppState extends PlaybackController {
  AppState(this.db, {super.random}) : scanner = Scanner(db), super(appId: 'analyze_this');

  final MusicDb db;
  final Scanner scanner;
  String? previewing;

  /// The mix being built on the Mix tab (songs, parts, program, name, filters,
  /// saved mixes). Screens watch it directly via its own provider.
  late final MixController mixer = MixController(db, random: random, songsQuery: () => query);

  /// Album health checks and the per-album badges.
  late final AlbumHealthController health = AlbumHealthController(
    db,
    libraryVersion: () => libraryVersion,
    isScanning: () => scanning,
    discography: _discography,
  );

  /// Artist photos and bulk cover-art downloads.
  late final ArtController artwork = ArtController(this, net: scanner.net);

  /// Damaged-audio scans and the damaged-songs list.
  late final DamageScanController damage = DamageScanController(
    db,
    findFfmpeg: () => MixtapeExport(this).detectFfmpeg(),
    onChanged: _damageChanged,
  );

  Future<void> _damageChanged() async {
    await mixer.refreshDamaged();
    await refresh();
  }

  List<String> folders = [];
  List<Song> results = [];
  List<String> genres = [];

  /// Decades present in the library (e.g. 1980), ascending; empty if none.
  List<int> decades = [];
  List<String> tagNames = [];
  SongQuery query = const SongQuery();
  int songCount = 0;

  /// Phones found/paired over Wi-Fi and the long-lived pull server.
  late final PhoneLink phones = PhoneLink(db, syncFactory: phoneSync);

  /// Set by main once the support folder is known.
  late BackupService backups;

  bool scanning = false;
  ScanProgress? progress;
  List<String> scanErrors = [];
  ScanOptions options = const ScanOptions();

  Future<void> load() async {
    folders = await db.folders();
    browseBySongs = (await db.setting('browse_by_songs')) != '0';
    hideUpTo = int.tryParse(await db.setting('hide_up_to') ?? '') ?? 0;
    await mixer.loadPrograms();
    await mixer.loadMixFilters();
    await mixer.loadGeneratorBookends();
    await db.cleanGenreCodes();
    await db.mergeGenres();
    await db.applyGenreLists();
    await refresh();
    await mixer.loadSavedMixes();
    await damage.load();
    await mixer.restoreDraft();
    await phones.load();
    await loadSmartLists();
    try {
      await importSharedPlays(db);
    } catch (_) {}
    await checkClassSuggestions();
    notifyListeners();
    scanOnStartup = (await db.setting('scan_on_startup')) != '0';
    recentWeeks = await db.recentWeeks();
    if (shouldScanOnStartup(folders, scanOnStartup)) unawaited(_startupScan());
  }

  // ---- class history ----

  /// Classes the play history says were probably taught but aren't logged.
  List<ClassSuggestion> classSuggestions = const [];

  /// Bumped whenever a class is logged or deleted, so views reload.
  int classHistoryVersion = 0;

  /// Re-runs the taught-class detector (after loading and after plays are
  /// imported from beats-me or the phone).
  Future<void> checkClassSuggestions() async {
    try {
      classSuggestions = await findClassSuggestions(db);
    } catch (_) {
      classSuggestions = const [];
    }
    notifyListeners();
  }

  /// A [PhoneSync] that re-checks class suggestions after it imports plays.
  PhoneSync phoneSync() => PhoneSync(db, onImported: (_) => unawaited(checkClassSuggestions()));

  Future<int> logClass({
    int? mixId,
    required String mixName,
    required List<String> paths,
    required DateTime taughtAt,
    String source = 'manual',
  }) async {
    final id = await db.logClass(mixId: mixId, mixName: mixName, paths: paths, taughtAt: taughtAt, source: source);
    classHistoryVersion++;
    await checkClassSuggestions();
    return id;
  }

  Future<void> deleteClassSession(int id) async {
    await db.deleteClassSession(id);
    classHistoryVersion++;
    await checkClassSuggestions();
  }

  Future<void> acceptClassSuggestion(ClassSuggestion s) =>
      logClass(mixId: s.mixId, mixName: s.mixName, paths: s.paths, taughtAt: s.start, source: 'auto');

  Future<void> dismissClassSuggestion(ClassSuggestion s) async {
    await db.dismissClassSuggestion(s.key);
    classSuggestions = [
      for (final x in classSuggestions)
        if (x.key != s.key) x,
    ];
    notifyListeners();
  }

  /// Songs taught within this many weeks count as recently taught (setting
  /// `recent_weeks`): the Songs tab can hide them and fills avoid them.
  int recentWeeks = defaultRecentWeeks;

  Future<void> setRecentWeeks(int weeks) async {
    recentWeeks = weeks;
    await db.setRecentWeeks(weeks);
    notifyListeners();
  }

  /// Folders tab: look for new/changed/removed files when the app starts.
  bool scanOnStartup = true;

  static bool shouldScanOnStartup(List<String> folders, bool enabled) => enabled && folders.isNotEmpty;

  Future<void> setScanOnStartup(bool on) async {
    scanOnStartup = on;
    await db.setSetting('scan_on_startup', on ? '1' : '0');
    notifyListeners();
  }

  Future<void> _startupScan() async {
    try {
      await quickScan();
    } catch (e) {
      scanErrors = [...scanErrors, 'Startup scan: $e'];
      notifyListeners();
    }
  }

  /// Artists/Albums tabs: most songs first (else by name), and hide entries
  /// with [hideUpTo] songs or fewer (0 = show all).
  bool browseBySongs = true;
  int hideUpTo = 0;

  Future<void> setBrowse({bool? bySongs, int? hide}) async {
    if (bySongs != null) {
      browseBySongs = bySongs;
      await db.setSetting('browse_by_songs', bySongs ? '1' : '0');
    }
    if (hide != null) {
      hideUpTo = hide;
      await db.setSetting('hide_up_to', '$hide');
    }
    libraryVersion++;
    notifyListeners();
  }

  Future<void>? _refreshing;
  bool _refreshAgain = false;

  /// Reloads the library views. Calls made while a reload runs are folded
  /// into one follow-up reload (and wait for it), so scan batches can't pile
  /// up heavy queries on the single database connection and starve writes.
  Future<void> refresh() {
    final running = _refreshing;
    if (running != null) {
      _refreshAgain = true;
      return running;
    }
    return _refreshing = _refreshLoop();
  }

  Future<void> _refreshLoop() async {
    try {
      do {
        _refreshAgain = false;
        results = await db.search(query);
        genres = await db.genres();
        decades = await db.decades();
        tagNames = await db.allTags();
        songCount = await db.songCount();
        libraryVersion++;
        notifyListeners();
      } while (_refreshAgain);
    } finally {
      _refreshing = null;
    }
  }

  /// Bumped whenever the library or its song data changes, so detail screens reload.
  int libraryVersion = 0;

  Future<void> search(SongQuery q) async {
    query = q;
    await refresh();
  }

  /// A search another screen wants shown on the Songs tab (see [showInSongs]).
  SongQuery? _songsRequest;

  /// Bumped by [showInSongs] so the home screen switches to the Songs tab.
  int songsRequestSeq = 0;

  /// Opens the Songs tab with its filters set to [q].
  void showInSongs(SongQuery q) {
    _songsRequest = q;
    songsRequestSeq++;
    notifyListeners();
  }

  /// The pending [showInSongs] search, once (the Songs tab applies it).
  SongQuery? takeSongsRequest() {
    final q = _songsRequest;
    _songsRequest = null;
    return q;
  }

  // ---- folders / scanning ----

  Future<void> addFolder(String p) async {
    await db.addFolder(p);
    folders = await db.folders();
    notifyListeners();
    unawaited(quickScan());
  }

  /// Tags-only pass so artists and albums can be found before the slow scan.
  Future<void> quickScan() async {
    if (scanning) return;
    scanning = true;
    scanErrors = [];
    notifyListeners();
    try {
      scanErrors = await scanner.quickScan(folders, onProgress: _onScanProgress, onBatch: () => unawaited(refresh()));
    } finally {
      scanning = false;
      progress = null;
      await db.applyGenreLists();
      await refresh();
    }
  }

  Future<void> removeFolder(String p) async {
    await db.removeFolder(p);
    folders = await db.folders();
    notifyListeners();
  }

  void setOptions(ScanOptions o) {
    options = o;
    notifyListeners();
  }

  Future<void> scan() => _runScan();

  /// Full analysis (BPM, lyrics, genre per the scan options) for just these
  /// songs, e.g. everything by one artist.
  Future<void> scanSongs(List<String> paths) => _runScan(only: paths);

  Future<void> _runScan({List<String>? only}) async {
    if (scanning) return;
    scanning = true;
    scanErrors = [];
    notifyListeners();
    try {
      scanErrors = await scanner.scanAll(folders, options: options, onlyFiles: only, onProgress: _onScanProgress);
    } finally {
      scanning = false;
      progress = null;
      // a forced full rescan is a one-off
      options = options.copyWith(forceFull: false, localOnly: false, refreshOnline: false);
      await db.applyGenreLists();
      await refresh();
      await mixer.refreshDamaged();
      await damage.load();
    }
  }

  void cancelScan() => scanner.cancelled = true;

  final _progressClock = Stopwatch();

  /// Scans report every file; rebuilding the app that often slows the scan
  /// itself, so the UI hears about it at most ten times a second.
  void _onScanProgress(ScanProgress p) {
    progress = p;
    if (_progressClock.isRunning && _progressClock.elapsedMilliseconds < 100) return;
    _progressClock
      ..reset()
      ..start();
    notifyListeners();
  }

  /// Progress text while the "Best of" albums are being built.
  String? bestOfProgress;
  bool _bestOfCancel = false;
  DeezerPopularity? popularity;

  void cancelBestOf() => _bestOfCancel = true;

  /// Builds a synthetic best-of album for every artist with more than one album,
  /// biggest catalogs first, ranked by Deezer popularity. Returns how many were built.
  Future<int> buildBestOfs() async {
    if (bestOfProgress != null) return 0;
    _bestOfCancel = false;
    final pop = popularity ??= DeezerPopularity();
    var built = 0, i = 0;
    try {
      final top = [
        for (final a in await db.artists())
          if (a.albums > 1) a,
      ];
      for (final a in top) {
        if (_bestOfCancel) break;
        bestOfProgress = 'Best of ${++i}/${top.length}: ${a.name}';
        notifyListeners();
        List<RankedTrack>? ranked;
        try {
          ranked = await pop.topTracks(a.name);
        } catch (_) {
          continue; // offline or rate limited: leave any existing best-of, retry later
        }
        final songs = await db.search(SongQuery(artist: a.name, exactNames: true, limit: 100000, sort: SongSort.title));
        final pick = pickBestOf(songs, ranked ?? const []);
        if (pick.songs.isEmpty) continue;
        await db.saveBestOf(a.name, [for (final s in pick.songs) s.path]);
        built++;
      }
    } finally {
      bestOfProgress = null;
      notifyListeners();
    }
    return built;
  }

  // ---- genre lists ----

  Future<void> setArtistGenre(String artist, String genre) async {
    await db.setArtistGenre(artist, genre);
    await refresh();
  }

  Future<void> setAlbumGenre(String artist, String album, String genre) async {
    await db.setAlbumGenre(artist, album, genre);
    await refresh();
  }

  Future<int> importGenreFile(String path) async {
    final n = await db.importGenreFile(await File(path).readAsString());
    await refresh();
    return n;
  }

  // ---- album art (artist photos and bulk downloads: see [artwork]) ----

  @override
  bool get supportsArtDownload => true;

  /// Downloads cover art for the album that [samplePath] belongs to.
  @override
  Future<bool> downloadAlbumArt(String samplePath) async {
    if (samplePath.isEmpty || !artBusy.add('s:$samplePath')) return false;
    notifyListeners();
    try {
      final ok = await enricher.fetchArtOnly(samplePath);
      await ensureMedia(samplePath, reload: true);
      libraryVersion++;
      return ok;
    } catch (_) {
      return false;
    } finally {
      artBusy.remove('s:$samplePath');
      notifyListeners();
    }
  }

  // ---- missing albums ----

  Discography? _disco;

  Future<Discography> _discography() async {
    if (_disco != null) return _disco!;
    final dir = await getApplicationSupportDirectory();
    return _disco = Discography(Directory('${dir.path}${Platform.pathSeparator}discography'), net: scanner.net);
  }

  /// Albums/EPs by [artist] that aren't in the library, oldest first.
  /// Null when Deezer doesn't know the artist; throws if unreachable.
  Future<List<AlbumRelease>?> missingAlbumsFor(String artist, Iterable<String> ownedAlbums) async {
    final r = await (await _discography()).releases(artist);
    return r == null ? null : missingAlbums(r, ownedAlbums);
  }

  Future<File?> missingAlbumCover(String artist, AlbumRelease r) async => (await _discography()).cover(artist, r);

  // ---- favourites, selection, smart lists, discovery ----

  List<SmartList> smartLists = [];
  Map<int, int> smartCounts = {};
  final Set<String> selected = {};
  bool selecting = false;

  Future<void> toggleFav(Song s) => setRatingFor(s.path, fav: !s.fav);

  void setSelecting(bool on) {
    selecting = on;
    if (!on) selected.clear();
    notifyListeners();
  }

  void toggleSelected(Song s) {
    selected.remove(s.path) || selected.add(s.path);
    notifyListeners();
  }

  void selectAllShown() {
    selected.addAll(results.map((r) => r.path));
    notifyListeners();
  }

  /// Sets artist/album/genre/year on the selected songs (kept across rescans).
  Future<void> editSelected({String? artist, String? album, String? genre, int? year}) async {
    await db.setOverrides(selected, artist: artist, album: album, genre: genre, year: year);
    selected.clear();
    selecting = false;
    await refresh();
  }

  Future<void> loadSmartLists() async {
    smartLists = await db.smartLists();
    smartCounts = {for (final l in smartLists) l.id: await db.count(l.query)};
    notifyListeners();
  }

  Future<void> saveSmartList(String name) async {
    if (name.trim().isEmpty) return;
    await db.saveSmartList(name, query);
    await loadSmartLists();
  }

  Future<void> deleteSmartList(SmartList l) async {
    await db.deleteSmartList(l.id);
    await loadSmartLists();
  }

  /// A random song matching the current filters.
  Future<Song?> surprise() async {
    final r = await db.search(query.copyWith(sort: SongSort.random, limit: 1));
    return r.isEmpty ? null : r.first;
  }

  Future<List<Song>> similarTo(Song s) async {
    final inMix = {for (final m in mixer.mix) m.path};
    return [
      for (final c in await db.similar(s, limit: 60))
        if (!inMix.contains(c.path)) c,
    ];
  }

  // ---- tags ----

  Future<void> addTag(Song s, String tag) async {
    if (tag.trim().isEmpty) return;
    await db.addTag(s.path, tag);
    await refresh();
    if (tag.trim().toLowerCase() == corruptTag) await _afterDamageTag();
  }

  Future<void> removeTag(Song s, String tag) async {
    await db.removeTag(s.path, tag);
    await refresh();
    if (tag == corruptTag) await _afterDamageTag();
  }

  Future<void> _afterDamageTag() async {
    await mixer.refreshDamaged();
    await damage.load();
  }

  // ---- ratings (the mix itself lives in [mixer]) ----

  Future<void> setRating(Song s, int stars) => setRatingFor(s.path, rating: s.rating == stars ? 0 : stars);

  final Map<String, ({int rating, bool fav})?> _rateCache = {};
  int _rateCacheVersion = -1;

  @override
  bool get supportsRating => true;

  @override
  int ratingOf(String path) => _rateOf(path)?.rating ?? 0;

  @override
  bool favOf(String path) => _rateOf(path)?.fav ?? false;

  /// From the loaded mix/results when the song is there, else a per-[libraryVersion]
  /// cache filled from the database in the background.
  ({int rating, bool fav})? _rateOf(String path) {
    for (final list in [mixer.mix, results]) {
      for (final s in list) {
        if (s.path == path) return (rating: s.rating, fav: s.fav);
      }
    }
    if (_rateCacheVersion != libraryVersion) {
      _rateCache.clear();
      _rateCacheVersion = libraryVersion;
    }
    if (_rateCache.containsKey(path)) return _rateCache[path];
    _rateCache[path] = null;
    final v = libraryVersion;
    unawaited(
      db.song(path).then((s) {
        if (s == null || v != libraryVersion) return;
        _rateCache[path] = (rating: s.rating, fav: s.fav);
        if (s.rating > 0 || s.fav) notifyListeners();
      }, onError: (_) {}),
    );
    return null;
  }

  @override
  Future<void> setRatingFor(String path, {int? rating, bool? fav}) async {
    if (rating != null) {
      final r = rating.clamp(0, 5);
      await db.setRating(path, r);
      mixer.updateSong(path, (m) => m.copyWith(rating: r));
    }
    if (fav != null) {
      await db.setFav(path, fav);
      mixer.updateSong(path, (m) => m.copyWith(fav: fav));
    }
    await refresh();
  }

  /// Audition: plays 30 seconds from the song's fastest section on the main player.
  Future<void> togglePreview(Song s) async {
    _previewTimer?.cancel();
    if (previewing == s.path) {
      previewing = null;
      await player.pause();
      notifyListeners();
      return;
    }
    previewing = s.path;
    notifyListeners();
    try {
      var start = PreviewService.startFor(s, await db.segmentsOf(s.path));
      final dur = s.duration;
      if (dur != null && start.inMilliseconds / 1000 > dur - 10) start = Duration.zero;
      queue = [s.path];
      index = 0;
      await loadCurrent(preview: true);
      await player.seek(start);
      _previewTimer = Timer(PreviewService.length, () {
        previewing = null;
        unawaited(player.pause());
        notifyListeners();
      });
    } catch (_) {
      previewing = null;
    }
    notifyListeners();
  }

  Timer? _previewTimer;

  /// Re-reads [paths] after their song settings changed, so the mix and the
  /// player see the new trim/explicit/loudness.
  Future<void> _reloadSongs(Iterable<String> paths) async {
    for (final p in paths) {
      clearTrackCache(p);
      final fresh = await db.song(p);
      if (fresh != null) mixer.updateSong(p, (_) => fresh);
    }
    await refresh();
  }

  /// Sets where [path] starts and stops playing (nulls = whole song).
  Future<void> setTrim(String path, double? start, double? end) async {
    await db.setTrim(path, start, end);
    await _reloadSongs([path]);
  }

  /// Marks [paths] explicit (true) or clean (false); null = use the lyrics check.
  Future<void> setExplicitMark(Iterable<String> paths, bool? explicit) async {
    final l = paths.toList();
    await db.setExplicitMark(l, explicit);
    await _reloadSongs(l);
  }

  /// Plays [path] as trimmed: from its start, or the last [tail] seconds
  /// before its end (to hear the fade-out).
  Future<void> previewTrimmed(String path, {bool atEnd = false, double tail = 8}) async {
    _previewTimer?.cancel();
    previewing = path;
    queue = [path];
    index = 0;
    await loadCurrent(preview: true);
    if (atEnd) {
      for (var i = 0; i < 40 && player.duration == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      final d = player.duration;
      if (d != null) await player.seek(d - Duration(milliseconds: (tail * 1000).round()));
    }
    _previewTimer = Timer(Duration(seconds: atEnd ? tail.ceil() + 1 : 12), () {
      previewing = null;
      unawaited(player.pause());
      notifyListeners();
    });
    notifyListeners();
  }

  Future<List<DupGroup>> duplicates() => db.duplicateSuggestions();

  /// Removes the song from the library and deletes its file and sidecars from disk.
  Future<void> deleteSongFile(Song s) async {
    for (final suffix in ['', '.bpm', '.lrc', '.wave', '.enrich']) {
      try {
        final f = File('${s.path}$suffix');
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    await removeFromLibrary(s);
  }

  Future<void> removeFromLibrary(Song s) async {
    await db.deleteSongs([s.path]);
    mixer.removeSong(s.path);
    await refresh();
  }

  Future<List<String>> explicitWords() => db.explicitWords();

  Future<void> saveExplicitWords(List<String> w) async {
    await db.saveExplicitWords(w);
    await refresh();
  }

  @override
  List<String> get libraryPaths => [for (final s in results) s.path];

  @override
  List<String> get mixPaths => mixer.paths;

  /// Timed sub-activities for a mix song, built from its program part, so the
  /// PC plays a mix with the same panel the phone shows after a transfer.
  @override
  Future<StepPlan?> planOf(String path) async {
    final i = mixer.mix.indexWhere((m) => m.path == path);
    if (i < 0) return super.planOf(path);
    return mixer.planAt(i, fallbackSeconds: tempos[path]?.durationSec);
  }

  @override
  Future<String?> noteOf(String path) async => mixer.songNotes[path] ?? await super.noteOf(path);

  /// Library songs play their trim and loudness, as they will on the phone.
  @override
  Future<({double? start, double? end, double? loudness})> trackInfo(String path) async {
    final s = await db.song(path);
    if (s == null) return super.trackInfo(path);
    return (start: s.trimStart, end: s.trimEnd, loudness: s.loudness);
  }

  @override
  void onPlayFinished(String path, double listened, bool completed) =>
      unawaited(db.recordPlay(path, listened, completed));

  @override
  void onPlayStarting() {
    _previewTimer?.cancel();
    previewing = null;
  }

  /// Plays [songs] in the given order (or shuffled), replacing the queue.
  Future<void> playSongList(List<Song> songs, {bool shuffle = false}) =>
      playSongs([for (final s in songs) s.path], shuffle: shuffle);

  @override
  void dispose() {
    _previewTimer?.cancel();
    unawaited(phones.stopPull());
    mixer.dispose();
    health.dispose();
    artwork.dispose();
    super.dispose();
  }
}
