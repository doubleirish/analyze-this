import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/album_health.dart' show albumArtist;
import '../services/app_state.dart';
import '../services/db.dart' show Song;
import '../services/relabel.dart';
import '../services/relabel_controller.dart';

/// Library tools > Relabel: matches albums with MusicBrainz releases and
/// offers reviewed tag fixes (library and MP3 files).
class RelabelView extends StatefulWidget {
  const RelabelView({super.key});
  @override
  State<RelabelView> createState() => _RelabelViewState();
}

class _RelabelViewState extends State<RelabelView> {
  final _filter = TextEditingController();
  bool _writeFiles = true;

  /// Changes the user unticked; changes of low-confidence albums start unticked.
  final _off = <TrackChange>{};
  final _seen = <String>{};
  int _undoable = 0;

  @override
  void initState() {
    super.initState();
    _refreshUndo();
  }

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  RelabelController get _c => context.read<AppState>().relabel;

  Future<void> _refreshUndo() async {
    final n = await _c.undoableCount();
    if (mounted) setState(() => _undoable = n);
  }

  Future<void> _scan() async {
    final songs = await context.read<AppState>().db.allSongs();
    _seen.clear();
    _off.clear();
    await _c.scan(songs, filter: _filter.text);
  }

  void _syncDefaults(RelabelController c) {
    for (final s in c.suggestions) {
      if (_seen.add('${s.key}|${s.release.id}') && !s.high) _off.addAll(s.changes);
    }
  }

  List<TrackChange> _selected(RelabelController c) => [
        for (final s in c.suggestions)
          for (final ch in s.changes)
            if (!_off.contains(ch)) ch
      ];

  Future<void> _apply(List<TrackChange> changes) async {
    final paths = {for (final c in changes) c.path}.length;
    if (_writeFiles) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Change audio files?'),
          content: Text('Tags in up to $paths MP3 files will be rewritten. The previous values are kept so '
              'you can undo the batch. Other formats are changed in the library only.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Apply')),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    final s = context.read<AppState>();
    final r = await s.relabel.apply(changes, writeFiles: _writeFiles);
    await s.refresh();
    await _refreshUndo();
    if (!mounted) return;
    _report('Relabelled', r);
  }

  Future<void> _undo() async {
    final s = context.read<AppState>();
    final r = await s.relabel.undoLast();
    await s.refresh();
    await _refreshUndo();
    if (!mounted) return;
    _report('Restored', r);
  }

  void _report(String verb, RelabelResult r) {
    final msg = '$verb ${r.songs} songs (${r.filesWritten} files'
        '${r.dbOnly > 0 ? ', ${r.dbOnly} library only' : ''})'
        '${r.errors.isEmpty ? '' : '; ${r.errors.length} file errors: ${r.errors.first}'}';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _search(String key, List<Song> songs) async {
    final artist = TextEditingController(text: albumArtist(songs));
    final album = TextEditingController(text: songs.first.album ?? '');
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Search MusicBrainz'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: artist, decoration: const InputDecoration(labelText: 'Artist (may be blank)')),
          TextField(controller: album, decoration: const InputDecoration(labelText: 'Album')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Search')),
        ],
      ),
    );
    final a = artist.text, b = album.text;
    artist.dispose();
    album.dispose();
    if (go != true || !mounted) return;
    _seen.removeWhere((k) => k.startsWith('$key|'));
    await _c.research(key, songs, artist: a, album: b);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.read<AppState>().relabel;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        _syncDefaults(c);
        final p = c.progress;
        final selected = _selected(c);
        return Column(children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              SizedBox(
                width: 220,
                child: TextField(
                  controller: _filter,
                  decoration: const InputDecoration(
                      isDense: true, labelText: 'Only albums/artists containing', border: OutlineInputBorder()),
                  onSubmitted: (_) => c.running ? null : _scan(),
                ),
              ),
              FilledButton.icon(
                  icon: const Icon(Icons.search), label: const Text('Find fixes'), onPressed: c.running ? null : _scan),
              if (c.running) TextButton(onPressed: c.cancel, child: const Text('Cancel')),
              FilterChip(
                  label: const Text('Write tags into MP3 files'),
                  selected: _writeFiles,
                  onSelected: (v) => setState(() => _writeFiles = v)),
              if (selected.isNotEmpty)
                FilledButton.tonalIcon(
                    icon: const Icon(Icons.check),
                    label: Text('Apply ${selected.length} changes'),
                    onPressed: c.running ? null : () => _apply(selected)),
              if (_undoable > 0)
                OutlinedButton.icon(
                    icon: const Icon(Icons.undo),
                    label: Text('Undo last batch ($_undoable songs)'),
                    onPressed: c.running ? null : _undo),
              const Text('Compares albums with MusicBrainz (about 1 album per 4 s). Low-confidence matches start unticked.'),
            ]),
          ),
          if (c.running) LinearProgressIndicator(value: p == null || p.$2 == 0 ? null : p.$1 / p.$2),
          if (c.error != null)
            Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text(c.error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
          if (p != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Text('${p.$1} of ${p.$2} albums checked · ${c.suggestions.length} with fixes · '
                  '${c.upToDate} already correct · ${c.unmatchedAlbums.length} without a match'),
            ),
          Expanded(
            child: ListView(children: [
              for (final s in c.suggestions) _suggestionTile(c, s),
              if (c.unmatchedAlbums.isNotEmpty) const Divider(),
              for (final e in c.unmatchedAlbums.entries)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.help_outline),
                  title: Text(e.value.first.album ?? ''),
                  subtitle: Text('${albumArtist(e.value)} · ${e.value.length} songs · no match'),
                  trailing: TextButton(
                      onPressed: c.running ? null : () => _search(e.key, e.value), child: const Text('Search…')),
                ),
            ]),
          ),
        ]);
      },
    );
  }

  Widget _suggestionTile(RelabelController c, RelabelSuggestion s) {
    final from = s.songs.first.album ?? '';
    final pct = (s.confidence * 100).round();
    return ExpansionTile(
      leading: Icon(s.high ? Icons.verified : Icons.help_outline, color: s.high ? Colors.green : Colors.amber),
      title: Text(from == s.release.title ? from : '$from → ${s.release.title}'),
      subtitle: Text('${s.release.artist} · ${s.matched} of ${s.songs.length} songs matched · '
          '$pct% ${s.high ? 'high' : 'low'} confidence · ${s.changes.length} changes'),
      children: [
        for (final ch in s.changes)
          CheckboxListTile(
            dense: true,
            value: !_off.contains(ch),
            onChanged: (v) => setState(() => v == true ? _off.remove(ch) : _off.add(ch)),
            title: Text('${ch.field}: "${ch.from ?? ''}" → "${ch.to}"'),
            subtitle: Text(ch.path),
          ),
        Align(
          alignment: Alignment.centerRight,
          child: Wrap(children: [
            TextButton(
                onPressed: c.running ? null : () => _search(s.key, s.songs), child: const Text('Search again…')),
            TextButton(
                onPressed: c.running ? null : () => _apply([for (final ch in s.changes) if (!_off.contains(ch)) ch]),
                child: const Text('Apply this album')),
          ]),
        ),
      ],
    );
  }
}
