part of 'mix_controller.dart';

/// Keeping classes fresh: swapping out recently used songs and planning a
/// series of mixes that don't repeat each other. (Rotation itself is a
/// search limit, see [MixController.rotationMixes].)
extension MixSeries on MixController {
  /// Mix songs that were taught recently or are in one of the last
  /// [lastMixes] other saved mixes: the ones [refreshPicks] swaps out.
  Future<List<int>> staleIndexes({int lastMixes = 3}) async =>
      _staleIn(await _stalePaths(lastMixes));

  Future<Set<String>> _stalePaths(int lastMixes) async => {
        ...await db.recentlyTaughtPaths(),
        ...await db.pathsInRecentMixes(lastMixes, exceptMix: mixDbId),
      };

  List<int> _staleIn(Set<String> stale) => [
        for (var i = 0; i < mix.length; i++)
          if (stale.contains(mix[i].path) && !lockedPaths.contains(mix[i].path)) i
      ];

  /// A fresh stand-in (same part, close in length and tempo, not itself
  /// stale) for each stale unlocked song; songs with none are left out.
  Future<Map<int, Song>> refreshPicks({int lastMixes = 3}) async {
    final stale = await _stalePaths(lastMixes);
    final idx = _staleIn(stale);
    if (idx.isEmpty) return {};
    final recent = await _loadRecent();
    final picks = <int, Song>{};
    final taken = <String>{};
    for (final i in idx) {
      final s = (await replacementsFor(i, limit: 20, alsoExclude: taken, recentPaths: recent))
          .where((c) => !stale.contains(c.path))
          .firstOrNull;
      if (s == null) continue;
      picks[i] = s;
      taken.add(s.path);
    }
    return picks;
  }

  /// Applies [picks] (index -> new song) as one undoable edit.
  void applyReplacements(Map<int, Song> picks) {
    final ok = {
      for (final e in picks.entries)
        if (e.key >= 0 && e.key < mix.length && !e.value.damaged) e.key: e.value
    };
    if (ok.isEmpty) return;
    _edit(() {
      for (final e in ok.entries) {
        _swapIn(e.key, e.value);
      }
    });
  }

  /// Plans a series of [count] mixes of the current program named
  /// "[name] 1".."[name] N", each filled avoiding the songs of the earlier
  /// ones where the library allows, saved and tagged `series:[name]`. The
  /// editor ends on the last one. Returns the saved mix ids.
  Future<List<int>> planSeries(String name, int count, {void Function(int done)? onProgress}) async {
    final t = program;
    final ids = <int>[];
    final used = <String>{};
    try {
      for (var k = 1; k <= count; k++) {
        clearMix();
        lockedPaths = {};
        songNotes = {};
        _seriesUsed = used;
        await fillProgram(t);
        _edit(() {
          mixName = '$name $k';
          mixNameAuto = false;
        }, undoable: false);
        await saveMix();
        ids.add(mixDbId!);
        used.addAll(paths);
        onProgress?.call(k);
      }
    } finally {
      _seriesUsed = const {};
    }
    if (ids.isNotEmpty) await db.tagMixes(ids, 'series:$name');
    await loadSavedMixes();
    return ids;
  }
}
