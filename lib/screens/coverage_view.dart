import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/app_state.dart';
import '../services/song_models.dart';
import 'browse_screens.dart';

/// Songs still to look at: for each of the four kinds, those neither found
/// nor looked up yet.
int pendingOf(Coverage c) {
  int left(int found, int checked) => (c.songs - found - checked).clamp(0, c.songs);
  return left(c.bpm, c.bpmChecked) +
      left(c.lyrics, c.lyricsChecked) +
      left(c.year, c.yearChecked) +
      left(c.genre, c.genreChecked);
}

String _tip(String label, int songs, int found, int checked, {String checkedNote = 'looked up with nothing found'}) {
  final pct = songs == 0 ? 0 : (found * 100 / songs).round();
  final left = (songs - found - checked).clamp(0, songs);
  return '$label: $found/$songs found ($pct%), $checked $checkedNote, $left not checked';
}

/// Four thin bars (Tempo, Lyrics, Year, Genre). Solid = found, pale = looked
/// up but nothing found. [wide] adds labels and percentages.
class CoverageBar extends StatelessWidget {
  const CoverageBar(this.cov, {super.key, this.wide = false, this.color});
  final Coverage cov;
  final bool wide;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final items = [
      ('Tempo', 'T', cov.bpm, cov.bpmChecked, 'could not be analysed'),
      ('Lyrics', 'L', cov.lyrics, cov.lyricsChecked, 'looked up with nothing found'),
      ('Year', 'Y', cov.year, cov.yearChecked, 'looked up with nothing found'),
      ('Genre', 'G', cov.genre, cov.genreChecked, 'looked up with nothing found'),
    ];
    return Row(children: [
      for (var i = 0; i < items.length; i++) ...[
        if (i > 0) SizedBox(width: wide ? 12 : 4),
        Expanded(
          child: Tooltip(
            message: _tip(items[i].$1, cov.songs, items[i].$3, items[i].$4,
                checkedNote: items[i].$5),
            child: _Segment(
              label: wide ? items[i].$1 : items[i].$2,
              songs: cov.songs,
              found: items[i].$3,
              checked: items[i].$4,
              wide: wide,
              color: color,
            ),
          ),
        ),
      ],
    ]);
  }
}

class _Segment extends StatelessWidget {
  const _Segment(
      {required this.label,
      required this.songs,
      required this.found,
      required this.checked,
      required this.wide,
      this.color});
  final String label;
  final int songs, found, checked;
  final bool wide;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final color = this.color ?? Theme.of(context).colorScheme.primary;
    double share(int n) => songs == 0 ? 0 : (n / songs).clamp(0.0, 1.0);
    final pct = songs == 0 ? 0 : (found * 100 / songs).round();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(wide ? '$label $pct%' : label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(fontSize: wide ? 12 : 9)),
      const SizedBox(height: 2),
      ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: SizedBox(
          height: wide ? 8 : 4,
          child: Stack(children: [
            Positioned.fill(child: ColoredBox(color: color.withValues(alpha: 0.08))),
            FractionallySizedBox(
                widthFactor: share(found + checked),
                child: ColoredBox(color: color.withValues(alpha: 0.3))),
            FractionallySizedBox(widthFactor: share(found), child: ColoredBox(color: color)),
          ]),
        ),
      ),
    ]);
  }
}

/// Scans just [paths] with the current scan options.
Future<void> scanMissing(BuildContext context, List<String> paths) async {
  final s = context.read<AppState>();
  if (paths.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Nothing missing for the current scan options')));
    return;
  }
  await s.scanSongs(paths);
}

/// Which songs a [CoverageSummary] or table row stands for.
class CoverageScope {
  const CoverageScope({this.artist, this.album, this.genre, this.noGenre = false});
  final String? artist, album, genre;
  final bool noGenre;
}

Future<List<String>> missingPaths(AppState s, CoverageScope c) => s.db.incompletePaths(
      artist: c.artist,
      album: c.album,
      genre: c.genre,
      noGenre: c.noGenre,
      fetchLyrics: s.options.fetchLyrics,
      lookupMusicBrainz: s.options.lookupMusicBrainz,
      lookupYear: s.options.lookupYear,
    );

/// Wide coverage bar with a "Scan missing" button, for detail pages.
class CoverageSummary extends StatefulWidget {
  const CoverageSummary(this.scope, {super.key});
  final CoverageScope scope;

  @override
  State<CoverageSummary> createState() => _CoverageSummaryState();
}

class _CoverageSummaryState extends State<CoverageSummary> {
  Future<(Coverage, int)>? _future;
  (int, bool, bool, bool, bool)? _key;

