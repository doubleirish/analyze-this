import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/album_health.dart';
import '../services/album_health_controller.dart';
import '../services/app_state.dart';
import '../services/art_controller.dart';
import 'package:shared_core/shared_core.dart';
import '../services/db.dart';
import '../services/discography.dart';
import '../services/lyric_keywords.dart';
import 'coverage_view.dart';
import 'library_screen.dart';
import 'readiness_view.dart';
import 'mix_add.dart';

void openArtist(BuildContext context, String? name) {
  if (name == null || name.trim().isEmpty) return;
  Navigator.push(context, MaterialPageRoute(builder: (_) => ArtistDetailScreen(name: name)));
}

void openAlbum(BuildContext context, String? album, String? artist) {
  if (album == null || album.trim().isEmpty) return;
  Navigator.push(
      context, MaterialPageRoute(builder: (_) => AlbumDetailScreen(album: album, artist: artist)));
}

/// Artist photo (Deezer, cached on disk), else album art from one of their songs.
class ArtistAvatar extends StatefulWidget {
  const ArtistAvatar({super.key, required this.name, required this.samplePath, required this.size});
  final String name;
  final String samplePath;
  final double size;

  @override
  State<ArtistAvatar> createState() => _ArtistAvatarState();
}

class _ArtistAvatarState extends State<ArtistAvatar> {
  @override
  void initState() {
    super.initState();
    context.read<ArtController>().ensureArtistImage(widget.name);
  }

  @override
  void didUpdateWidget(ArtistAvatar old) {
    super.didUpdateWidget(old);
    if (old.name != widget.name) context.read<ArtController>().ensureArtistImage(widget.name);
  }

  @override
  Widget build(BuildContext context) {
    final key = ArtistArt.keyFor(widget.name);
    final File? f = context.select<ArtController, File?>((s) => s.artistImages[key]);
    final version = context.select<ArtController, int>((s) => s.artistImageVersions[key] ?? 0);
    if (f == null) {
      final busy = context.select<ArtController, bool>((s) => s.artistBusy.contains(key));
      return Tooltip(
        message: 'Click to download artist photo',
        child: InkWell(
          borderRadius: BorderRadius.circular(widget.size / 2),
          onTap: busy
              ? null
              : () async {
                  final s = context.read<ArtController>();
                  final m = ScaffoldMessenger.of(context);
                  final ok = await s.downloadArtistPhoto(widget.name);
                  m.showSnackBar(SnackBar(
                      content: Text(ok ? 'Artist photo downloaded' : 'No artist photo found online')));
                },
          child: Stack(alignment: Alignment.center, children: [
            TrackArt(path: widget.samplePath, size: widget.size),
            if (busy) const CircularProgressIndicator(strokeWidth: 2),
          ]),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.size / 2),
      child: Image.file(f,
          key: ValueKey((f.path, version)),
          width: widget.size,
          height: widget.size,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => TrackArt(path: widget.samplePath, size: widget.size)),
    );
  }
}

enum _ArtistPhotoAction { album, online, reset }

class _ArtistPhotoMenu extends StatelessWidget {
  const _ArtistPhotoMenu({required this.artist, required this.albums});
  final String artist;
  final List<AlbumInfo> albums;

  Future<void> _select(BuildContext context, _ArtistPhotoAction action) async {
    final controller = context.read<ArtController>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      switch (action) {
        case _ArtistPhotoAction.album:
          final album = await showDialog<AlbumInfo>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('Choose an album cover'),
              content: SizedBox(
                width: 540,
                height: 400,
                child: SingleChildScrollView(
                  child: Wrap(spacing: 8, runSpacing: 8, children: [
                    for (final a in albums)
                      SizedBox(
                        width: 160,
                        child: _card(ctx,
                          image: TrackArt(path: a.samplePath, size: 130),
                          title: a.album,
                          subtitle: 'Use as artist photo',
                          onTap: () => Navigator.pop(ctx, a)),
                      ),
                  ]),
                ),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              ],
            ),
          );
          if (album == null) return;
          await controller.useAlbumCoverAsArtistPhoto(artist, album.samplePath);
        case _ArtistPhotoAction.online:
          await controller.randomOnlineArtistPhoto(artist);
        case _ArtistPhotoAction.reset:
          await controller.resetArtistPhoto(artist);
      }
      messenger.showSnackBar(SnackBar(content: Text(
          action == _ArtistPhotoAction.reset ? 'Artist photo reset to automatic' : 'Artist photo updated')));
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('Could not update artist photo: $error')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final busy = context.select<ArtController, bool>(
        (s) => s.artistBusy.contains(ArtistArt.keyFor(artist)));
    return PopupMenuButton<_ArtistPhotoAction>(
      enabled: !busy,
      tooltip: 'Change artist photo',
      icon: busy
          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.edit),
      onSelected: (action) => _select(context, action),
      itemBuilder: (_) => [
        PopupMenuItem(
          value: _ArtistPhotoAction.album,
          enabled: albums.isNotEmpty,
          child: const Text('Use an album cover...')),
        const PopupMenuItem(
          value: _ArtistPhotoAction.online, child: Text('Try another online photo')),
        const PopupMenuItem(
          value: _ArtistPhotoAction.reset, child: Text('Reset to automatic photo')),
      ],
    );
  }
}

/// Re-runs [load] whenever the library changes (ratings, favourites, scans...).
class _Loader<T> extends StatefulWidget {
  const _Loader({super.key, required this.load, required this.builder});
  final Future<T> Function(AppState s) load;
  final Widget Function(BuildContext, T) builder;

  @override
  State<_Loader<T>> createState() => _LoaderState<T>();
}

