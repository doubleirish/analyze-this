import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/app_state.dart';
import '../services/db.dart';
import '../services/planner.dart';
import 'package:shared_core/shared_core.dart';
import 'duplicates_screen.dart';
import 'browse_screens.dart';
import 'bpm_fix_dialog.dart';
import 'trim_dialog.dart';
import 'mix_add.dart';

Future<void> playSong(BuildContext context, AppState s, String path) async {
  if (s.mode == PlayMode.mix && !s.mixer.mix.any((m) => m.path == path)) s.setMode(PlayMode.alphabetical);
  await s.play(path);
  if (context.mounted) {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => const NowPlayingScreen()));
  }
}

const _effortWords = ['go', 'fire', 'higher', 'faster', 'run', 'power', 'push', 'climb', 'fly'];
const _easterWords = ['final', 'last', 'end', 'begin', 'start', 'stop', 'countdown', 'goodbye'];

List<String> _split(String s) =>
    [for (final t in s.split(',')) if (t.trim().isNotEmpty) t.trim()];

class LibraryTab extends StatefulWidget {
  const LibraryTab({super.key});

  /// The Songs tab's main search box (focused by Ctrl+F).
  static final searchFocus = FocusNode(debugLabel: 'Songs search');

  @override
  State<LibraryTab> createState() => _LibraryTabState();
}

class _LibraryTabState extends State<LibraryTab> {
  final _c = <String, TextEditingController>{
    for (final k in [
      'text', 'phrase', 'any', 'all', 'not', 'min', 'max', 'rpm', 'tol',
      'std', 'minDur', 'maxDur', 'genre', 'artist', 'album'
    ])
      k: TextEditingController(text: k == 'tol' ? '5' : ''),
  };
  bool _favOnly = false;
  bool _recent = false;
  int? _decade;
  String _tag = '';
  bool _lyricsOnly = false;
  bool _hideExplicit = false;
  bool _hideUsed = false;
  bool _hideTaught = false;
  bool _halfDouble = true;
  bool _includeTitle = false;
  int _minRating = 0;
  SongSort _sort = SongSort.artist;
  String _preset = '';

  /// Year limits carried over from a saved search or [AppState.showInSongs]
  /// (shown as a removable chip; the form has no year fields).
  int? _minYear;
  int? _maxYear;

  late final AppState _state;