  Future<(Coverage, int)> _load(AppState s) async {
    final c = widget.scope;
    final cov = await s.db.coverageOf(
        artist: c.artist, album: c.album, genre: c.genre, noGenre: c.noGenre);
    return (cov, (await missingPaths(s, c)).length);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final key = (
      s.libraryVersion,
      s.scanning,
      s.options.fetchLyrics,
      s.options.lookupMusicBrainz,
      s.options.lookupYear
    );
    if (_key != key) {
      _key = key;
      _future = _load(s);
    }
    return FutureBuilder<(Coverage, int)>(
      future: _future,
      builder: (ctx, snap) {
        final d = snap.data;
        if (d == null) return const SizedBox(height: 40);
        final (cov, missing) = d;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Expanded(child: CoverageBar(cov, wide: true)),
            const SizedBox(width: 12),
            FilledButton.tonalIcon(
              onPressed: s.scanning || missing == 0
                  ? null
                  : () async {
                      final paths = await missingPaths(s, widget.scope);
                      if (ctx.mounted) await scanMissing(ctx, paths);
                    },
              icon: const Icon(Icons.search),
              label: Text('Scan missing ($missing)'),
            ),
          ]),
        );
      },
    );
  }
}

enum CoverageBy { genre, artist, album }

enum _Col { name, songs, tempo, lyrics, year, genre, overall }

class _Row {
  _Row(this.name, this.songs, this.cov, this.scope, this.onOpen, [this.subtitle]);
  final String name;
  final String? subtitle;
  final int songs;
  final Coverage cov;
  final CoverageScope scope;
  final VoidCallback? onOpen;
}

/// Scan coverage table: for every genre, artist or album, how much of it has
/// tempo, lyrics, year and genre data.
class CoverageTab extends StatefulWidget {
  const CoverageTab({super.key});

  @override
  State<CoverageTab> createState() => _CoverageTabState();
}

class _CoverageTabState extends State<CoverageTab> {
  CoverageBy _by = CoverageBy.genre;
  final _filter = TextEditingController();
  bool _onlyIncomplete = false;
  _Col _sort = _Col.songs;
  bool _desc = true;
  Future<List<_Row>>? _future;
  Object? _key;

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  Future<List<_Row>> _load(AppState s) async {
    final f = _filter.text;
    switch (_by) {
      case CoverageBy.genre:
        final list = await s.db.genreSummaries(filter: f);
        final none = await s.db.coverageOf(noGenre: true);
        return [
          for (final g in list)
            _Row(g.name, g.songs, g.coverage, CoverageScope(genre: g.name),
                () => Navigator.push(context,
                    MaterialPageRoute(builder: (_) => GenreDetailScreen(genre: g.name)))),
          if (none.songs > 0 && (f.trim().isEmpty || 'no genre'.contains(f.trim().toLowerCase())))
            _Row('(no genre)', none.songs, none, const CoverageScope(noGenre: true), null),
        ];
      case CoverageBy.artist:
        return [
          for (final a in await s.db.artists(filter: f))
            _Row(a.name, a.songs, a.coverage, CoverageScope(artist: a.name),
                () => openArtist(context, a.name)),
        ];
      case CoverageBy.album:
        return [
          for (final a in await s.db.albums(filter: f))
            _Row(a.album, a.songs, a.coverage,
                CoverageScope(album: a.album, artist: a.artist ?? ''),
                () => openAlbum(context, a.album, a.artist), a.artist),
        ];
    }
  }

  double _value(_Row r, _Col c) => switch (c) {
        _Col.songs => r.songs.toDouble(),
        _Col.tempo => r.cov.bpmShare,
        _Col.lyrics => r.cov.lyricsShare,
        _Col.year => r.cov.yearShare,
        _Col.genre => r.cov.genreShare,
        _Col.overall => r.cov.overall,
        _Col.name => 0,
      };