class _LoaderState<T> extends State<_Loader<T>> {
  Future<T>? _future;
  int _version = -1;

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    if (_future == null || _version != s.libraryVersion) {
      _version = s.libraryVersion;
      _future = widget.load(s);
    }
    return FutureBuilder<T>(
      future: _future,
      builder: (ctx, snap) => snap.hasData
          ? widget.builder(ctx, snap.data as T)
          : Center(
              child: snap.hasError
                  ? Text('${snap.error}')
                  : const CircularProgressIndicator()),
    );
  }
}

Widget _card(BuildContext context,
    {required Widget image,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    VoidCallback? onLongPress,
    VoidCallback? onPlay,
    Coverage? coverage}) {
  final body = InkWell(
    onTap: onTap,
    onLongPress: onLongPress,
    onSecondaryTap: onLongPress,
    borderRadius: BorderRadius.circular(8),
    child: Padding(
      padding: const EdgeInsets.all(8),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        image,
        const SizedBox(height: 6),
        Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center),
        Text(subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall),
        if (coverage != null && coverage.songs > 0) ...[
          const SizedBox(height: 4),
          CoverageBar(coverage),
        ],
      ]),
    ),
  );
  if (onPlay == null) return body;
  return Stack(children: [
    Positioned.fill(child: body),
    Positioned(
      top: 10,
      right: 10,
      child: IconButton.filled(
        tooltip: 'Play',
        iconSize: 20,
        visualDensity: VisualDensity.compact,
        icon: const Icon(Icons.play_arrow),
        onPressed: onPlay,
      ),
    ),
  ]);
}

/// Songs of one album in track (file name) order. Files sharing a leading track
/// number (duplicate rips) collapse to the largest one.
List<Song> _byFile(Iterable<Song> songs) {
  final sorted = [...songs]
    ..sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
  final best = <String, Song>{};
  final out = <Song>[];
  for (final s in sorted) {
    final m = RegExp(r'^(\d{1,3})\s*[-._ ]').firstMatch(baseName(s.path));
    if (m == null) {
      out.add(s);
      continue;
    }
    final k = int.parse(m.group(1)!).toString();
    final prev = best[k];
    if (prev == null) {
      best[k] = s;
      out.add(s);
    } else if (s.size > prev.size) {
      out[out.indexOf(prev)] = s;
      best[k] = s;
    }
  }
  return out;
}

Future<void> playAlbum(AppState s, String album, String? artist, {bool shuffle = false}) async {
  final songs = await s.db.albumSongs(album, artist);
  s.playSongList(_isBestOf(album, artist) ? songs : _byFile(songs), shuffle: shuffle);
}

/// All of an artist's songs, album by album.
List<Song> _artistOrder(Iterable<Song> songs) => [...songs]
  ..sort((a, b) {
    final c = (a.album ?? '').toLowerCase().compareTo((b.album ?? '').toLowerCase());
    return c != 0 ? c : a.path.toLowerCase().compareTo(b.path.toLowerCase());
  });

Future<void> playArtist(AppState s, String name, {bool shuffle = false}) async => s.playSongList(
    _artistOrder(await s.db
        .search(SongQuery(artist: name, exactNames: true, limit: 5000, sort: SongSort.title))),
    shuffle: shuffle);

const _grid = SliverGridDelegateWithMaxCrossAxisExtent(
    maxCrossAxisExtent: 180, mainAxisExtent: 230, crossAxisSpacing: 4, mainAxisSpacing: 4);

/// Bulk art download button; shows progress while it runs and a result snackbar.
class _ArtButton extends StatelessWidget {
  const _ArtButton({required this.label, required this.run});
  final String label;
  final Future<String> Function(AppState s) run;

  @override
  Widget build(BuildContext context) {
    final art = context.watch<ArtController>();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: OutlinedButton.icon(
        icon: const Icon(Icons.image_search),
        label: Text(art.artProgress ?? label),
        onPressed: art.artProgress != null
            ? null
            : () async {
                final m = ScaffoldMessenger.of(context);
                final msg = await run(context.read<AppState>());
                m.showSnackBar(SnackBar(content: Text(msg)));
              },
      ),
    );
  }
}

class _BrowseControls extends StatelessWidget {
  const _BrowseControls();

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    return Wrap(spacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
      SegmentedButton<bool>(
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(value: true, label: Text('Most songs')),
          ButtonSegment(value: false, label: Text('Name')),
        ],
        selected: {s.browseBySongs},
        onSelectionChanged: (v) => s.setBrowse(bySongs: v.first),
      ),
      const Text('Hide with'),
      DropdownButton<int>(
        value: s.hideUpTo,
        items: const [
          DropdownMenuItem(value: 0, child: Text('none hidden')),
          DropdownMenuItem(value: 1, child: Text('1 song or fewer')),
          DropdownMenuItem(value: 2, child: Text('2 songs or fewer')),
        ],
        onChanged: (v) => v == null ? null : s.setBrowse(hide: v),
      ),
    ]);
  }
}

class ArtistsTab extends StatefulWidget {
  const ArtistsTab({super.key});

  @override
  State<ArtistsTab> createState() => _ArtistsTabState();
}

