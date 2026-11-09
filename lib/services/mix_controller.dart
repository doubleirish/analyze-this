import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_core/shared_core.dart';

import 'activities.dart';
import 'db.dart';
import 'm3u_import.dart';
import 'fill_planner.dart';
import 'planner.dart';
import 'program_generator.dart' show Bookends, themedBuiltins;
import 'readiness.dart';

part 'mix_series.dart';

/// The mix being built on the Mix tab: its songs, the program part of each
/// song, the program, the name and phone identity, plus the Mix page filters,
/// the saved programs and the saved mixes.
///
/// Every change to the songs, their parts, the program, the name or the
/// mixtape identity goes through [_edit].
class MixController extends ChangeNotifier {
  MixController(this.db, {Random? random, SongQuery Function()? songsQuery})
      : random = random ?? Random(),
        _songsQuery = songsQuery ?? (() => const SongQuery()) {
    _markClean();
  }

  final MusicDb db;
  final Random random;

  /// The Songs tab's current search (see [mixBase] and [useSongsFilters]).
  final SongQuery Function() _songsQuery;

  /// The songs of the mix, in play order.
  List<Song> mix = [];

  /// Program part index of each mix item (null = not from a program part).
  List<int?> mixPart = [];
  Program program = classicProgram;
  List<Program> userPrograms = [];
  List<Program> get programs => [...builtinPrograms, ...themedBuiltins, ...userPrograms];

  String mixName = 'New mix';

  /// While true the name follows the Mix filters (see [_refreshMixName]).
  bool mixNameAuto = true;

  /// Stable mixtape id for the current mix: it follows the mix through
  /// renames so the phone updates its copy instead of adding a new one.
  String mixKey = newMixtapeId();
  int? mixDbId;

  List<MixInfo> savedMixes = [];

  /// Class length in minutes ("Class mins"), for the time left.
  double targetMinutes = 45;

  /// Paths of the songs locked in place: auto-fill and "Re-fill this part"
  /// keep them (in their part and order). Keyed by path, so reorders and
  /// removals need no bookkeeping; stale paths are pruned after every edit.
  Set<String> lockedPaths = {};

  /// Coaching notes for songs in the mix, by path (shown on the phone).
  Map<String, String> songNotes = {};

  /// Sets (or with an empty [note] clears) the note for [path]; one undo step.
  void setSongNote(String path, String note) {
    final n = note.trim();
    if ((songNotes[path] ?? '') == n) return;
    _edit(() => songNotes = {...songNotes}..removeWhere((k, _) => k == path)..addAll({if (n.isNotEmpty) path: n}));
  }

  /// Applies a change to the mix and notifies listeners. Every change to the
  /// songs, their parts, the program, the name or the mixtape identity
  /// (key / saved id) is made inside [apply], so the state just before the
  /// call and just after it are the "before" and "after" of one edit.
  ///
  /// The "before" goes on the undo stack (unless [undoable] is false), the
  /// redo stack is cleared and the draft is saved shortly after. Consecutive
  /// edits with the same non-null [coalesce] key (e.g. typing the name) share
  /// one undo entry.
  void _edit(VoidCallback apply, {bool undoable = true, String? coalesce}) {
    final before = undoable ? snapshot() : null;
    apply();
    _syncParts();
    lockedPaths.retainAll(paths);
    _pruneNotes();
    if (before != null) {
      if (coalesce == null || coalesce != _lastCoalesce || _undo.isEmpty) {
        _undo.add(before);
        if (_undo.length > maxUndo) _undo.removeAt(0);
      }
      _redo.clear();
    }
    _lastCoalesce = coalesce;
    notifyListeners();
    _scheduleDraft();
  }

  // ---- undo / redo / dirty ----

  static const maxUndo = 50;
  final List<MixSnapshot> _undo = [];
  final List<MixSnapshot> _redo = [];
  String? _lastCoalesce;

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  /// The current mix (deep copies of the mutable lists).
  MixSnapshot snapshot() {
    _syncParts();
    return MixSnapshot(
      songs: List.of(mix),
      parts: List.of(mixPart),
      locked: {...lockedPaths},
      notes: {...songNotes},
      program: program,
      name: mixName,
      nameAuto: mixNameAuto,
      mixKey: mixKey,
      mixDbId: mixDbId,
      targetMinutes: targetMinutes,
    );
  }

  void _restore(MixSnapshot s) {
    // Keep the latest library data (ratings, favourites) for songs still in the mix.
    final current = {for (final m in mix) m.path: m};
    mix = [for (final m in s.songs) current[m.path] ?? m];
    mixPart = List.of(s.parts);
    lockedPaths = {...s.locked};
    songNotes = {...s.notes};
    program = s.program;
    mixName = s.name;
    mixNameAuto = s.nameAuto;
    mixKey = s.mixKey;
    mixDbId = s.mixDbId;
    targetMinutes = s.targetMinutes;
    _syncParts();
    lockedPaths.retainAll(paths);
    _lastCoalesce = null;
    notifyListeners();
    _scheduleDraft();
  }

  void _pruneNotes() {
    if (songNotes.isEmpty) return;
    final have = paths.toSet();
    songNotes.removeWhere((k, _) => !have.contains(k));
  }

  void undo() {
    if (_undo.isEmpty) return;
    _redo.add(snapshot());
    _restore(_undo.removeLast());
  }

  void redo() {
    if (_redo.isEmpty) return;
    _undo.add(snapshot());
    _restore(_redo.removeLast());
  }

  /// The saved content ([MixSnapshot.content]) as of the last save, load or
  /// startup; [dirty] compares against it.
  String _baseline = '';

  /// True when the songs, parts, locks, program or name differ from the last
  /// save / load (or from the empty mix at startup).
  bool get dirty => snapshot().content != _baseline;

  void _markClean() => _baseline = snapshot().content;

  // ---- draft (the working mix survives a restart) ----

  static const draftKey = 'mix_draft';
  static const draftDelay = Duration(seconds: 1);
  Timer? _draftTimer;

  void _scheduleDraft() {
    _draftTimer?.cancel();
    _draftTimer = Timer(draftDelay, () => unawaited(saveDraft()));
  }