  List<_Row> _arranged(List<_Row> rows) {
    final list = [
      for (final r in rows)
        if (!_onlyIncomplete || pendingOf(r.cov) > 0) r
    ];
    list.sort((a, b) {
      final c = _sort == _Col.name
          ? a.name.toLowerCase().compareTo(b.name.toLowerCase())
          : _value(a, _sort).compareTo(_value(b, _sort));
      final r = _desc ? -c : c;
      return r != 0 ? r : a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return list;
  }

  void _sortBy(_Col c) => setState(() {
        if (_sort == c) {
          _desc = !_desc;
        } else {
          _sort = c;
          _desc = c != _Col.name;
        }
      });

  Widget _head(_Col c, String label, {double? width}) {
    final on = _sort == c;
    final child = InkWell(
      onTap: () => _sortBy(c),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
          if (on) Icon(_desc ? Icons.arrow_downward : Icons.arrow_upward, size: 14),
        ]),
      ),
    );
    return width == null ? Expanded(child: child) : SizedBox(width: width, child: child);
  }

  static const _numW = 74.0;

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final key = (_by, _filter.text, s.libraryVersion);
    if (_key != key) {
      _key = key;
      _future = _load(s);
    }
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(children: [
        Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          SegmentedButton<CoverageBy>(
            segments: const [
              ButtonSegment(value: CoverageBy.genre, label: Text('Genres')),
              ButtonSegment(value: CoverageBy.artist, label: Text('Artists')),
              ButtonSegment(value: CoverageBy.album, label: Text('Albums')),
            ],
            selected: {_by},
            onSelectionChanged: (v) => setState(() => _by = v.first),
          ),
          SizedBox(
            width: 240,
            child: TextField(
              controller: _filter,
              decoration: const InputDecoration(
                  isDense: true, prefixIcon: Icon(Icons.search), hintText: 'Filter'),
              onChanged: (_) => setState(() {}),
            ),
          ),
          FilterChip(
            label: const Text('Only incomplete'),
            selected: _onlyIncomplete,
            onSelected: (v) => setState(() => _onlyIncomplete = v),
          ),
          const Tooltip(
            message: 'Solid = found. Pale = looked up but nothing found, so a normal scan '
                'will not try again. Hover a bar for exact counts.',
            child: Icon(Icons.info_outline, size: 18),
          ),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          _head(_Col.name, switch (_by) {
            CoverageBy.genre => 'Genre',
            CoverageBy.artist => 'Artist',
            CoverageBy.album => 'Album',
          }),
          _head(_Col.songs, 'Songs', width: 64),
          _head(_Col.tempo, 'Tempo', width: _numW),
          _head(_Col.lyrics, 'Lyrics', width: _numW),
          _head(_Col.year, 'Year', width: _numW),
          _head(_Col.genre, 'Genre', width: _numW),
          _head(_Col.overall, 'Overall', width: _numW),
          const SizedBox(width: 48),
        ]),
        const Divider(height: 1),
        Expanded(
          child: FutureBuilder<List<_Row>>(
            future: _future,
            builder: (ctx, snap) {
              if (snap.hasError) return Center(child: Text('${snap.error}'));
              final data = snap.data;
              if (data == null) return const Center(child: CircularProgressIndicator());
              final rows = _arranged(data);
              if (rows.isEmpty) return const Center(child: Text('Nothing to show'));
              return ListView.builder(
                itemCount: rows.length,
                itemExtent: 52,
                itemBuilder: (_, i) => _line(ctx, s, rows[i]),
              );
            },
          ),
        ),
      ]),
    );
  }

  Widget _pct(Coverage c, int found, int checked) {
    final p = c.songs == 0 ? 0 : (found * 100 / c.songs).round();
    final extra = checked > 0 ? ' +${(checked * 100 / c.songs).round()}' : '';
    return SizedBox(
      width: _numW,
      child: Tooltip(
        message: '$found found, $checked looked up with nothing found, '
            '${(c.songs - found - checked).clamp(0, c.songs)} not checked',
        child: Text('$p%$extra'),
      ),
    );
  }

  Widget _line(BuildContext ctx, AppState s, _Row r) {
    final c = r.cov;
    final pending = pendingOf(c);
    return InkWell(
      onTap: r.onOpen,
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Row(children: [
          Expanded(
            child: Text(
                r.subtitle == null || r.subtitle!.isEmpty ? r.name : '${r.name} · ${r.subtitle}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ),
          SizedBox(width: 64, child: Text('${r.songs}')),
          _pct(c, c.bpm, c.bpmChecked),
          _pct(c, c.lyrics, c.lyricsChecked),
          _pct(c, c.year, c.yearChecked),
          _pct(c, c.genre, c.genreChecked),
          SizedBox(width: _numW, child: Text('${(c.overall * 100).round()}%')),
          SizedBox(
            width: 48,
            child: IconButton(
              tooltip: pending == 0 ? 'Everything has been looked up' : 'Scan missing',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 32, height: 28),
              icon: const Icon(Icons.search),
              onPressed: s.scanning || pending == 0
                  ? null
                  : () async {
                      final paths = await missingPaths(s, r.scope);
                      if (ctx.mounted) await scanMissing(ctx, paths);
                    },
            ),
          ),
        ]),
        const SizedBox(height: 3),
        SizedBox(height: 14, child: CoverageBar(c)),
      ]),
    );
  }
}