  @override
  void initState() {
    super.initState();
    _state = context.read<AppState>()..addListener(_takeRequest);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _takeRequest();
    });
  }

  void _takeRequest() {
    final q = _state.takeSongsRequest();
    if (q != null) _applySmart(q);
  }

  @override
  void dispose() {
    _state.removeListener(_takeRequest);
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  double? _n(String k) => double.tryParse(_c[k]!.text);
  double? _mins(String k) => _n(k) == null ? null : _n(k)! * 60;

  /// Decades in the library (1950s–2020s if none), plus the selected one so
  /// a saved filter never disappears from the list.
  List<int> _decadeOptions(AppState s) {
    final ds = {
      ...s.decades.isEmpty ? [for (var d = 1950; d <= 2020; d += 10) d] : s.decades,
      ?_decade,
    }.toList()
      ..sort();
    return ds;
  }

  void _go() => context.read<AppState>().search(SongQuery(
        text: _c['text']!.text,
        artist: _c['artist']!.text,
        album: _c['album']!.text,
        favOnly: _favOnly,
        addedSince: _recent
            ? DateTime.now().subtract(const Duration(days: 30)).millisecondsSinceEpoch
            : null,
        lyrics: _c['phrase']!.text,
        lyricsAny: _split(_c['any']!.text),
        lyricsAll: _split(_c['all']!.text),
        lyricsNot: _split(_c['not']!.text),
        anyIncludesTitle: _includeTitle,
        minBpm: _n('min'),
        maxBpm: _n('max'),
        targetRpm: _n('rpm'),
        rpmTolerance: _n('tol') ?? 5,
        halfDouble: _halfDouble,
        maxStddev: _n('std'),
        minSeconds: _mins('minDur'),
        maxSeconds: _mins('maxDur'),
        genre: _c['genre']!.text,
        decade: _decade,
        tag: _tag,
        lyricsOnly: _lyricsOnly,
        hideExplicit: _hideExplicit,
        hideUsed: _hideUsed,
        hideTaughtWithinDays: _hideTaught ? context.read<AppState>().recentWeeks * 7 : null,
        minRating: _minRating,
        sort: _sort,
        minYear: _minYear,
        maxYear: _maxYear,
      ));

  void _applyPreset(String name) {
    setState(() {
      _preset = name;
      final p = name.isEmpty ? null : presetNamed(name);
      String f(double? v) => v == null ? '' : v.round().toString();
      _c['min']!.text = f(p?.minBpm);
      _c['max']!.text = f(p?.maxBpm);
      _c['std']!.text = f(p?.maxStddev);
      _c['minDur']!.text = p?.minSeconds == null ? '' : (p!.minSeconds! / 60).toStringAsFixed(1);
      _c['maxDur']!.text = p?.maxSeconds == null ? '' : (p!.maxSeconds! / 60).toStringAsFixed(1);
      _c['rpm']!.text = '';
    });
    _go();
  }

  void _lyricChip(String word, {required bool title}) {
    setState(() {
      _c['any']!.text = word;
      _includeTitle = title;
    });
    _go();
  }

  Future<void> _surprise(BuildContext context) async {
    final s = context.read<AppState>();
    _go();
    final song = await s.surprise();
    if (!context.mounted) return;
    if (song == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('No songs match the current filters')));
      return;
    }
    if (!addToMixOrWarn(context, s.mixer, song)) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('Added ${song.display} to the mix')));
  }

  Future<void> _saveSmart(BuildContext context) async {
    final s = context.read<AppState>();
    _go();
    final c = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Save this search'),
        content: TextField(
            controller: c,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'e.g. Britpop 80s, 120-130 BPM'),
            onSubmitted: (v) => Navigator.pop(ctx, v)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Save')),
        ],
      ),
    );
    c.dispose();
    if (name != null) await s.saveSmartList(name);
  }

  /// Fills the form from a saved search and runs it.
  void _applySmart(SongQuery q) {
    setState(() {
      String f(double? v) => v == null ? '' : v.round().toString();
      _c['text']!.text = q.text;
      _c['artist']!.text = q.artist;
      _c['album']!.text = q.album;
      _c['phrase']!.text = q.lyrics;
      _c['any']!.text = q.lyricsAny.join(', ');
      _c['all']!.text = q.lyricsAll.join(', ');
      _c['not']!.text = q.lyricsNot.join(', ');
      _c['min']!.text = f(q.minBpm);
      _c['max']!.text = f(q.maxBpm);
      _c['rpm']!.text = q.targetRpm == null
          ? ''
          : q.targetRpm! % 1 == 0
              ? q.targetRpm!.round().toString()
              : q.targetRpm.toString();
      _c['tol']!.text = q.rpmTolerance.toString();
      _c['std']!.text = f(q.maxStddev);
      _c['minDur']!.text = q.minSeconds == null ? '' : (q.minSeconds! / 60).toStringAsFixed(1);
      _c['maxDur']!.text = q.maxSeconds == null ? '' : (q.maxSeconds! / 60).toStringAsFixed(1);
      _c['genre']!.text = q.genre;
      _decade = q.decade;
      _tag = q.tag;
      _lyricsOnly = q.lyricsOnly;
      _hideExplicit = q.hideExplicit;
      _hideUsed = q.hideUsed;
      _hideTaught = q.hideTaughtWithinDays != null;
      _halfDouble = q.halfDouble;
      _includeTitle = q.anyIncludesTitle;
      _minRating = q.minRating;
      _sort = q.sort;
      _favOnly = q.favOnly;
      _recent = q.addedSince != null;
      _minYear = q.minYear;
      _maxYear = q.maxYear;
    });
    _go();
  }

  Future<void> _batchEdit(BuildContext context) async {
    final s = context.read<AppState>();
    final c = {for (final k in ['artist', 'album', 'genre', 'year']) k: TextEditingController()};
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Edit ${s.selected.length} songs'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Blank fields are left alone. Changes are kept when you rescan.'),
          for (final k in c.keys)
            TextField(controller: c[k], decoration: InputDecoration(labelText: k)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Apply')),
        ],
      ),
    );
    String? v(String k) => c[k]!.text.trim().isEmpty ? null : c[k]!.text.trim();
    if (ok == true) {
      await s.editSelected(
          artist: v('artist'), album: v('album'), genre: v('genre'), year: int.tryParse(v('year') ?? ''));
    }
    for (final t in c.values) {
      t.dispose();
    }
  }

  Widget _field(String k, String label, double w) {
    final field = TextField(
      controller: _c[k],
      focusNode: k == 'text' ? LibraryTab.searchFocus : null,
      decoration: InputDecoration(labelText: label, isDense: true),
      onSubmitted: (_) => _go(),
    );
    return SizedBox(
      width: w,
      child: k == 'text' ? Tooltip(message: 'Search (Ctrl+F)', child: field) : field,
    );
  }

  Widget _check(String label, bool v, ValueChanged<bool> on) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        Checkbox(
            value: v,
            onChanged: (b) {
              setState(() => on(b ?? false));
              _go();
            }),
        Text(label),
      ]);

  Widget _chips(String title, List<Widget> chips) => Align(
        alignment: Alignment.centerLeft,
        child: Wrap(spacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text(title, style: Theme.of(context).textTheme.labelMedium),
          ...chips,
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(children: [
        ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.45),
          child: SingleChildScrollView(
            child: Column(children: [
              Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                _field('text', 'Title / artist / album', 200),
                _field('artist', 'Artist', 150),
                _field('album', 'Album', 150),
                _field('phrase', 'Lyrics phrase', 160),
                _field('any', 'Lyrics any of (a, b)', 170),
                _field('all', 'Lyrics all of (a, b)', 170),
                _field('not', 'Lyrics exclude (a, b)', 170),
                _check('Title counts for "any"', _includeTitle, (v) => _includeTitle = v),
              ]),
              const SizedBox(height: 8),
              Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                DropdownButton<String>(
                  value: _preset,
                  items: [
                    const DropdownMenuItem(value: '', child: Text('Section preset')),
                    for (final p in sectionPresets)
                      DropdownMenuItem(value: p.name, child: Text(p.name)),
                  ],
                  onChanged: (v) => _applyPreset(v ?? ''),
                ),
                _field('min', 'Min BPM', 70),
                _field('max', 'Max BPM', 70),
                _field('rpm', 'Target RPM', 80),
                _field('tol', '± BPM', 60),
                _check('Half/double time', _halfDouble, (v) => _halfDouble = v),
                _field('std', 'Max tempo drift', 100),
                _field('minDur', 'Min mins', 70),
                _field('maxDur', 'Max mins', 70),
                _field('genre', 'Genre', 120),
              ]),
              const SizedBox(height: 8),
              Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                DropdownButton<int?>(
                  value: _decade,
                  items: [
                    const DropdownMenuItem(value: null, child: Text('Any decade')),
                    for (final d in _decadeOptions(s))
                      DropdownMenuItem(value: d, child: Text('${d}s')),
                  ],
                  onChanged: (v) {
                    setState(() => _decade = v);
                    _go();
                  },
                ),
                if (_minYear != null || _maxYear != null)
                  InputChip(
                    label: Text(_minYear == null
                        ? 'Years to $_maxYear'
                        : _maxYear == null
                            ? 'Years from $_minYear'
                            : 'Years $_minYear–$_maxYear'),
                    onDeleted: () {
                      setState(() => _minYear = _maxYear = null);
                      _go();
                    },
                  ),
                DropdownButton<String>(
                  value: s.tagNames.contains(_tag) ? _tag : '',
                  items: [
                    const DropdownMenuItem(value: '', child: Text('Any tag')),
                    for (final t in s.tagNames) DropdownMenuItem(value: t, child: Text(t)),
                  ],
                  onChanged: (v) {
                    setState(() => _tag = v ?? '');
                    _go();
                  },
                ),
                DropdownButton<int>(
                  value: _minRating,
                  items: [
                    for (var i = 0; i <= 5; i++)
                      DropdownMenuItem(value: i, child: Text(i == 0 ? 'Any rating' : '$i+ stars')),
                  ],
                  onChanged: (v) {
                    setState(() => _minRating = v ?? 0);
                    _go();
                  },
                ),
                DropdownButton<SongSort>(
                  value: _sort,
                  items: [
                    for (final o in SongSort.values)
                      DropdownMenuItem(value: o, child: Text('Sort: ${o.name}')),
                  ],
                  onChanged: (v) {
                    setState(() => _sort = v ?? SongSort.artist);
                    _go();
                  },
                ),
                _check('Has lyrics', _lyricsOnly, (v) => _lyricsOnly = v),
                _check('Hide explicit', _hideExplicit, (v) => _hideExplicit = v),
                _check('Hide songs in saved mixes', _hideUsed, (v) => _hideUsed = v),
                Row(mainAxisSize: MainAxisSize.min, children: [
                  _check('Hide songs taught in last', _hideTaught, (v) => _hideTaught = v),
                  const SizedBox(width: 6),
                  Tooltip(
                    message: 'Recently taught = taught in this many weeks; '
                        'auto-fill, swap and suggestions also avoid these songs',
                    child: DropdownButton<int>(
                      value: s.recentWeeks,
                      items: [
                        for (final w in {1, 2, 3, 4, 6, 8, 12, 26, s.recentWeeks}.toList()..sort())
                          DropdownMenuItem(value: w, child: Text('$w')),
                      ],
                      onChanged: (v) async {
                        if (v == null) return;
                        await s.setRecentWeeks(v);
                        if (_hideTaught && mounted) _go();
                      },
                    ),
                  ),
                  Text(s.recentWeeks == 1 ? ' week' : ' weeks'),
                ]),
                _check('Favourites', _favOnly, (v) => _favOnly = v),
                _check('Added in last 30 days', _recent, (v) => _recent = v),
                FilledButton.icon(
                    onPressed: _go, icon: const Icon(Icons.search), label: const Text('Search')),
                OutlinedButton.icon(
                    onPressed: () => _surprise(context),
                    icon: const Icon(Icons.casino),
                    label: const Text('Surprise me')),
                OutlinedButton.icon(
                    onPressed: () => _saveSmart(context),
                    icon: const Icon(Icons.bookmark_add),
                    label: const Text('Save search')),
                OutlinedButton.icon(
                    onPressed: () => s.setSelecting(!s.selecting),
                    icon: Icon(s.selecting ? Icons.close : Icons.checklist),
                    label: Text(s.selecting ? 'Done selecting' : 'Select songs')),
                TextButton.icon(
                    onPressed: () => Navigator.push(context,
                        MaterialPageRoute(builder: (_) => const DuplicatesScreen())),
                    icon: const Icon(Icons.content_copy),
                    label: const Text('Duplicates')),
              ]),
              if (s.smartLists.isNotEmpty)
                _chips('Saved searches:', [
                  for (final l in s.smartLists)
                    InputChip(
                      label: Text('${l.name} (${s.smartCounts[l.id] ?? 0})'),
                      onPressed: () => _applySmart(l.query),
                      onDeleted: () => s.deleteSmartList(l),
                    ),
                ]),
              _chips('Effort:', [
                for (final w in _effortWords)
                  ActionChip(label: Text(w), onPressed: () => _lyricChip(w, title: false)),
              ]),
              _chips('Easter eggs:', [
                for (final w in _easterWords)
                  ActionChip(label: Text(w), onPressed: () => _lyricChip(w, title: true)),
              ]),
              _chips('Decade:', [
                for (final d in _decadeOptions(s))
                  ActionChip(
                      label: Text('${d}s'),
                      onPressed: () {
                        setState(() => _decade = d);
                        _go();
                      }),
              ]),
              if (s.genres.isNotEmpty)
                _chips('Genre:', [
                  for (final g in s.genres.take(12))
                    ActionChip(
                        label: Text(g),
                        onPressed: () {
                          _c['genre']!.text = g;
                          _go();
                        }),
                ]),
            ]),
          ),
        ),
        const Divider(),
        if (s.selecting)
          Row(children: [
            Text('${s.selected.length} selected'),
            TextButton(onPressed: s.selectAllShown, child: const Text('Select all shown')),
            TextButton(
                onPressed: s.selected.isEmpty ? null : () => _batchEdit(context),
                child: const Text('Edit artist / album / genre / year…')),
            TextButton(
                onPressed: s.selected.isEmpty
                    ? null
                    : () {
                        addAllToMixOrWarn(context, s.mixer,
                            s.results.where((r) => s.selected.contains(r.path)).toList());
                        s.setSelecting(false);
                      },
                child: const Text('Add to mix')),
            PopupMenuButton<int>(
              enabled: s.selected.isNotEmpty,
              tooltip: 'Explicit / clean',
              onSelected: (v) => s.setExplicitMark(s.selected.toList(), v < 0 ? null : v == 1),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 1, child: Text('Mark explicit')),
                PopupMenuItem(value: 0, child: Text('Mark clean')),
                PopupMenuItem(value: -1, child: Text('Use lyrics check')),
              ],
              child: const Padding(padding: EdgeInsets.all(8), child: Text('Explicit…')),
            ),
          ]),
        Expanded(
          child: ListView.builder(
            itemCount: s.results.length,
            itemBuilder: (_, i) => SongTile(song: s.results[i]),
          ),
        ),
        Text('${s.results.length} shown'),
      ]),
    );
  }
}