  /// Writes the working mix to `settings[mix_draft]` now (normally done ~1 s
  /// after each change).
  Future<void> saveDraft() async {
    _draftTimer?.cancel();
    _draftTimer = null;
    final s = snapshot();
    try {
      await db.setSetting(
          draftKey,
          jsonEncode({
            'paths': [for (final m in s.songs) m.path],
            'parts': s.parts,
            'locked': [for (final m in s.songs) if (s.locked.contains(m.path)) m.path],
            'notes': s.notes,
            'program': s.program.toJson(),
            'name': s.name,
            'nameAuto': s.nameAuto,
            'mixKey': s.mixKey,
            'mixDbId': s.mixDbId,
            'targetMinutes': s.targetMinutes,
            'baseline': _baseline,
          }));
    } catch (_) {
      // The database may already be closed (app shutting down).
    }
  }

  /// Restores the draft saved by [saveDraft], dropping songs no longer in
  /// the library. Not an undoable edit. Returns whether a draft was found.
  Future<bool> restoreDraft() async {
    final raw = await db.setting(draftKey);
    if (raw == null) {
      _markClean();
      return false;
    }
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final paths = [for (final p in j['paths'] as List? ?? const []) p as String];
      final parts = j['parts'] as List? ?? const [];
      final songs = <Song>[];
      final songParts = <int?>[];
      for (var i = 0; i < paths.length; i++) {
        final s = await db.song(paths[i]);
        if (s == null) continue;
        songs.add(s);
        songParts.add(i < parts.length ? (parts[i] as num?)?.toInt() : null);
      }
      mix = songs;
      mixPart = songParts;
      lockedPaths = {for (final p in j['locked'] as List? ?? const []) p as String}
        ..retainAll(this.paths);
      songNotes = {
        for (final e in ((j['notes'] as Map?) ?? const {}).entries)
          if (this.paths.contains(e.key)) e.key as String: e.value as String
      };
      if (j['program'] is Map) {
        program = Program.fromJson((j['program'] as Map).cast<String, dynamic>());
      }
      mixName = j['name'] as String? ?? mixName;
      mixNameAuto = j['nameAuto'] as bool? ?? mixNameAuto;
      mixKey = j['mixKey'] as String? ?? mixKey;
      mixDbId = (j['mixDbId'] as num?)?.toInt();
      targetMinutes = (j['targetMinutes'] as num?)?.toDouble() ?? targetMinutes;
      _baseline = j['baseline'] as String? ?? snapshot().content;
      _undo.clear();
      _redo.clear();
      _lastCoalesce = null;
      notifyListeners();
      return true;
    } catch (_) {
      _markClean();
      return false;
    }
  }

  @override
  void dispose() {
    _draftTimer?.cancel();
    super.dispose();
  }

  // ---- locks ----

  bool isLocked(int i) => i >= 0 && i < mix.length && lockedPaths.contains(mix[i].path);

  void toggleLock(int i) => _edit(() {
        final p = mix[i].path;
        lockedPaths.remove(p) || lockedPaths.add(p);
      });

  void _syncParts() {
    while (mixPart.length < mix.length) {
      mixPart.add(null);
    }
    if (mixPart.length > mix.length) mixPart = mixPart.sublist(0, mix.length);
  }

  // ---- songs ----

  List<String> get paths => [for (final s in mix) s.path];

  double get mixSeconds => mix.fold(0.0, (a, s) => a + (s.playSeconds ?? 0));

  double get remainingSeconds => targetMinutes * 60 - mixSeconds;

  List<int> get jumps => bigJumps(mix);

  /// The program part of mix item [i], or null if it has none.
  ProgramPart? partAt(int i) {
    final pi = i < mixPart.length ? mixPart[i] : null;
    return pi != null && pi < program.parts.length ? program.parts[pi] : null;
  }

  /// Timed sub-activities for mix item [i] from its program part; null if
  /// it has no part. Consecutive songs of the same part share one pattern
  /// (see [buildPartPlans]). [fallbackSeconds] is used when a length is unknown.
  StepPlan? planAt(int i, {double? fallbackSeconds}) {
    final part = partAt(i);
    if (part == null) return null;
    _syncParts();
    var a = i, b = i + 1;
    while (a > 0 && mixPart[a - 1] == mixPart[i]) {
      a--;
    }
    while (b < mix.length && mixPart[b] == mixPart[i]) {
      b++;
    }
    return buildPartPlans(
        part, [for (var k = a; k < b; k++) mix[k].playSeconds ?? fallbackSeconds])[i - a];
  }

  /// Seconds of songs currently assigned to program part [part].
  double partSeconds(int part) {
    var t = 0.0;
    for (var i = 0; i < mix.length && i < mixPart.length; i++) {
      if (mixPart[i] == part) t += mix[i].playSeconds ?? 0;
    }
    return t;
  }

  /// Why part [part] may need re-filling, or null when it looks fine: its
  /// songs run more than [partToleranceSeconds] off its minutes, or their
  /// lengths are uneven (longest over 1.5× the shortest).
  String? partWarning(int part) {
    if (part < 0 || part >= program.parts.length || !program.parts[part].music) return null;
    final lens = [
      for (var i = 0; i < mix.length && i < mixPart.length; i++)
        if (mixPart[i] == part) songSeconds(mix[i])
    ];
    if (lens.isEmpty) return 'No songs';
    final off = lens.fold(0.0, (a, b) => a + b) - program.parts[part].minutes * 60;
    if (off.abs() > partToleranceSeconds) {
      return '${off > 0 ? 'Over' : 'Under'} by ${(off.abs() / 60).toStringAsFixed(1)} min';
    }
    if (lens.length > 1 && lens.reduce(max) / lens.reduce(min) > balanceStages[1].lengthRatio) {
      return 'Uneven song lengths';
    }
    return null;
  }

  /// Adds [s] (moving it if already in the mix). Damaged songs are refused:
  /// returns false and changes nothing.
  bool addToMix(Song s, {bool atEnd = true}) {
    if (s.damaged) return false;
    _edit(() {
        _syncParts();
        final old = mix.indexWhere((m) => m.path == s.path);
        if (old >= 0) {
          mix.removeAt(old);
          mixPart.removeAt(old);
        }
        if (atEnd) {
          mix.add(s);
          mixPart.add(null);
        } else {
          mix.insert(0, s);
          mixPart.insert(0, null);
        }
      });
    return true;
  }

  /// Adds [songs] at the end of the mix as one undoable edit, skipping damaged
  /// ones. Returns how many were skipped.
  int addAllToMix(Iterable<Song> songs) {
    final ok = [for (final s in songs) if (!s.damaged) s];
    final skipped = songs.length - ok.length;
    if (ok.isEmpty) return skipped;
    final add = {for (final s in ok) s.path};
    _edit(() {
      _syncParts();
      for (var i = mix.length - 1; i >= 0; i--) {
        if (add.contains(mix[i].path)) {
          mix.removeAt(i);
          mixPart.removeAt(i);
        }
      }
      mix.addAll(ok);
      mixPart.addAll(List<int?>.filled(ok.length, null));
    });
    return skipped;
  }

  void removeFromMix(int i) => _edit(() {
        _syncParts();
        mix.removeAt(i);
        mixPart.removeAt(i);
      });

  void reorderMix(int oldI, int newI) => _edit(() {
        _syncParts();
        if (newI > oldI) newI--;
        mix.insert(newI, mix.removeAt(oldI));
        mixPart.insert(newI, mixPart.removeAt(oldI));
      });

  void moveToEnd(int i) => _edit(() {
        _syncParts();
        mix.add(mix.removeAt(i));
        mixPart.add(mixPart.removeAt(i));
      });

  void moveToStart(int i) => _edit(() {
        _syncParts();
        mix.insert(0, mix.removeAt(i));
        mixPart.insert(0, mixPart.removeAt(i));
      });

  /// Adds [song] at the end of [part] (after the last song of that or an
  /// earlier part). Damaged songs are refused (returns false).
  bool addToPart(Song song, int part) {
    if (song.damaged) return false;
    _edit(() {
        _syncParts();
        var at = 0;
        for (var i = 0; i < mix.length; i++) {
          final mp = mixPart[i];
          if (mp != null && mp <= part) at = i + 1;
        }
        mix.insert(at, song);
        mixPart.insert(at, part);
      });
    return true;
  }

  /// Drops [path] from the mix, e.g. after it was removed from the library.
  void removeSong(String path) {
    if (!mix.any((m) => m.path == path)) return;
    _edit(() {
      _syncParts();
      for (var i = mix.length - 1; i >= 0; i--) {
        if (mix[i].path == path) {
          mix.removeAt(i);
          mixPart.removeAt(i);
        }
      }
    });
  }

  /// Refreshes the mix's copy of a song whose library data changed (rating,
  /// favourite). Not an edit: the songs and their order stay the same.
  void updateSong(String path, Song Function(Song) update) {
    if (!mix.any((m) => m.path == path)) return;
    mix = [for (final m in mix) m.path == path ? update(m) : m];
    notifyListeners();
  }

  void setTargetMinutes(double m) {
    targetMinutes = m;
    notifyListeners();
  }

  // ---- programs ----

  Future<void> loadPrograms() async {
    final raw = await db.setting('programs');
    if (raw == null) return;
    try {
      userPrograms = [
        for (final j in jsonDecode(raw) as List) Program.fromJson(j as Map<String, dynamic>)
      ];
    } catch (_) {
      userPrograms = [];
    }
  }

  Future<void> _savePrograms() =>
      db.setSetting('programs', jsonEncode([for (final p in userPrograms) p.toJson()]));

  /// Saves [p] as a user program (replacing one with the same name).
  Future<void> saveProgram(Program p) async {
    final name = p.name.trim().isEmpty ? 'My program' : p.name.trim();
    final saved = Program(name, p.parts);
    userPrograms = [for (final u in userPrograms) if (u.name != name) u, saved];
    _edit(() => program = saved);
    await _savePrograms();
  }

  Future<void> deleteProgram(Program p) async {
    userPrograms = [for (final u in userPrograms) if (u.name != p.name) u];
    if (program.name == p.name) {
      _edit(() => program = classicProgram);
    } else {
      notifyListeners();
    }
    await _savePrograms();
  }

  void selectProgram(Program p) => _edit(() {
        program = p;
        targetMinutes = p.minutes;
      });

  /// Which fixed parts the Generate… wizard starts with; remembered between uses.
  Bookends generatorBookends = const Bookends();

  Future<void> loadGeneratorBookends() async {
    try {
      final raw = await db.setting('generator_bookends');
      if (raw == null) return;
      generatorBookends =
          Bookends.fromJson((jsonDecode(raw) as Map).cast<String, dynamic>());
    } catch (_) {
      generatorBookends = const Bookends();
    }
  }

  Future<void> setGeneratorBookends(Bookends b) async {
    if (b == generatorBookends) return;
    generatorBookends = b;
    await db.setSetting('generator_bookends', jsonEncode(b.toJson()));
  }

  /// Search for one part: its RPM range matched against song BPM (also half and
  /// double time), limited by the Mix page filter for the part's role.
  SongQuery queryForPart(ProgramPart p, {Set<String> exclude = const {}, int limit = 200}) =>
      partQuery(p, mixBase(p.kind), exclude: exclude, limit: limit);

  // ---- Mix page filters ----

  /// Genre / artist / year limits for every song picked on the Mix page.
  MixFilter mixFilter = const MixFilter();

  /// Extra limits per part role (e.g. calm warm-up music), laid over [mixFilter].
  Map<PartRole, MixFilter> roleFilters = {};

  MixFilter filterFor(PartRole? role) =>
      role == null ? mixFilter : mixFilter.overlay(roleFilters[role] ?? const MixFilter());

  /// Base query for the Mix page: only the explicit/rating choices carry over
  /// from the Songs tab, plus the Mix filter for [role]. Damaged songs are
  /// never picked.
  SongQuery mixBase([PartRole? role]) {
    final q = _songsQuery();
    return filterFor(role).applyTo(SongQuery(
        hideExplicit: cleanClass || q.hideExplicit,
        minRating: q.minRating,
        hideCorrupt: true,
        hideInLastMixes: rotationMixes,
        exceptMix: mixDbId));
  }

  /// Rotation: songs used in this many most recently saved mixes (other than
  /// the one being edited) are never picked; 0 = off. Songs used or taught
  /// within `recent_weeks` are only avoided when there is a choice.
  int rotationMixes = 0;

  Future<void> setRotationMixes(int n) async {
    rotationMixes = max(0, n);
    notifyListeners();
    await db.setSetting('rotation_mixes', '$rotationMixes');
  }

  /// Clean class: fills, suggestions and replacements never pick explicit
  /// songs (whatever the Songs tab shows), and Send warns about any left.
  bool cleanClass = false;

  Future<void> setCleanClass(bool on) async {
    cleanClass = on;
    notifyListeners();
    await db.setSetting('clean_class', on ? '1' : '0');
  }

  /// Songs in the mix that are explicit (by the user's mark or the lyrics).
  List<Song> get explicitInMix => [for (final m in mix) if (m.isExplicit) m];

  Future<void> loadMixFilters() async {
    cleanClass = (await db.setting('clean_class')) == '1';
    rotationMixes = int.tryParse(await db.setting('rotation_mixes') ?? '') ?? 0;
    try {
      final raw = await db.setting('mix_filters');
      if (raw == null) return;
      final j = jsonDecode(raw) as Map<String, dynamic>;
      mixFilter = MixFilter.fromJson((j['all'] as Map?)?.cast<String, dynamic>() ?? {});
      roleFilters = {
        for (final r in PartRole.values)
          if (j['roles'] is Map && (j['roles'] as Map)[r.name] is Map)
            r: MixFilter.fromJson(((j['roles'] as Map)[r.name] as Map).cast<String, dynamic>())
      };
      _refreshMixName();
    } catch (_) {
      mixFilter = const MixFilter();
      roleFilters = {};
    }
  }

  Future<void> _saveMixFilters() => db.setSetting(
      'mix_filters',
      jsonEncode({
        'all': mixFilter.toJson(),
        'roles': {for (final e in roleFilters.entries) e.key.name: e.value.toJson()},
      }));

  /// Notifies after a filter change; an automatic mix name follows the filters.
  void _filtersChanged() {
    if (mixNameAuto) {
      // Not undoable: undo can't bring back the filter that named the mix.
      _edit(_refreshMixName, undoable: false);
    } else {
      notifyListeners();
    }
  }

  Future<void> setMixFilter(MixFilter f) async {
    mixFilter = f;
    _filtersChanged();
    await _saveMixFilters();
  }

  Future<void> setRoleFilter(PartRole role, MixFilter f) async {
    roleFilters = {...roleFilters};
    if (f.isEmpty) {
      roleFilters.remove(role);
    } else {
      roleFilters[role] = f;
    }
    _filtersChanged();
    await _saveMixFilters();
  }

  /// Copies the Songs tab's genre, artist and decade into the Mix filter.
  Future<void> useSongsFilters() {
    final query = _songsQuery();
    return setMixFilter(MixFilter(
        genre: query.genre.trim(),
        artist: query.artist.trim(),
        minYear: query.decade,
        maxYear: query.decade == null ? null : query.decade! + 9));
  }

  /// Explicit/rating limits that carry over from the Songs tab (or clean
  /// class) into every Mix search, for showing next to the Mix filter.
  ({bool clean, int minRating}) get carriedLimits {
    final q = _songsQuery();
    return (clean: cleanClass || q.hideExplicit, minRating: q.minRating);
  }

  /// For each tempo band used by [role]'s parts in the current program: how
  /// many songs could fill it, and how many each limit removes.
  Future<List<PartSupply>> supplyFor(PartRole role) async {
    final seen = <String>{};
    final out = <PartSupply>[];
    final carried = carriedLimits;
    for (final p in program.parts) {
      if (!p.music || p.kind != role) continue;
      if (!seen.add('${p.minRpm}|${p.maxRpm}|${p.maxStddev}')) continue;
      final base = SongQuery(hideCorrupt: true);
      final filtered = filterFor(role).applyTo(base);
      out.add(PartSupply(
        role: role,
        minRpm: p.minRpm,
        maxRpm: p.maxRpm,
        tempo: await db.count(partQuery(p, base)),
        filtered: await db.count(partQuery(p, filtered)),
        allowed: await db.count(partQuery(
            p, filterFor(role).applyTo(SongQuery(
                hideCorrupt: true, hideExplicit: carried.clean, minRating: carried.minRating)))),
        eligible: await db.count(queryForPart(p)),
      ));
    }
    return out;
  }

  /// While the user hasn't typed a name, the mix is named after the active filter,
  /// e.g. "Rock · Radiohead · from 1990 · Pyramid", and follows filter changes.
  void _refreshMixName() {
    if (!mixNameAuto) return;
    final parts = <String>[
      if (!mixFilter.isEmpty)
        mixFilter.summary
      else
        ...{for (final f in roleFilters.values) f.summary},
    ];
    if (parts.isEmpty) {
      mixName = 'New mix';
      return;
    }
    final base = program.name.trim();
    mixName = '${parts.join(' · ')}${base.isEmpty ? ' mix' : ' · $base'}';
  }

  // ---- auto-fill, swap and suggestions ----

  /// Paths taught, or put in another mix, in the last `recent_weeks` weeks
  /// (plus earlier mixes of a series being planned), loaded once per fill:
  /// fills, swaps and suggestions prefer other songs.
  Set<String> _recent = const {};
  Set<String> _seriesUsed = const {};

  Future<Set<String>> _loadRecent() async {
    try {
      final since = DateTime.now().subtract(Duration(days: 7 * await db.recentWeeks()));
      final own = {for (final m in mix) m.path};
      return {
        ...await db.recentlyTaughtPaths(),
        // This mix's own songs were marked when it was saved; don't count them.
        ...(await db.pathsMixedSince(since)).difference(own),
        ..._seriesUsed,
      };
    } catch (_) {
      return _seriesUsed;
    }
  }

  /// [cands] with recently taught songs last.
  Future<List<Song>> _rankRecent(Future<List<Song>> cands) async =>
      rankNotRecent(await cands, await _loadRecent());

  /// Songs for a role's usual tempo (see [sectionPresets]), best rated first.
  Future<List<Song>> suggestForRole(PartRole role, {int limit = 12}) async {
    final preset = presetNamed(role.preset);
    return _rankRecent(db.search(mixBase(role).copyWith(
        minBpm: preset.minBpm,
        maxBpm: preset.maxBpm,
        maxStddev: preset.maxStddev,
        minSeconds: preset.minSeconds,
        maxSeconds: preset.maxSeconds,
        exclude: {for (final m in mix) m.path},
        sort: SongSort.rating,
        limit: limit)));
  }

  /// How many songs the last [fillProgram] had to pick with looser tempo rules
  /// because nothing matched exactly (e.g. an artist with unusual tempos).
  int lastFillRelaxed = 0;

  /// Songs added by the last [fillProgram] / [refillPart].
  int lastFillAdded = 0;

  /// Big tempo jumps ([bigJumps]) in the mix after the last fill.
  int lastFillBigJumps = 0;

  /// Activities filled with uneven songs (see [PartPick.uneven]) by the last fill.
  int lastFillUneven = 0;

  /// e.g. "Filled 12 songs · 1 relaxed · 2 big jumps" for the last fill.
  String get lastFillReport =>
      fillReport(lastFillAdded, lastFillRelaxed, lastFillBigJumps, uneven: lastFillUneven);

  /// Songs for one activity of [p] lasting about [need] seconds (see
  /// [planPartSongs]): exact tempo matches first, then a wider RPM band,
  /// finally ignoring tempo when a Mix filter such as an artist is active.
  /// A looser candidate set is only used when the stricter one has no
  /// balanced choice. Returns the pick and whether its songs are loose matches.
  Future<(PartPick?, bool)> _pickForPart(ProgramPart p, Set<String> used, double need,
      {Song? previous, List<Song> anchors = const []}) async {
    final base = mixBase(p.kind);
    final filtered = !filterFor(p.kind).isEmpty;
    final tries = <SongQuery>[
      queryForPart(p, exclude: used, limit: 400),
      base.copyWith(
          targetRpm: p.targetRpm,
          rpmTolerance: p.rpmTolerance * 1.6 + 3,
          exclude: used,
          limit: 400),
      if (filtered) base.copyWith(exclude: used, limit: 400),
    ];
    final preset = presetNamed(p.kind.preset);
    (PartPick, bool)? fallback;
    for (var i = 0; i < tries.length; i++) {
      final pick = planPartSongs(await db.search(tries[i]), need, random,
          previous: previous,
          recentlyTaught: _recent,
          anchors: anchors,
          single: p.kind == PartRole.halfAndHalf,
          required: p.kind == PartRole.halfAndHalf && anchors.isEmpty,
          minSeconds: preset.minSeconds,
          maxSeconds: preset.maxSeconds);
      if (pick == null) continue;
      if (pick.stage < balanceStages.length) return (pick, i >= 1);
      fallback ??= (pick, i >= 1);
    }
    return fallback ?? (null, false);
  }

  /// Picks the songs for one part [p] covering about [need] seconds, give or
  /// take [partToleranceSeconds] (the songs' ends define where the activity
  /// ends), then orders them for a smooth tempo chain after [previous] (the
  /// song before them in the mix). [anchors] are the part's locked songs:
  /// new songs are balanced against them, and a half & half part with none
  /// always gets a song. Picked paths are added to [used]; loose matches and
  /// uneven parts are counted in [lastFillRelaxed] / [lastFillUneven].
  Future<List<Song>> _fillPart(ProgramPart p, Set<String> used, double need,
      {List<Song> anchors = const [], Song? previous}) async {
    if (p.kind == PartRole.halfAndHalf && anchors.isNotEmpty) return const [];
    final (pick, loose) = await _pickForPart(p, used, need, previous: previous, anchors: anchors);
    if (pick == null || pick.songs.isEmpty) return const [];
    if (loose) lastFillRelaxed += pick.songs.length;
    if (pick.uneven) lastFillUneven++;
    used.addAll(pick.songs.map((s) => s.path));
    return orderChain(pick.songs, previous: previous);
  }

  /// Locked songs of the mix grouped by part index (in mix order); key null
  /// holds locked songs without a part in a program of [partCount] parts.
  Map<int?, List<Song>> _lockedByPart(int partCount) {
    _syncParts();
    final out = <int?, List<Song>>{};
    for (var i = 0; i < mix.length; i++) {
      if (!lockedPaths.contains(mix[i].path)) continue;
      final pi = mixPart[i];
      (out[pi != null && pi < partCount ? pi : null] ??= []).add(mix[i]);
    }
    return out;
  }

  /// Fills the mix from [t]: for each part, songs whose BPM maps to the part's
  /// RPM until its minutes are covered. Locked songs stay in their parts (in
  /// their order, first in the part) and only the time left is filled;
  /// locked songs without a part go at the end. Returns how many music parts
  /// got no songs.
  Future<int> fillProgram(Program t) async {
    final locked = _lockedByPart(t.parts.length);
    final used = <String>{for (final l in locked.values) ...l.map((s) => s.path)};
    final out = <Song>[];
    final parts = <int?>[];
    var unfilled = 0;
    lastFillRelaxed = 0;
    lastFillAdded = 0;
    lastFillUneven = 0;
    _recent = await _loadRecent();
    // Part ends are measured on the whole programme's clock, so an overshoot
    // (or shortfall) in one part is absorbed by the next instead of piling up.
    var elapsed = 0.0, partEnd = 0.0;
    for (var i = 0; i < t.parts.length; i++) {
      final p = t.parts[i];
      partEnd += p.minutes * 60;
      final keep = locked[i] ?? const <Song>[];
      for (final s in keep) {
        out.add(s);
        parts.add(i);
        elapsed += s.playSeconds ?? 240;
      }
      if (!p.music) {
        elapsed = partEnd;
        continue;
      }
      final picked = await _fillPart(p, used, partEnd - elapsed,
          anchors: keep, previous: out.lastOrNull);
      lastFillAdded += picked.length;
      for (final s in picked) {
        out.add(s);
        parts.add(i);
        elapsed += s.playSeconds ?? 240;
      }
      if (keep.isEmpty && picked.isEmpty) unfilled++;
    }
    for (final s in locked[null] ?? const <Song>[]) {
      out.add(s);
      parts.add(null);
    }
    _edit(() {
      mix = out;
      mixPart = parts;
      program = t;
      targetMinutes = t.minutes;
      _refreshMixName();
    });
    lastFillBigJumps = bigJumps(mix).length;
    return unfilled;
  }

  /// Re-fills part [part] of the current program: its unlocked songs are
  /// replaced with new picks for the part's time left after its locked songs;
  /// the rest of the mix is untouched. Returns how many songs were added.
  Future<int> refillPart(int part) async {
    if (part < 0 || part >= program.parts.length) return 0;
    final p = program.parts[part];
    _syncParts();
    final keep = <Song>[];
    final keepParts = <int?>[];
    for (var i = 0; i < mix.length; i++) {
      if (mixPart[i] == part && !lockedPaths.contains(mix[i].path)) continue;
      keep.add(mix[i]);
      keepParts.add(mixPart[i]);
    }
    final lockedSongs = [
      for (var i = 0; i < keep.length; i++)
        if (keepParts[i] == part) keep[i]
    ];
    final lockedSecs = lockedSongs.fold(0.0, (a, s) => a + songSeconds(s));
    lastFillRelaxed = 0;
    lastFillUneven = 0;
    _recent = await _loadRecent();
    // After the last song of this or an earlier part (as in [addToPart]).
    var at = 0;
    for (var i = 0; i < keep.length; i++) {
      final mp = keepParts[i];
      if (mp != null && mp <= part) at = i + 1;
    }
    // Where this part should end on the programme's clock, as in [fillProgram],
    // so it also absorbs drift from earlier parts (within reason).
    var elapsed = 0.0, partEnd = 0.0;
    for (var q = 0; q < part; q++) {
      partEnd += program.parts[q].minutes * 60;
      for (var i = 0; i < keep.length; i++) {
        if (keepParts[i] == q) elapsed += songSeconds(keep[i]);
      }
      if (!program.parts[q].music) elapsed = partEnd;
    }
    partEnd += p.minutes * 60;
    final own = max(0.0, p.minutes * 60 - lockedSecs);
    final need = (partEnd - elapsed - lockedSecs).clamp(own * 0.5, own * 1.5);
    final picked = p.music
        ? await _fillPart(p, {for (final s in keep) s.path}, need,
            anchors: lockedSongs, previous: at > 0 ? keep[at - 1] : null)
        : const <Song>[];
    _edit(() {
      mix = [...keep]..insertAll(at, picked);
      mixPart = [...keepParts]..insertAll(at, [for (final _ in picked) part]);
    });
    lastFillAdded = picked.length;
    lastFillBigJumps = bigJumps(mix).length;
    return picked.length;
  }

  /// Library songs per music part of [p] with the Mix filters (see [programReadiness]).
  Future<List<PartReadiness>> readinessOf(Program p) =>
      programReadiness(db, p, base: mixBase);

  /// Songs for [part] of the current program, best rated first.
  Future<List<Song>> suggestForPart(int part) async {
    if (part < 0 || part >= program.parts.length) return [];
    return _rankRecent(db.search(queryForPart(program.parts[part],
            exclude: {for (final m in mix) m.path}, limit: 12)
        .copyWith(sort: SongSort.rating)));
  }

  /// Replaces mix[i] with a similar song, relaxing the match (duration, then
  /// steadiness, then tempo) until a candidate is found, so a swap only ever
  /// fails when the library truly has nothing else left to offer.
  Future<bool> swap(int i) async {
    _syncParts();
    final cur = mix[i];
    final d = cur.playSeconds;
    final part = partAt(i);
    final bpm = cur.medianBpm;
    final exclude = {for (final m in mix) m.path};
    final recent = await _loadRecent();

    SongQuery baseFor({bool useRpm = true, bool useStddev = true}) {
      if (part != null) {
        var q = mixBase(part.kind).copyWith(exclude: exclude, limit: 100);
        if (useRpm) {
          q = q.copyWith(targetRpm: part.targetRpm, rpmTolerance: part.rpmTolerance);
        }
        if (useStddev && part.maxStddev != null) q = q.copyWith(maxStddev: part.maxStddev);
        return q;
      }
      var q = mixBase().copyWith(exclude: exclude, limit: 100);
      if (useRpm && bpm != null) q = q.copyWith(targetRpm: bpm, rpmTolerance: 8);
      return q;
    }

    final attempts = <SongQuery Function()>[
      () => baseFor().copyWith(
          minSeconds: d == null ? null : d - 60,
          maxSeconds: d == null ? null : d + 60,
          clearDuration: d == null),
      () => baseFor(),
      () => baseFor(useStddev: false),
      () => baseFor(useRpm: false, useStddev: false),
    ];
    for (final attempt in attempts) {
      final cands = await db.search(attempt());
      final s = pickWeighted(preferCandidates(cands, recentlyTaught: recent), random);
      if (s != null) {
        _edit(() => mix[i] = s);
        return true;
      }
    }
    return false;
  }

  // ---- damaged songs ----

  /// Why each damaged mix song was flagged (path -> reason), for tooltips.
  Map<String, String?> damagedReasons = {};

  /// Indexes of mix songs tagged damaged.
  List<int> get damagedIndexes => [
        for (var i = 0; i < mix.length; i++)
          if (mix[i].damaged) i
      ];

  /// Re-reads tags of the mix songs (e.g. after a damage scan) so damaged
  /// songs show up without reloading the mix. Not an edit.
  Future<void> refreshDamaged() async {
    if (mix.isEmpty) {
      damagedReasons = {};
      return;
    }
    final fresh = await db.songsAt(paths);
    mix = [for (final m in mix) fresh[m.path] ?? m];
    final bad = [for (final m in mix) if (m.damaged) m.path];
    final h = await db.healthOf(bad);
    damagedReasons = {for (final p in bad) p: h[p]?.reason};
    notifyListeners();
  }

  /// Tempo gap between two songs, allowing half/double time.
  static double _bpmGap(double? a, double? b) {
    if (a == null || b == null) return 10;
    return [(a - b).abs(), (a * 2 - b).abs(), (a / 2 - b).abs()].reduce(min);
  }

  /// How close [c] is to [cur] in length (minutes off) and tempo (per 5 bpm);
  /// a lower score is a better stand-in.
  double _likeness(Song cur, Song c, Set<String> recent) {
    final d = cur.playSeconds, cd = c.playSeconds;
    final len = d == null || cd == null ? 1.0 : (d - cd).abs() / 60;
    return len * 1.5 +
        _bpmGap(cur.medianBpm, c.medianBpm) / 5 -
        c.rating * 0.1 +
        (recent.contains(c.path) ? 0.5 : 0);
  }

  /// Songs that could stand in for mix[i]: same part (cadence and filters),
  /// closest in length and tempo first. Never damaged or already in the mix.
  /// [recentPaths] lets batch callers load the recently used set once.
  Future<List<Song>> replacementsFor(int i,
      {int limit = 8, Set<String> alsoExclude = const {}, Set<String>? recentPaths}) async {
    _syncParts();
    final cur = mix[i];
    final d = cur.playSeconds;
    final part = partAt(i);
    final exclude = {for (final m in mix) m.path, ...alsoExclude};
    final recent = recentPaths ?? await _loadRecent();
    SongQuery base({bool tempo = true}) {
      var q = (part != null ? mixBase(part.kind) : mixBase()).copyWith(exclude: exclude, limit: 200);
      if (!tempo) return q;
      if (part != null) {
        return q.copyWith(targetRpm: part.targetRpm, rpmTolerance: part.rpmTolerance);
      }
      if (cur.medianBpm != null) q = q.copyWith(targetRpm: cur.medianBpm, rpmTolerance: 8);
      return q;
    }

    final win = d == null ? null : max(30.0, d * 0.15);
    for (final q in [
      if (win != null) base().copyWith(minSeconds: d! - win, maxSeconds: d + win),
      base(),
      base(tempo: false),
    ]) {
      final cands = await db.search(q);
      if (cands.isEmpty) continue;
      cands.sort((a, b) => _likeness(cur, a, recent).compareTo(_likeness(cur, b, recent)));
      return cands.take(limit).toList();
    }
    return [];
  }

  /// Puts [s] in place of mix[i], keeping its part and lock. Refuses damaged songs.
  bool replaceAt(int i, Song s) {
    if (s.damaged || i < 0 || i >= mix.length) return false;
    _edit(() => _swapIn(i, s));
    return true;
  }

  void _swapIn(int i, Song s) {
    final old = mix[i].path;
    mix[i] = s;
    if (lockedPaths.remove(old)) lockedPaths.add(s.path);
  }

  /// Replaces mix[i] with its closest stand-in; returns it (null if none).
  Future<Song?> replaceSong(int i) async {
    final best = (await replacementsFor(i, limit: 1)).firstOrNull;
    if (best == null) return null;
    replaceAt(i, best);
    return best;
  }

  /// Replaces every damaged song in the mix with its closest stand-in, as one
  /// undoable edit. Returns (replaced, damaged) counts; songs with no stand-in stay.
  Future<(int, int)> replaceAllDamaged() async {
    final damaged = damagedIndexes;
    final picks = <int, Song>{};
    final taken = <String>{};
    final recent = damaged.isEmpty ? const <String>{} : await _loadRecent();
    for (final i in damaged) {
      final s = (await replacementsFor(i, limit: 1, alsoExclude: taken, recentPaths: recent)).firstOrNull;
      if (s == null) continue;
      picks[i] = s;
      taken.add(s.path);
    }
    if (picks.isNotEmpty) {
      _edit(() {
        for (final e in picks.entries) {
          _swapIn(e.key, e.value);
        }
      });
    }
    return (picks.length, damaged.length);
  }

  /// Songs whose tempo follows on smoothly from the end of the mix.
  Future<List<Song>> suggestNext() async {
    final bpm = mix.isEmpty ? null : mix.last.medianBpm;
    if (bpm == null) return [];
    return _rankRecent(db.search(mixBase(mix.isEmpty ? null : partAt(mix.length - 1)?.kind).copyWith(
        targetRpm: bpm,
        rpmTolerance: 8,
        exclude: {for (final m in mix) m.path},
        sort: SongSort.rating,
        limit: 10)));
  }

  // ---- name, save, load, export ----

  /// Typing the name: consecutive calls share one undo entry.
  void setMixName(String n) => _edit(() {
        mixName = n;
        mixNameAuto = n.trim().isEmpty;
      }, coalesce: 'name');

  void clearMix() => _edit(() {
        mix = [];
        mixPart = [];
        mixKey = newMixtapeId();
        mixDbId = null;
      });

  /// Puts the library songs of M3U/M3U8 playlist [text] in the mix, in
  /// playlist order and without program parts (see [matchM3uEntries]).
  /// [replace] starts a new mix (named [name] if given, like [clearMix]);
  /// otherwise the songs go at the end, moving any already in the mix. One
  /// undoable edit; nothing changes when no song matches.
  Future<M3uImportResult> importPlaylist(String text,
      {String? baseDir, bool replace = true, String? name}) async {
    final entries = parseM3uEntries(text, baseDir: baseDir);
    final matches = matchM3uEntries(entries, await db.songPathIndex());
    final songs = await db.songsAt([for (final m in matches) ?m.path]);
    final picked = <Song>[];
    final seen = <String>{};
    final skipped = <M3uSkip>[];
    for (var i = 0; i < entries.length; i++) {
      final path = matches[i].path;
      final song = path == null ? null : songs[path];
      if (song == null) {
        skipped.add(M3uSkip(entries[i].line, matches[i].reason ?? M3uSkipReason.notFound));
      } else if (!seen.add(song.path)) {
        skipped.add(M3uSkip(entries[i].line, M3uSkipReason.duplicate));
      } else {
        picked.add(song);
      }
    }
    if (picked.isNotEmpty) {
      _edit(() {
        _syncParts();
        if (replace) {
          mix = picked;
          mixPart = List<int?>.filled(picked.length, null, growable: true);
          lockedPaths = {};
          mixKey = newMixtapeId();
          mixDbId = null;
          final n = name?.trim() ?? '';
          if (n.isNotEmpty) {
            mixName = n;
            mixNameAuto = false;
          }
        } else {
          for (var i = mix.length - 1; i >= 0; i--) {
            if (seen.contains(mix[i].path)) {
              mix.removeAt(i);
              mixPart.removeAt(i);
            }
          }
          mix.addAll(picked);
          mixPart.addAll(List<int?>.filled(picked.length, null));
        }
      });
    }
    return M3uImportResult(matched: picked.length, total: entries.length, skipped: skipped);
  }

  Future<void> loadSavedMixes() async {
    savedMixes = await db.mixes();
    notifyListeners();
  }

  Future<void> saveMix() async {
    mixNameAuto = false;
    final name = mixName.trim().isEmpty ? 'New mix' : mixName.trim();
    _syncParts();
    final id = await db.saveMix(name, [for (final s in mix) s.path],
        parts: mixPart, program: jsonEncode(program.toJson()), notes: songNotes);
    await db.markMixed(paths);
    final rowKey = await db.setting('mix_key:$id');
    var key = mixKey;
    if (id != mixDbId && rowKey != null) {
      // Saved over another existing mix: this is now that mix.
      key = rowKey;
    } else {
      await db.setSetting('mix_key:$id', mixKey);
      final old = mixDbId;
      if (old != null && old != id && await db.setting('mix_key:$old') == mixKey) {
        // Saved under a new name: the key moves with the edited mix, and
        // the old saved copy becomes its own mixtape.
        await db.setSetting('mix_key:$old', newMixtapeId());
      }
    }
    savedMixes = await db.mixes();
    final before = (mixKey, mixDbId);
    _edit(() {
      mixKey = key;
      mixDbId = id;
      mixName = name;
    }, undoable: false);
    // Undo/redo steps of this same mix now belong to the saved copy.
    MixSnapshot rekey(MixSnapshot s) =>
        (s.mixKey, s.mixDbId) == before ? s.withIdentity(key, id) : s;
    for (final stack in [_undo, _redo]) {
      for (var i = 0; i < stack.length; i++) {
        stack[i] = rekey(stack[i]);
      }
    }
    _markClean();
  }

  Future<void> loadMix(MixInfo m) async {
    final songs = <Song>[];
    final parts = <int?>[];
    final saved = await db.mixParts(m.id);
    final paths = await db.mixPaths(m.id);
    final byPath = await db.songsAt(paths);
    for (var i = 0; i < paths.length; i++) {
      final s = byPath[paths[i]];
      if (s != null) {
        songs.add(s);
        parts.add(i < saved.length ? saved[i] : null);
      }
    }
    Program? savedProgram;
    if (m.programJson != null) {
      try {
        savedProgram = Program.fromJson(jsonDecode(m.programJson!) as Map<String, dynamic>);
      } catch (_) {
        // Keep the current program if the saved one can't be parsed.
      }
    }
    var key = await db.setting('mix_key:${m.id}');
    if (key == null) {
      key = newMixtapeId();
      await db.setSetting('mix_key:${m.id}', key);
    }
    final mixtapeKey = key;
    final notes = await db.mixNotes(m.id);
    _edit(() {
      mix = songs;
      mixPart = parts;
      lockedPaths = {};
      songNotes = notes;
      mixName = m.name;
      mixNameAuto = false;
      mixDbId = m.id;
      if (savedProgram != null) program = savedProgram;
      mixKey = mixtapeKey;
    });
    _markClean();
    await db.noteMixOpened(m.id);
    await refreshDamaged();
  }

  Future<void> deleteMix(MixInfo m) => deleteMixes([m.id]);

  /// Deletes saved mixes [ids]; pass the result to [restoreMixes] to undo.
  Future<DeletedMixes> deleteMixes(List<int> ids) async {
    final gone = await db.deleteMixes(ids);
    savedMixes = await db.mixes();
    if (ids.contains(mixDbId)) {
      _unsavedFrom = mixDbId;
      // The loaded mix stays on screen (and keeps its phone key) but is no
      // longer a saved mix.
      _edit(() => mixDbId = null);
    } else {
      notifyListeners();
    }
    return gone;
  }

  /// Id of the loaded mix when it was deleted, so undoing the delete
  /// reattaches it.
  int? _unsavedFrom;

  Future<void> restoreMixes(DeletedMixes d) async {
    await db.restoreMixes(d);
    savedMixes = await db.mixes();
    if (mixDbId == null && _unsavedFrom != null && d.ids.contains(_unsavedFrom)) {
      mixDbId = _unsavedFrom;
      _unsavedFrom = null;
    }
    notifyListeners();
  }

  /// Renames saved mix [m]; throws [MixNameTaken] if the name is in use.
  /// If [m] is the loaded mix its name follows.
  Future<void> renameMix(MixInfo m, String name) async {
    await db.renameMix(m.id, name);
    savedMixes = await db.mixes();
    if (mixDbId == m.id) {
      // The DB already has the new name, so a clean mix stays clean.
      final wasClean = !dirty;
      _edit(() {
        mixName = name.trim();
        mixNameAuto = false;
      });
      if (wasClean) {
        _markClean();
        notifyListeners();
      }
    } else {
      notifyListeners();
    }
  }

  /// Copies saved mix [m] as [name] (a new phone mixtape); returns its id.
  Future<int> duplicateMix(MixInfo m, String name) async {
    final id = await db.duplicateMix(m.id, name);
    savedMixes = await db.mixes();
    notifyListeners();
    return id;
  }

  String classSheet() {
    _syncParts();
    return buildClassSheet(mixName, mix, program: program, parts: mixPart, notes: songNotes);
  }

  String mixAsM3u8() => buildM3u8([
        for (final s in mix)
          MixEntry(s.path, s.title ?? s.path.split(RegExp(r'[\\/]')).last,
              artist: s.artist, durationSec: s.playSeconds)
      ]);
}