class _ArtistsTabState extends State<ArtistsTab> {
  final _filter = TextEditingController();

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(12),
        child: Column(children: [
          Row(children: [
            SizedBox(
              width: 280,
              child: TextField(
                controller: _filter,
                decoration: const InputDecoration(
                    labelText: 'Find an artist', isDense: true, prefixIcon: Icon(Icons.search)),
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: 16),
            const Expanded(child: _BrowseControls()),
            _ArtButton(
                label: 'Download missing artist photos',
                run: (s) async {
                  final list = await s.db.artists(
                      filter: _filter.text, bySongs: s.browseBySongs, hideUpTo: s.hideUpTo);
                  final n = await s.artwork.downloadMissingArtistPhotos([for (final a in list) a.name]);
                  return '$n artist photo${n == 1 ? '' : 's'} downloaded';
                }),
            const Text('Long-press = set genre'),
            IconButton(
                tooltip: 'Import genre file',
                icon: const Icon(Icons.file_open),
                onPressed: () => _importGenres(context)),
            IconButton(
                tooltip: 'Export genre file',
                icon: const Icon(Icons.save_alt),
                onPressed: () => _exportGenres(context)),
          ]),
          const SizedBox(height: 8),
          Expanded(
            child: _Loader<List<ArtistInfo>>(
              key: ValueKey('${_filter.text}|${context.watch<AppState>().browseBySongs}|${context.watch<AppState>().hideUpTo}'),
              load: (s) => s.db.artists(
                  filter: _filter.text, bySongs: s.browseBySongs, hideUpTo: s.hideUpTo),
              builder: (ctx, list) => list.isEmpty
                  ? const Center(child: Text('No artists yet. Scan some folders first.'))
                  : GridView.builder(
                      gridDelegate: _grid,
                      itemCount: list.length,
                      itemBuilder: (_, i) {
                        final a = list[i];
                        return _card(ctx,
                            image: ArtistAvatar(name: a.name, samplePath: a.samplePath, size: 130),
                            title: a.name,
                            subtitle:
                                '${a.songs} song${a.songs == 1 ? '' : 's'} · ${a.albums} album${a.albums == 1 ? '' : 's'}',
                            coverage: a.coverage,
                            onTap: () => openArtist(ctx, a.name),
                            onPlay: () => playArtist(ctx.read<AppState>(), a.name),
                            onLongPress: () => _editGenre(ctx, artist: a.name));
                      }),
            ),
          ),
        ]),
      );
}

class AlbumsTab extends StatefulWidget {
  const AlbumsTab({super.key});

  @override
  State<AlbumsTab> createState() => _AlbumsTabState();
}

class _AlbumsTabState extends State<AlbumsTab> {
  final _filter = TextEditingController();

  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      if (mounted) context.read<AppState>().health.ensureHealth();
    });
  }

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(12),
        child: Column(children: [
          Row(children: [
            SizedBox(
              width: 280,
              child: TextField(
                controller: _filter,
                decoration: const InputDecoration(
                    labelText: 'Find an album', isDense: true, prefixIcon: Icon(Icons.search)),
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: 16),
            const Expanded(child: _BrowseControls()),
            _ArtButton(
                label: 'Download missing album art',
                run: (s) async {
                  final list = await _albumsWithBestOf(s, _filter.text);
                  final n = await s.artwork.downloadMissingAlbumArt([for (final a in list) a.samplePath]);
                  return '$n album cover${n == 1 ? '' : 's'} downloaded';
                }),
            const _BestOfButton(),
          ]),
          const SizedBox(height: 8),
          Expanded(
            child: _Loader<List<AlbumInfo>>(
              key: ValueKey('${_filter.text}|${context.watch<AppState>().browseBySongs}|${context.watch<AppState>().hideUpTo}|${context.select<AppState, bool>((s) => s.bestOfProgress == null)}'),
              load: (s) => _albumsWithBestOf(s, _filter.text),
              builder: (ctx, list) => list.isEmpty
                  ? const Center(child: Text('No albums yet. Scan some folders first.'))
                  : GridView.builder(
                      gridDelegate: _grid,
                      itemCount: list.length,
                      itemBuilder: (_, i) => _albumCard(ctx, list[i]),
                    ),
            ),
          ),
        ]),
      );
}

/// Builds the synthetic "Best of" albums for the biggest artists.
class _BestOfButton extends StatelessWidget {
  const _BestOfButton();

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final busy = s.bestOfProgress != null;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      OutlinedButton.icon(
        icon: const Icon(Icons.star_outline),
        label: Text(s.bestOfProgress ?? 'Build Best of albums'),
        onPressed: busy
            ? null
            : () async {
                final m = ScaffoldMessenger.of(context);
                final n = await s.buildBestOfs();
                m.showSnackBar(SnackBar(
                    content: Text(n == 0
                        ? 'No Best of albums built (offline or cancelled?)'
                        : 'Built $n Best of albums, ranked by Deezer popularity')));
              },
      ),
      if (busy) TextButton(onPressed: s.cancelBestOf, child: const Text('Cancel')),
    ]);
  }
}

/// Warning icon for an album whose files look damaged, duplicated or incomplete
/// (see the Album health tool); empty when it looks fine or hasn't been checked.
class _HealthBadge extends StatelessWidget {
  const _HealthBadge({required this.paths, this.size = 20});
  final List<String> paths;
  final double size;

  @override
  Widget build(BuildContext context) {
    final h = context.select<AlbumHealthController, AlbumHealth?>((s) {
      for (final p in paths) {
        final x = s.healthFor(p);
        if (x != null) return x;
      }
      return null;
    });
    if (h == null) return const SizedBox.shrink();
    final err = h.worst == HealthSeverity.error;
    final msgs = h.issues.map((i) => i.message).toList();
    return Tooltip(
      message: [...msgs.take(6), if (msgs.length > 6) '…and ${msgs.length - 6} more'].join('\n'),
      child: Container(
        decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
        padding: const EdgeInsets.all(2),
        child: Icon(err ? Icons.error : Icons.warning_amber,
            size: size, color: err ? Colors.redAccent : Colors.amber),
      ),
    );
  }
}

bool _isBestOf(String album, String? artist) => artist != null && album == bestOfTitle(artist);

Future<List<AlbumInfo>> _albumsWithBestOf(AppState s, String filter) async => [
      ...await s.db.bestOfAlbums(filter: filter),
      ...await s.db.albums(filter: filter, bySongs: s.browseBySongs, hideUpTo: s.hideUpTo),
    ];