class SongTile extends StatelessWidget {
  const SongTile({super.key, required this.song});
  final Song song;

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final q = s.query;
    final bpm = song.medianBpm == null ? '-' : song.medianBpm!.round().toString();
    final bits = [
      '$bpm BPM',
      if (song.bpmStddev != null) '±${song.bpmStddev!.toStringAsFixed(1)}',
      if (song.playSeconds != null)
        '${song.playSeconds! ~/ 60}:${(song.playSeconds! % 60).round().toString().padLeft(2, '0')}${song.trimmed ? ' (trimmed)' : ''}',
      if (song.album != null) song.album!,
      if (song.year != null) '${song.year}',
      if (song.genre != null) song.genre!,
      if (song.isExplicit) 'explicit',
    ].join('  |  ');
    final snip = lyricSnippet(song.lyrics,
        [q.lyrics, ...q.lyricsAny, ...q.lyricsAll].where((e) => e.trim().isNotEmpty).toList());
    return ListTile(
      dense: true,
      leading: s.selecting
          ? Checkbox(value: s.selected.contains(song.path), onChanged: (_) => s.toggleSelected(song))
          : song.damaged
              ? Stack(children: [
                  TrackArt(path: song.path, size: 40),
                  const Positioned(right: 0, bottom: 0, child: DamagedBadge(size: 16)),
                ])
              : TrackArt(path: song.path, size: 40),
      onTap: s.selecting ? () => s.toggleSelected(song) : null,
      title: Text(song.display),
      subtitle: Text([
        bits,
        if (song.userTags.isNotEmpty) '#${song.userTags.join(' #')}',
        if (snip != null) '"$snip"',
      ].join('\n')),
      isThreeLine: true,
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        IconButton(
          tooltip: song.fav ? 'Remove from favourites' : 'Favourite',
          icon: Icon(song.fav ? Icons.favorite : Icons.favorite_border,
              size: 18, color: song.fav ? Colors.pinkAccent : null),
          onPressed: () => s.toggleFav(song),
        ),
        for (var i = 1; i <= 5; i++)
          InkResponse(
            onTap: () => s.setRating(song, i),
            child: Icon(i <= song.rating ? Icons.star : Icons.star_border, size: 18),
          ),
        IconButton(
          tooltip: 'Play (queue follows the mode)',
          icon: const Icon(Icons.play_arrow),
          onPressed: () => playSong(context, s, song.path),
        ),
        IconButton(
          tooltip: s.previewing == song.path ? 'Stop preview' : 'Preview 30 s',
          icon: Icon(s.previewing == song.path ? Icons.stop_circle : Icons.play_circle),
          onPressed: () => s.togglePreview(song),
        ),
        IconButton(
          tooltip: 'Add to end of mix',
          icon: const Icon(Icons.playlist_add),
          onPressed: () => addToMixOrWarn(context, s.mixer, song),
        ),
        IconButton(
          tooltip: 'Add to start of mix',
          icon: const Icon(Icons.vertical_align_top),
          onPressed: () => addToMixOrWarn(context, s.mixer, song, atEnd: false),
        ),
        PopupMenuButton<String>(
          tooltip: 'More',
          onSelected: (v) {
            switch (v) {
              case 'similar':
                showSimilar(context, song);
              case 'used':
                showMixUsage(context, song);
              case 'tags':
                _tagDialog(context, s);
              case 'bpm':
                showBpmFixDialog(context, s, song);
              case 'trim':
                showTrimDialog(context, s, song);
              case 'explicit':
                s.setExplicitMark([song.path], true);
              case 'clean':
                s.setExplicitMark([song.path], false);
              case 'autoExplicit':
                s.setExplicitMark([song.path], null);
              case 'artist':
                openArtist(context, song.artist);
              case 'album':
                openAlbum(context, song.album, song.artist);
            }
          },
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'similar', child: Text('More like this')),
            const PopupMenuItem(value: 'used', child: Text('Used in mixes…')),
            const PopupMenuItem(value: 'tags', child: Text('Tags…')),
            const PopupMenuItem(value: 'bpm', child: Text('Fix BPM…')),
            PopupMenuItem(value: 'trim', child: Text(song.trimmed ? 'Trim (trimmed)…' : 'Trim start/end…')),
            if (song.explicitManual != true) const PopupMenuItem(value: 'explicit', child: Text('Mark explicit')),
            if (song.explicitManual != false) const PopupMenuItem(value: 'clean', child: Text('Mark clean')),
            if (song.explicitManual != null)
              const PopupMenuItem(value: 'autoExplicit', child: Text('Explicit: use lyrics check')),
            if (song.artist != null) const PopupMenuItem(value: 'artist', child: Text('Open artist')),
            if (song.album != null) const PopupMenuItem(value: 'album', child: Text('Open album')),
          ],
        ),
      ]),
    );
  }

  Future<void> _tagDialog(BuildContext context, AppState s) async {
    final c = TextEditingController();
    final tag = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Tag: ${song.display}'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
              controller: c,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'e.g. brit-pop, easter-egg'),
              onSubmitted: (v) => Navigator.pop(ctx, v)),
          Wrap(spacing: 6, children: [
            for (final t in song.userTags)
              InputChip(
                  label: Text(t),
                  onDeleted: () {
                    s.removeTag(song, t);
                    Navigator.pop(ctx);
                  }),
          ]),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Add')),
        ],
      ),
    );
    c.dispose();
    if (tag != null) await s.addTag(song, tag);
  }
}