/// One undo step: a copy of the mix (see [MixController.snapshot]).
class MixSnapshot {
  const MixSnapshot({
    required this.songs,
    required this.parts,
    required this.locked,
    this.notes = const {},
    required this.program,
    required this.name,
    required this.nameAuto,
    required this.mixKey,
    required this.mixDbId,
    required this.targetMinutes,
  });

  final List<Song> songs;
  final List<int?> parts;
  final Set<String> locked;
  final Map<String, String> notes;
  final Program program;
  final String name;
  final bool nameAuto;
  final String mixKey;
  final int? mixDbId;
  final double targetMinutes;

  /// What a save stores (songs, parts, locks, program, name), for dirty checks.
  String get content => jsonEncode({
        'paths': [for (final s in songs) s.path],
        'parts': parts,
        'locked': [for (final s in songs) if (locked.contains(s.path)) s.path],
        if (notes.isNotEmpty) 'notes': {for (final s in songs) if (notes[s.path] != null) s.path: notes[s.path]},
        'program': program.toJson(),
        'name': name.trim(),
      });

  MixSnapshot withIdentity(String key, int? dbId) => MixSnapshot(
      songs: songs,
      parts: parts,
      locked: locked,
      notes: notes,
      program: program,
      name: name,
      nameAuto: nameAuto,
      mixKey: key,
      mixDbId: dbId,
      targetMinutes: targetMinutes);
}

/// How many songs fit one tempo band of a part role, narrowing step by step:
/// any undamaged song at the tempo → the Mix filters → explicit/rating
/// limits → rotation. [eligible] is what fills and suggestions pick from.
class PartSupply {
  const PartSupply({
    required this.role,
    required this.minRpm,
    required this.maxRpm,
    required this.tempo,
    required this.filtered,
    required this.allowed,
    required this.eligible,
  });

  final PartRole role;
  final num minRpm, maxRpm;
  final int tempo, filtered, allowed, eligible;

  /// What removed songs, e.g. "filter −40 · explicit/rating −3 · rotation −5".
  String get why => [
        if (tempo > filtered) 'filter −${tempo - filtered}',
        if (filtered > allowed) 'explicit/rating −${filtered - allowed}',
        if (allowed > eligible) 'rotation −${allowed - eligible}',
      ].join(' · ');
}