Widget _albumCard(BuildContext ctx, AlbumInfo a) {
  final best = _isBestOf(a.album, a.artist);
  return _card(ctx,
      image: Stack(children: [
        TrackArt(path: a.samplePath, size: 130, downloadable: true),
        if (best)
          const Positioned(
              top: 2,
              left: 2,
              child: Tooltip(
                  message: 'Best of: this artist\'s most popular songs',
                  child: Icon(Icons.star, color: Colors.amber, size: 22)))
        else
          Positioned(top: 2, left: 2, child: _HealthBadge(paths: [a.samplePath])),
      ]),
      title: a.album,
      subtitle: [if (a.artist != null) a.artist!, '${a.songs}'].join(' · '),
      coverage: a.coverage,
      onTap: () => openAlbum(ctx, a.album, a.artist),
      onPlay: () => playAlbum(ctx.read<AppState>(), a.album, a.artist),
      onLongPress: a.artist == null || best ? null : () => _editGenre(ctx, album: a));
}

/// Long-press (or right-click) a card to set its genre. Song genres win over
/// the album's, and the album's over the artist's.
Future<void> _editGenre(BuildContext ctx, {String? artist, AlbumInfo? album}) async {
  final s = ctx.read<AppState>();
  final name = artist ?? album!.artist!;
  final c = TextEditingController(text: artist != null ? await s.db.artistGenre(artist) ?? '' : '');
  if (!ctx.mounted) return;
  final ok = await showDialog<bool>(
    context: ctx,
    builder: (d) => AlertDialog(
      title: Text(artist != null ? 'Genre for $name' : 'Genre for ${album!.album}'),
      content: TextField(
          controller: c,
          autofocus: true,
          decoration: InputDecoration(
              labelText: 'Genre (empty clears)',
              helperText: artist != null
                  ? 'Used for songs with no genre of their own or from their album'
                  : 'Used for this album\'s songs with no genre of their own')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Save')),
      ],
    ),
  );
  if (ok == true) {
    artist != null
        ? await s.setArtistGenre(artist, c.text)
        : await s.setAlbumGenre(name, album!.album, c.text);
  }
}

Future<void> _importGenres(BuildContext ctx) async {
  final s = ctx.read<AppState>();
  final m = ScaffoldMessenger.of(ctx);
  final r = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['json']);
  final p = r.single.path;
  if (p == null) return;
  try {
    m.showSnackBar(SnackBar(content: Text('Imported ${await s.importGenreFile(p)} genre entries')));
  } catch (e) {
    m.showSnackBar(SnackBar(content: Text('Not a valid genre file: $e')));
  }
}

Future<void> _exportGenres(BuildContext ctx) async {
  final s = ctx.read<AppState>();
  final m = ScaffoldMessenger.of(ctx);
  final saved = await FilePicker.saveFile(
    dialogTitle: 'Export genre file',
    fileName: 'genres.json',
    bytes: Uint8List.fromList(utf8.encode(await s.db.exportGenreFile())),
    type: FileType.custom,
    allowedExtensions: ['json'],
  );
  if (saved != null) m.showSnackBar(SnackBar(content: Text('Saved $saved')));
}

class _SongList extends StatelessWidget {
  const _SongList(this.songs);
  final List<Song> songs;

  @override
  Widget build(BuildContext context) =>
      Column(children: [for (final s in songs) SongTile(song: s)]);
}

String _bpmRange(Iterable<Song> songs) {
  final b = [for (final s in songs) if (s.medianBpm != null) s.medianBpm!];
  if (b.isEmpty) return 'no BPM data';
  b.sort();
  return '${b.first.round()}–${b.last.round()} BPM';
}

class _ArtistData {
  _ArtistData(this.songs, this.albums, this.keywords, this.mixes);
  final List<Song> songs;
  final List<AlbumInfo> albums;
  final List<MapEntry<String, int>> keywords;
  final int mixes;
}

class ArtistDetailScreen extends StatefulWidget {
  const ArtistDetailScreen({super.key, required this.name});
  final String name;

  @override
  State<ArtistDetailScreen> createState() => _ArtistDetailScreenState();
}

class _ArtistDetailScreenState extends State<ArtistDetailScreen> {
  String _keyword = '';
  bool _showMinor = false;
  int _rev = 0;

  Future<_ArtistData> _load(AppState s) async {
    final songs = await s.db.search(
        SongQuery(artist: widget.name, exactNames: true, limit: 5000, sort: SongSort.title));
    final albums = sortArtistAlbums([
      ...await s.db.bestOfAlbums(artist: widget.name),
      ...await s.db.albums(artist: widget.name),
    ]);
    final lyrics = await s.db.lyricsOfArtist(widget.name);
    final inMixes = <String>{};
    for (final m in s.mixer.savedMixes) {
      inMixes.addAll(await s.db.mixPaths(m.id));
    }
    return _ArtistData(
        songs, albums, topKeywords(lyrics), songs.where((x) => inMixes.contains(x.path)).length);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppState>();
    return Scaffold(
      appBar: AppBar(title: Text(widget.name)),
      body: _Loader<_ArtistData>(
        key: ValueKey(_rev),
        load: _load,
        builder: (ctx, d) {
          final mainAlbums = d.albums.where((a) => !a.isMinor).toList();
          final minorAlbums = d.albums.where((a) => a.isMinor).toList();
          final shown = _keyword.isEmpty
              ? d.songs
              : [
                  for (final x in d.songs)
                    if ((x.lyrics ?? '').toLowerCase().contains(_keyword)) x
                ];
          return ListView(padding: const EdgeInsets.all(12), children: [
            Row(children: [
              Column(mainAxisSize: MainAxisSize.min, children: [
                ArtistAvatar(
                    name: widget.name,
                    samplePath: d.songs.isEmpty ? '' : d.songs.first.path,
                    size: 120),
                _ArtistPhotoMenu(artist: widget.name, albums: d.albums),
              ]),
              const SizedBox(width: 16),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(widget.name, style: Theme.of(ctx).textTheme.headlineSmall),
                  Text('${d.songs.length} songs · ${d.albums.length} albums · ${_bpmRange(d.songs)}'),
                  Text('${d.mixes} of them used in saved mixes'),
                  const SizedBox(height: 8),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    FilledButton.icon(
                      onPressed:
                          d.songs.isEmpty ? null : () => s.playSongList(_artistOrder(shown)),
                      icon: const Icon(Icons.play_arrow),
                      label: Text(_keyword.isEmpty ? 'Play all' : 'Play these ${shown.length}'),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: d.songs.isEmpty
                          ? null
                          : () => s.playSongList(_artistOrder(shown), shuffle: true),
                      icon: const Icon(Icons.shuffle),
                      label: const Text('Shuffle'),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: d.songs.isEmpty
                          ? null
                          : () => addAllToMixOrWarn(context, s.mixer, shown),
                      icon: const Icon(Icons.playlist_add),
                      label: Text(_keyword.isEmpty ? 'Add all to mix' : 'Add these ${shown.length} to mix'),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: d.songs.isEmpty
                          ? null
                          : () async {
                              await s.scanSongs([for (final x in d.songs) x.path]);
                              if (mounted) setState(() => _rev++);
                            },
                      icon: const Icon(Icons.graphic_eq),
                      label: Text('Analyze all (${d.songs.length})'),
                    ),
                  ]),
                  CoverageSummary(CoverageScope(artist: widget.name)),
                  const _ScanStatus(),
                ]),
              ),
            ]),
            if (mainAlbums.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text('Albums (${mainAlbums.length})',
                  style: Theme.of(ctx).textTheme.titleMedium),
              _albumGrid(ctx, mainAlbums),
            ],
            if (minorAlbums.isNotEmpty) ...[
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: () => setState(() => _showMinor = !_showMinor),
                icon: Icon(_showMinor ? Icons.expand_less : Icons.expand_more),
                label: Text('Singles & EPs (${minorAlbums.length})'),
              ),
              if (_showMinor) _albumGrid(ctx, minorAlbums),
            ],
            if (d.songs.length >= 3)
              _MissingAlbums(artist: widget.name, owned: [for (final a in d.albums) a.album]),
            if (d.keywords.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('Lyric themes (tap a word to see those songs)',
                  style: Theme.of(ctx).textTheme.titleMedium),
              Wrap(spacing: 6, children: [
                for (final k in d.keywords)
                  FilterChip(
                    label: Text('${k.key} ${k.value}'),
                    selected: _keyword == k.key,
                    onSelected: (on) => setState(() => _keyword = on ? k.key : ''),
                  ),
              ]),
            ],
            const SizedBox(height: 8),
            Text('Songs (${shown.length})', style: Theme.of(ctx).textTheme.titleMedium),
            _SongList(shown),
          ]);
        },
      ),
    );
  }
}

Widget _albumGrid(BuildContext context, List<AlbumInfo> albums) => Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final album in albums)
          SizedBox(width: 170, height: 230, child: _albumCard(context, album)),
      ],
    );

/// Progress and cancel for a running scan (shown under the Analyze all button).
class _ScanStatus extends StatelessWidget {
  const _ScanStatus();

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final p = s.progress;
    if (!s.scanning) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            LinearProgressIndicator(
                value: p == null || p.total == 0 ? null : p.done / p.total),
            const SizedBox(height: 2),
            Text(p == null
                ? 'Scanning…'
                : 'Analyzing ${p.done}/${p.total}${p.current.isEmpty ? '' : ' · ${p.current}'}'
                    '${p.onlineTotal > 0 ? ' · online ${p.onlineDone}/${p.onlineTotal}' : ''}'),
          ]),
        ),
        TextButton(onPressed: s.cancelScan, child: const Text('Cancel')),
      ]),
    );
  }
}

/// Releases from Deezer that the library lacks, with covers.
class _MissingAlbums extends StatefulWidget {
  const _MissingAlbums({required this.artist, required this.owned});
  final String artist;
  final List<String> owned;

  @override
  State<_MissingAlbums> createState() => _MissingAlbumsState();
}

class _MissingAlbumsState extends State<_MissingAlbums> {
  late Future<List<AlbumRelease>?> _future = _load();
  bool _showMinor = false;

  Future<List<AlbumRelease>?> _load() =>
      context.read<AppState>().missingAlbumsFor(widget.artist, widget.owned);

  @override
  Widget build(BuildContext context) {
    final title = Theme.of(context).textTheme.titleMedium;
    return FutureBuilder<List<AlbumRelease>?>(
      future: _future,
      builder: (ctx, snap) {
        Widget body;
        if (snap.connectionState != ConnectionState.done) {
          body = const Padding(padding: EdgeInsets.all(8), child: LinearProgressIndicator());
        } else if (snap.hasError) {
          body = Row(children: [
            const Text('Couldn\'t reach Deezer. '),
            TextButton(onPressed: () => setState(() => _future = _load()), child: const Text('Retry')),
          ]);
        } else if (snap.data == null) {
          body = const Text('No matching artist found on Deezer.');
        } else if (snap.data!.isEmpty) {
          body = const Text('No missing albums or EPs.');
        } else {
          final list = [...snap.data!]..sort((a, b) {
            if (a.date != b.date) {
              if (a.date == null) return 1;
              if (b.date == null) return -1;
              return b.date!.compareTo(a.date!);
            }
            return a.title.toLowerCase().compareTo(b.title.toLowerCase());
          });
          Widget row(List<AlbumRelease> items) => Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final r in items)
                    SizedBox(
                      width: 170,
                      child: _card(ctx,
                          image: _MissingCover(artist: widget.artist, release: r),
                          title: r.title,
                          subtitle: [if (r.year != null) '${r.year}', r.type.toUpperCase()].join(' · '),
                          onTap: () {}),
                    ),
                ],
              );
          bool minor(AlbumRelease r) => ['ep', 'single'].contains(r.type.toLowerCase());
          final eps = list.where(minor).toList();
          final lps = list.where((r) => !minor(r)).toList();
          body = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (lps.isNotEmpty) row(lps),
            if (eps.isNotEmpty) ...[
              TextButton.icon(
                onPressed: () => setState(() => _showMinor = !_showMinor),
                icon: Icon(_showMinor ? Icons.expand_less : Icons.expand_more),
                label: Text('Missing singles & EPs (${eps.length})'),
              ),
              if (_showMinor) row(eps),
            ],
          ]);
        }
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const SizedBox(height: 16),
          Text(snap.data == null ? 'Missing albums' : 'Missing albums (${snap.data!.length}, newest first)',
              style: title),
          body,
        ]);
      },
    );
  }
}

class _MissingCover extends StatelessWidget {
  const _MissingCover({required this.artist, required this.release});
  final String artist;
  final AlbumRelease release;

  @override
  Widget build(BuildContext context) => FutureBuilder<File?>(
        future: context.read<AppState>().missingAlbumCover(artist, release),
        builder: (_, snap) => ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: snap.data == null
              ? const SizedBox(width: 130, height: 130, child: Icon(Icons.album, size: 64))
              : Image.file(snap.data!,
                  width: 130, height: 130, fit: BoxFit.cover, cacheWidth: 260),
        ),
      );
}

class AlbumDetailScreen extends StatelessWidget {
  const AlbumDetailScreen({super.key, required this.album, this.artist});
  final String album;
  final String? artist;

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppState>();
    return Scaffold(
      appBar: AppBar(title: Text(album)),
      body: _Loader<List<Song>>(
        load: (s) => s.db.albumSongs(album, artist),
        builder: (ctx, songs) {
          final best = _isBestOf(album, artist);
          Future.microtask(s.health.ensureHealth);
          return ListView(padding: const EdgeInsets.all(12), children: [
          Row(children: [
            TrackArt(path: songs.isEmpty ? '' : songs.first.path, size: 140, downloadable: true),
            const SizedBox(width: 16),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Flexible(child: Text(album, style: Theme.of(ctx).textTheme.headlineSmall)),
                  const SizedBox(width: 8),
                  if (best)
                    const Icon(Icons.star, color: Colors.amber, size: 24)
                  else
                    _HealthBadge(paths: [for (final x in songs) x.path], size: 24),
                ]),
                if (artist != null)
                  TextButton(onPressed: () => openArtist(ctx, artist), child: Text(artist!)),
                Text([
                  '${songs.length} songs',
                  if (songs.any((x) => x.year != null))
                    '${songs.map((x) => x.year).whereType<int>().reduce((a, b) => a < b ? a : b)}',
                  _bpmRange(songs),
                ].join(' · ')),
                const SizedBox(height: 8),
                Wrap(spacing: 8, children: [
                  FilledButton.icon(
                    onPressed: songs.isEmpty
                        ? null
                        : () => s.playSongList(best ? songs : _byFile(songs)),
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Play album'),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: songs.isEmpty
                        ? null
                        : () => s.playSongList(best ? songs : _byFile(songs), shuffle: true),
                    icon: const Icon(Icons.shuffle),
                    label: const Text('Shuffle'),
                  ),
                  FilledButton.icon(
                  onPressed: songs.isEmpty
                      ? null
                      : () => addAllToMixOrWarn(context, s.mixer, songs),
                  icon: const Icon(Icons.playlist_add),
                  label: const Text('Add all to mix'),
                ),
                ]),
                CoverageSummary(CoverageScope(album: album, artist: artist ?? '')),
                const _ScanStatus(),
              ]),
            ),
          ]),
          const SizedBox(height: 8),
          _SongList(songs),
        ]);
        },
      ),
    );
  }
}

/// "More like this": songs close in tempo, genre, decade or artist.
Future<void> showSimilar(BuildContext context, Song song) async {
  final s = context.read<AppState>();
  final songs = await s.similarTo(song);
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Like: ${song.display}'),
      content: SizedBox(
        width: 480,
        child: songs.isEmpty
            ? const Text('Nothing similar found')
            : ListView(shrinkWrap: true, children: [
                for (final c in songs)
                  ListTile(
                    dense: true,
                    leading: TrackArt(path: c.path, size: 36),
                    title: Text(c.display),
                    subtitle: Text([
                      '${c.medianBpm?.round() ?? '-'} BPM',
                      if (c.genre != null) c.genre!,
                      if (c.year != null) '${c.year}',
                    ].join('  |  ')),
                    trailing: IconButton(
                      tooltip: 'Add to mix',
                      icon: const Icon(Icons.playlist_add),
                      onPressed: () {
                        if (addToMixOrWarn(context, s.mixer, c)) Navigator.pop(ctx);
                      },
                    ),
                  ),
              ]),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
    ),
  );
}

String _date(int? ms) {
  if (ms == null) return 'date unknown';
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

Future<void> showMixUsage(BuildContext context, Song song) async {
  final s = context.read<AppState>();
  final mixes = await s.db.mixesUsing(song.path);
  final taught = await s.db.taughtDates(song.path);
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Mixes with ${song.display}'),
      content: SizedBox(
        width: 360,
        child: ListView(shrinkWrap: true, children: [
          if (mixes.isEmpty) const Text('Not used in any saved mix yet'),
          for (final m in mixes)
            ListTile(dense: true, title: Text(m.name), subtitle: Text('saved ${_date(m.savedAt)}')),
          const Divider(),
          Text(taught.isEmpty ? 'Never taught in a logged class' : 'Taught in class',
              style: Theme.of(ctx).textTheme.titleSmall),
          for (final d in taught)
            ListTile(dense: true, leading: const Icon(Icons.event), title: Text(_date(d.millisecondsSinceEpoch))),
        ]),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
    ),
  );
}

class _Insights {
  _Insights(this.stats, this.gaps);
  final LibraryStats stats;
  final List<AlbumInfo> gaps;
}

/// Library stats and discography gaps.
class InsightsScreen extends StatelessWidget {
  const InsightsScreen({super.key});

  Widget _bars(BuildContext ctx, String title, Map<String, int> data) {
    final max = data.values.fold(1, (a, b) => a > b ? a : b);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 4),
        child: Text(title, style: Theme.of(ctx).textTheme.titleMedium),
      ),
      for (final e in data.entries)
        Row(children: [
          SizedBox(width: 90, child: Text(e.key)),
          Expanded(child: LinearProgressIndicator(value: e.value / max, minHeight: 10)),
          SizedBox(width: 50, child: Text('  ${e.value}')),
        ]),
    ]);
  }

  @override
  Widget build(BuildContext context) => DefaultTabController(
        length: 4,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('Library insights'),
            bottom: const TabBar(tabs: [
              Tab(text: 'Stats'),
              Tab(text: 'Discography gaps'),
              Tab(text: 'Program readiness'),
              Tab(text: 'Scan coverage'),
            ]),
          ),
          body: _Loader<_Insights>(
            load: (s) async => _Insights(await s.db.stats(), await s.db.discographyGaps()),
            builder: (ctx, d) {
              final st = d.stats;
              String pct(int n) => st.total == 0 ? '-' : '${(n * 100 / st.total).round()}%';
              return TabBarView(children: [
                ListView(padding: const EdgeInsets.all(16), children: [
                  Text('${st.total} songs · ${st.favourites} favourites'),
                  Text('BPM known: ${st.withBpm} (${pct(st.withBpm)})   '
                      'Lyrics: ${st.withLyrics} (${pct(st.withLyrics)})   '
                      'Genre: ${st.withGenre} (${pct(st.withGenre)})'),
                  _bars(ctx, 'Tempo (BPM)',
                      {for (final e in st.bpmBuckets.entries) '${e.key}–${e.key + 9}': e.value}),
                  _bars(ctx, 'Decades', {for (final e in st.decades.entries) '${e.key}s': e.value}),
                  _bars(ctx, 'Top genres', {for (final g in st.genres) g.key: g.value}),
                ]),
                d.gaps.isEmpty
                    ? const Center(child: Text('Every album has 3 or more songs'))
                    : ListView(children: [
                        const Padding(
                          padding: EdgeInsets.all(12),
                          child: Text('Albums where you only have one or two songs'),
                        ),
                        for (final a in d.gaps)
                          ListTile(
                            leading: TrackArt(path: a.samplePath, size: 40),
                            title: Text(a.album),
                            subtitle: Text('${a.artist ?? 'Unknown artist'} · ${a.songs} song${a.songs == 1 ? '' : 's'}'),
                            onTap: () => openAlbum(ctx, a.album, a.artist),
                          ),
                      ]),
                const ProgramReadinessView(),
                const CoverageTab(),
              ]);
            },
          ),
        ),
      );
}


/// Genres tab: pick a genre to discover its artists and albums.
class GenresTab extends StatefulWidget {
  const GenresTab({super.key});

  @override
  State<GenresTab> createState() => _GenresTabState();
}

class _GenresTabState extends State<GenresTab> {
  final _filter = TextEditingController();

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(12),
        child: Column(children: [
          Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(
              width: 280,
              child: TextField(
                controller: _filter,
                decoration: const InputDecoration(
                    labelText: 'Find a genre', isDense: true, prefixIcon: Icon(Icons.search)),
                onChanged: (_) => setState(() {}),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _Loader<List<GenreInfo>>(
              key: ValueKey(_filter.text),
              load: (s) => s.db.genreSummaries(filter: _filter.text),
              builder: (ctx, list) => list.isEmpty
                  ? const Center(child: Text('No genres yet. Scan with genre lookup enabled.'))
                  : GridView.builder(
                      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 300,
                          mainAxisExtent: 170,
                          crossAxisSpacing: 8,
                          mainAxisSpacing: 8),
                      itemCount: list.length,
                      itemBuilder: (_, i) {
                        final g = list[i];
                        return _GenreTile(
                          genre: g,
                          onTap: () => Navigator.push(
                              ctx,
                              MaterialPageRoute(
                                  builder: (_) => GenreDetailScreen(genre: g.name))),
                        );
                      }),
            ),
          ),
        ]),
      );
}

/// A stable gradient for a genre name.
List<Color> genreColors(String name) {
  final h = name.toLowerCase().codeUnits.fold<int>(7, (a, c) => (a * 31 + c) & 0xffff) % 360;
  return [
    HSLColor.fromAHSL(1, h.toDouble(), 0.55, 0.32).toColor(),
    HSLColor.fromAHSL(1, ((h + 40) % 360).toDouble(), 0.6, 0.18).toColor(),
  ];
}

IconData genreIcon(String name) {
  final n = name.toLowerCase();
  const map = <String, IconData>{
    'rock': Icons.electric_bolt,
    'metal': Icons.whatshot,
    'punk': Icons.bolt,
    'pop': Icons.star,
    'jazz': Icons.piano,
    'blues': Icons.nightlife,
    'classical': Icons.library_music,
    'country': Icons.landscape,
    'folk': Icons.park,
    'hip': Icons.mic,
    'rap': Icons.mic,
    'r&b': Icons.favorite,
    'soul': Icons.favorite,
    'electronic': Icons.graphic_eq,
    'edm': Icons.graphic_eq,
    'house': Icons.graphic_eq,
    'techno': Icons.graphic_eq,
    'dance': Icons.graphic_eq,
    'reggae': Icons.beach_access,
    'soundtrack': Icons.movie,
    'latin': Icons.celebration,
    'ambient': Icons.cloud,
    'indie': Icons.headphones,
    'alternative': Icons.headphones,
  };
  for (final e in map.entries) {
    if (n.contains(e.key)) return e.value;
  }
  return Icons.music_note;
}

class _GenreTile extends StatelessWidget {
  const _GenreTile({required this.genre, required this.onTap});
  final GenreInfo genre;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Stack(fit: StackFit.expand, children: [
        DecoratedBox(
          decoration: BoxDecoration(
              gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: genreColors(genre.name))),
        ),
        Positioned(
          right: -10,
          top: -10,
          child: Icon(genreIcon(genre.name), size: 120, color: Colors.white24),
        ),
        Positioned.fill(child: _CoverMosaic(paths: genre.samples)),
        const Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
                gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Colors.black87])),
          ),
        ),
        Positioned.fill(
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      _OutlinedText(genre.name,
                          style: style.titleLarge!.copyWith(fontWeight: FontWeight.bold)),
                      _OutlinedText('${genre.artists} artists · ${genre.albums} albums',
                          style: style.bodyMedium!),
                      _OutlinedText('${genre.songs} songs', style: style.bodyMedium!),
                      if (genre.coverage.songs > 0) ...[
                        const SizedBox(height: 4),
                        CoverageBar(genre.coverage, color: Colors.white),
                      ],
                    ]),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

/// White text with a black outline and soft shadow, readable on any image.
class _OutlinedText extends StatelessWidget {
  const _OutlinedText(this.text, {required this.style});
  final String text;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final fontSize = style.fontSize ?? 14;
    return Stack(children: [
      Text(text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: style.copyWith(
              foreground: Paint()
                ..style = PaintingStyle.stroke
                ..strokeWidth = fontSize / 4
                ..strokeJoin = StrokeJoin.round
                ..color = Colors.black,
              shadows: const [Shadow(blurRadius: 6, color: Colors.black87)])),
      Text(text,
          maxLines: 1, overflow: TextOverflow.ellipsis, style: style.copyWith(color: Colors.white)),
    ]);
  }
}

/// Full-tile collage of covers (only those that have art) from the genre's albums.
class _CoverMosaic extends StatefulWidget {
  const _CoverMosaic({required this.paths});
  final List<String> paths;

  @override
  State<_CoverMosaic> createState() => _CoverMosaicState();
}

class _CoverMosaicState extends State<_CoverMosaic> {
  @override
  void initState() {
    super.initState();
    final s = context.read<AppState>();
    for (final p in widget.paths) {
      s.ensureMedia(p);
    }
  }

  @override
  Widget build(BuildContext context) {
    final media = context.select<AppState, List<File>>(
        (s) => [for (final p in widget.paths) if (s.media[p]?.art != null) s.media[p]!.art!]);
    if (media.isEmpty) return const SizedBox.shrink();
    return Opacity(
      opacity: 0.85,
      child: Row(children: [
        for (final f in media)
          Expanded(
            child: Image.file(f,
                key: ValueKey(f.path),
                height: double.infinity,
                fit: BoxFit.cover,
                cacheWidth: 300,
                errorBuilder: (_, _, _) => const SizedBox.shrink()),
          ),
      ]),
    );
  }
}

class GenreDetailScreen extends StatelessWidget {
  const GenreDetailScreen({super.key, required this.genre});
  final String genre;

  @override
  Widget build(BuildContext context) => DefaultTabController(
        length: 2,
        child: Scaffold(
          appBar: AppBar(
            title: Text(genre),
            flexibleSpace: DecoratedBox(
                decoration: BoxDecoration(
                    gradient: LinearGradient(colors: genreColors(genre)))),
            actions: [
              IconButton(
                tooltip: 'Play a random song from this genre',
                icon: const Icon(Icons.shuffle),
                onPressed: () async {
                  final s = context.read<AppState>();
                  final r = await s.db.search(SongQuery(
                      genre: genre, sort: SongSort.random, limit: 1));
                  if (r.isNotEmpty) await s.play(r.first.path);
                },
              ),
            ],
            bottom: const TabBar(tabs: [Tab(text: 'Artists'), Tab(text: 'Albums')]),
          ),
          body: Column(children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Column(children: [
                CoverageSummary(CoverageScope(genre: genre)),
                const _ScanStatus(),
              ]),
            ),
            Expanded(child: TabBarView(children: [
            _Loader<List<ArtistInfo>>(
              load: (s) => s.db.artists(genre: genre),
              builder: (ctx, list) => GridView.builder(
                padding: const EdgeInsets.all(12),
                gridDelegate: _grid,
                itemCount: list.length,
                itemBuilder: (_, i) {
                  final a = list[i];
                  return _card(ctx,
                      image: ArtistAvatar(name: a.name, samplePath: a.samplePath, size: 130),
                      title: a.name,
                      subtitle: '${a.songs} song${a.songs == 1 ? '' : 's'}',
                      coverage: a.coverage,
                      onTap: () => openArtist(ctx, a.name),
                      onPlay: () => playArtist(ctx.read<AppState>(), a.name));
                },
              ),
            ),
            _Loader<List<AlbumInfo>>(
              load: (s) => s.db.albums(genre: genre, bySongs: true),
              builder: (ctx, list) => list.isEmpty
                  ? const Center(child: Text('No albums in this genre'))
                  : GridView.builder(
                      padding: const EdgeInsets.all(12),
                      gridDelegate: _grid,
                      itemCount: list.length,
                      itemBuilder: (_, i) => _albumCard(ctx, list[i]),
                    ),
            ),
          ])),
          ]),
        ),
      );
}
