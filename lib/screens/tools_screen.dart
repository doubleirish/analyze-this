import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_core/shared_core.dart' show measureLoudness;

import '../services/album_health.dart';
import '../services/album_health_controller.dart';
import '../services/app_state.dart';
import '../services/backup.dart';
import '../services/damage_scan.dart';
import '../services/db.dart';
import '../services/library_tools.dart';
import '../services/share.dart';
import '../services/usb_sync.dart';
import 'browse_screens.dart' show openAlbum;
import 'mix_add.dart';
import 'send_dialog.dart';

class ToolsScreen extends StatelessWidget {
  const ToolsScreen({super.key});

  @override
  Widget build(BuildContext context) => DefaultTabController(
        length: 9,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('Library tools'),
            bottom: const TabBar(isScrollable: true, tabs: [
              Tab(icon: Icon(Icons.auto_fix_high), text: 'Tidy tags'),
              Tab(icon: Icon(Icons.drive_file_move), text: 'Organize files'),
              Tab(icon: Icon(Icons.link_off), text: 'Missing files'),
              Tab(icon: Icon(Icons.health_and_safety), text: 'Album health'),
              Tab(icon: Icon(Icons.broken_image_outlined), text: 'Damaged audio'),
              Tab(icon: Icon(Icons.history), text: 'Listening'),
              Tab(icon: Icon(Icons.share), text: 'Share'),
              Tab(icon: Icon(Icons.graphic_eq), text: 'Loudness'),
              Tab(icon: Icon(Icons.backup), text: 'Backup'),
            ]),
          ),
          body: const TabBarView(children: [
            _TidyTab(),
            _OrganizeTab(),
            _MissingTab(),
            _HealthTab(),
            _DamageTab(),
            _ListeningTab(),
            _ShareTab(),
            _LoudnessTab(),
            _BackupTab(),
          ]),
        ),
      );
}

class _DamageTab extends StatefulWidget {
  const _DamageTab();
  @override
  State<_DamageTab> createState() => _DamageTabState();
}

class _DamageTabState extends State<_DamageTab> {
  bool _recheck = false;

  Future<void> _run(bool deep) async {
    try {
      await context.read<DamageScanController>().scan(deep: deep, recheck: _recheck);
    } on StateError catch (e) {
      if (mounted) _snack(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = context.watch<DamageScanController>();
    final p = d.progress;
    final theme = Theme.of(context);
    return Column(children: [
      Padding(
        padding: const EdgeInsets.all(12),
        child: Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          FilledButton.icon(
              icon: const Icon(Icons.search),
              label: const Text('Quick check'),
              onPressed: d.running ? null : () => _run(false)),
          FilledButton.tonalIcon(
              icon: const Icon(Icons.graphic_eq),
              label: const Text('Deep check (ffmpeg)'),
              onPressed: d.running ? null : () => _run(true)),
          if (d.running) TextButton(onPressed: d.cancel, child: const Text('Stop')),
          FilterChip(
              label: const Text('Re-check unchanged files'),
              selected: _recheck,
              onSelected: d.running ? null : (v) => setState(() => _recheck = v)),
          const Text('Quick reads each file\'s structure (also done when scanning). '
              'Deep decodes every song: slow, but catches more.'),
        ]),
      ),
      if (d.running) LinearProgressIndicator(value: p == null || p.$2 == 0 ? null : p.$1 / p.$2),
      if (d.running && p != null)
        Padding(padding: const EdgeInsets.all(4), child: Text('${p.$1} / ${p.$2}')),
      if (d.lastResult != null)
        Padding(padding: const EdgeInsets.all(4), child: Text(d.lastResult!)),
      Expanded(
        child: d.damaged.isEmpty
            ? const Center(child: Text('No damaged songs'))
            : ListView(children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: Text(
                      '${d.damaged.length} damaged song${d.damaged.length == 1 ? '' : 's'}: '
                      'kept out of new mixes. Open a mix to replace them.',
                      style: theme.textTheme.titleSmall),
                ),
                for (final (s, h) in d.damaged)
                  ListTile(
                    dense: true,
                    leading: Icon(Icons.broken_image_outlined, color: theme.colorScheme.error),
                    title: Text(s.display),
                    subtitle: Text([
                      h?.reason ?? 'tagged damaged',
                      if (h?.depth != null) '${h!.depth} check ${_ago(h.checkedAt)}',
                      s.path,
                    ].join('\n')),
                    isThreeLine: true,
                    trailing: TextButton(
                        onPressed: () => d.markOk(s.path),
                        child: const Tooltip(
                            message: 'It plays fine: untag it and don\'t flag it again unless the file changes',
                            child: Text('Plays fine'))),
                  ),
              ]),
      ),
    ]);
  }
}

void _snack(BuildContext c, String m) =>
    ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(m)));

class _TidyTab extends StatefulWidget {
  const _TidyTab();
  @override
  State<_TidyTab> createState() => _TidyTabState();
}

class _TidyTabState extends State<_TidyTab> {
  List<TagFix>? _fixes;
  final _skip = <TagFix>{};

  Future<void> _scan() async {
    final songs = await context.read<AppState>().db.allSongs();
    if (!mounted) return;
    setState(() {
      _fixes = planTagCleanup(songs);
      _skip.clear();
    });
  }

  Future<void> _apply() async {
    final s = context.read<AppState>();
    final todo = [for (final f in _fixes!) if (!_skip.contains(f)) f];
    final n = await applyTagFixes(s.db, todo);
    await s.refresh();
    if (!mounted) return;
    _snack(context, 'Updated $n songs');
    await _scan();
  }

  @override
  Widget build(BuildContext context) {
    final fixes = _fixes;
    return Column(children: [
      Padding(
        padding: const EdgeInsets.all(12),
        child: Row(children: [
          FilledButton.icon(
              icon: const Icon(Icons.search), label: const Text('Find fixes'), onPressed: _scan),
          const SizedBox(width: 12),
          if (fixes != null && fixes.isNotEmpty)
            FilledButton.tonalIcon(
                icon: const Icon(Icons.check),
                label: Text('Apply ${fixes.length - _skip.length} fixes'),
                onPressed: fixes.length == _skip.length ? null : _apply),
          const SizedBox(width: 12),
          const Expanded(
              child: Text('Merges spelling/case variants, "Beatles, The", "ft." → "feat.", '
                  'lowercase names. Remembered across rescans; files are not modified.')),
        ]),
      ),
      Expanded(
        child: fixes == null
            ? const SizedBox.shrink()
            : fixes.isEmpty
                ? const Center(child: Text('Nothing to tidy'))
                : ListView(children: [
                    for (final f in fixes)
                      CheckboxListTile(
                        dense: true,
                        value: !_skip.contains(f),
                        onChanged: (v) => setState(() => v == true ? _skip.remove(f) : _skip.add(f)),
                        title: Text('${f.field}: "${f.from}" → "${f.to}"'),
                        subtitle: Text('${f.paths.length} songs'),
                      ),
                  ]),
      ),
    ]);
  }
}

class _OrganizeTab extends StatefulWidget {
  const _OrganizeTab();
  @override
  State<_OrganizeTab> createState() => _OrganizeTabState();
}

class _OrganizeTabState extends State<_OrganizeTab> {
  final _pattern = TextEditingController(text: defaultPattern);
  String? _root;
  OrganizePlan? _plan;
  int _undoable = 0;

  @override
  void initState() {
    super.initState();
    _refreshUndo();
  }

  @override
  void dispose() {
    _pattern.dispose();
    super.dispose();
  }

  Future<void> _refreshUndo() async {
    final n = await Organizer(context.read<AppState>().db).undoableCount();
    if (mounted) setState(() => _undoable = n);
  }

  Future<void> _preview() async {
    final s = context.read<AppState>();
    final root = _root ?? (s.folders.isEmpty ? null : s.folders.first);
    if (root == null) return;
    final songs = await s.db.allSongs();
    setState(() {
      _root = root;
      _plan = planOrganize(songs, root, pattern: _pattern.text);
    });
  }

  Future<void> _apply() async {
    final s = context.read<AppState>();
    final done = await Organizer(s.db).apply(_plan!.moves);
    await s.refresh();
    if (!mounted) return;
    _snack(context, 'Moved ${done.length} of ${_plan!.moves.length} files');
    setState(() => _plan = null);
    await _refreshUndo();
  }

  Future<void> _undo() async {
    final s = context.read<AppState>();
    final n = await Organizer(s.db).undo();
    await s.refresh();
    if (!mounted) return;
    _snack(context, 'Moved $n files back');
    await _refreshUndo();
  }

  @override
  Widget build(BuildContext context) {
    final plan = _plan;
    final s = context.read<AppState>();
    return Column(children: [
      Padding(
        padding: const EdgeInsets.all(12),
        child: Column(children: [
          Row(children: [
            Expanded(
              child: TextField(
                controller: _pattern,
                decoration: const InputDecoration(
                    labelText: 'Pattern',
                    helperText: 'Tokens: {artist} {album} {year} {title} {filename}; "/" makes folders'),
              ),
            ),
            const SizedBox(width: 12),
            DropdownButton<String>(
              value: s.folders.contains(_root) ? _root : null,
              hint: const Text('Destination folder'),
              items: [for (final f in s.folders) DropdownMenuItem(value: f, child: Text(f))],
              onChanged: (v) => setState(() {
                _root = v;
                _plan = null;
              }),
            ),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            FilledButton.icon(
                icon: const Icon(Icons.preview), label: const Text('Preview'), onPressed: _preview),
            const SizedBox(width: 12),
            if (plan != null && plan.moves.isNotEmpty)
              FilledButton.tonalIcon(
                  icon: const Icon(Icons.drive_file_move),
                  label: Text('Move ${plan.moves.length} files'),
                  onPressed: _apply),
            const Spacer(),
            TextButton.icon(
                icon: const Icon(Icons.undo),
                label: Text('Undo last move ($_undoable)'),
                onPressed: _undoable == 0 ? null : _undo),
          ]),
        ]),
      ),
      if (plan != null && plan.skipped.isNotEmpty)
        Text('${plan.skipped.length} songs skipped (target exists or name clash)'),
      Expanded(
        child: plan == null
            ? const SizedBox.shrink()
            : plan.moves.isEmpty
                ? const Center(child: Text('Everything is already organized'))
                : ListView(children: [
                    for (final m in plan.moves.take(500))
                      ListTile(dense: true, title: Text(m.from), subtitle: Text('→ ${m.to}')),
                  ]),
      ),
    ]);
  }
}

class _MissingTab extends StatefulWidget {
  const _MissingTab();
  @override
  State<_MissingTab> createState() => _MissingTabState();
}

class _MissingTabState extends State<_MissingTab> {
  List<Song>? _missing;
  bool _busy = false;

  Future<void> _check() async {
    setState(() => _busy = true);
    final m = await findMissing(await context.read<AppState>().db.allSongs());
    if (mounted) {
      setState(() {
        _missing = m;
        _busy = false;
      });
    }
  }

  Future<void> _removeAll() async {
    final s = context.read<AppState>();
    await s.db.deleteSongs([for (final x in _missing!) x.path]);
    await s.refresh();
    if (mounted) await _check();
  }

  @override
  Widget build(BuildContext context) {
    final m = _missing;
    return Column(children: [
      Padding(
        padding: const EdgeInsets.all(12),
        child: Row(children: [
          FilledButton.icon(
              icon: const Icon(Icons.search),
              label: const Text('Check for missing files'),
              onPressed: _busy ? null : _check),
          const SizedBox(width: 12),
          if (m != null && m.isNotEmpty)
            FilledButton.tonalIcon(
                icon: const Icon(Icons.delete_sweep),
                label: Text('Remove ${m.length} from library'),
                onPressed: _removeAll),
          const SizedBox(width: 12),
          const Expanded(
              child: Text('If files were moved, rescan their folder first; '
                  'ratings and tags of removed songs are lost.')),
        ]),
      ),
      if (_busy) const LinearProgressIndicator(),
      Expanded(
        child: m == null
            ? const SizedBox.shrink()
            : m.isEmpty
                ? const Center(child: Text('All files exist'))
                : ListView(children: [
                    for (final x in m) ListTile(dense: true, title: Text(x.display), subtitle: Text(x.path)),
                  ]),
      ),
    ]);
  }
}

class _HealthTab extends StatefulWidget {
  const _HealthTab();
  @override
  State<_HealthTab> createState() => _HealthTabState();
}

class _HealthTabState extends State<_HealthTab> {
  bool _online = false;
  bool _ran = false;

  Future<void> _run() async {
    final s = context.read<AlbumHealthController>();
    setState(() => _ran = true);
    await s.checkHealth(online: _online);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AlbumHealthController>();
    final list = s.albumHealth;
    final p = s.healthProgress;
    final theme = Theme.of(context);
    return Column(children: [
      Padding(
        padding: const EdgeInsets.all(12),
        child: Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          FilledButton.icon(
              icon: const Icon(Icons.health_and_safety),
              label: const Text('Check albums'),
              onPressed: s.healthRunning ? null : _run),
          if (s.healthRunning)
            TextButton(onPressed: s.cancelHealth, child: const Text('Cancel')),
          FilterChip(
              label: const Text('Also compare with Deezer track counts'),
              selected: _online,
              onSelected: s.healthRunning ? null : (v) => setState(() => _online = v)),
          const Text('Looks for missing or duplicate tracks and files with odd size or length.'),
        ]),
      ),
      if (s.healthRunning)
        LinearProgressIndicator(value: p == null || p.$2 == 0 ? null : p.$1 / p.$2),
      Expanded(
        child: !_ran && list.isEmpty
            ? const SizedBox.shrink()
            : list.isEmpty && !s.healthRunning
                ? const Center(child: Text('No problems found'))
                : ListView(children: [
                    for (final a in list)
                      ExpansionTile(
                        leading: Icon(
                            a.worst == HealthSeverity.error ? Icons.error : Icons.warning_amber,
                            color: a.worst == HealthSeverity.error
                                ? theme.colorScheme.error
                                : Colors.amber),
                        title: Text(a.album),
                        subtitle: Text(
                            '${a.artist.isEmpty ? 'Unknown artist' : a.artist} · ${a.songs.length} songs · '
                            '${a.issues.length} issue${a.issues.length == 1 ? '' : 's'}'),
                        children: [
                          for (final i in a.issues)
                            ListTile(
                              dense: true,
                              leading: Icon(switch (i.kind) {
                                HealthKind.missing => Icons.playlist_remove,
                                HealthKind.duplicate => Icons.content_copy,
                                HealthKind.file => Icons.broken_image_outlined,
                              }, size: 20),
                              title: Text(i.message),
                              subtitle: i.paths.length == 1 ? Text(i.paths.first) : null,
                            ),
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton(
                                onPressed: () =>
                                    openAlbum(context, a.album, a.artist.isEmpty || a.artist == 'Various artists' ? null : a.artist),
                                child: const Text('Open album')),
                          ),
                        ],
                      ),
                  ]),
      ),
    ]);
  }
}

String _ago(int? ms) {
  if (ms == null) return 'never';
  final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms));
  if (d.inDays >= 1) return '${d.inDays}d ago';
  if (d.inHours >= 1) return '${d.inHours}h ago';
  return '${d.inMinutes}m ago';
}

class _ListeningData {
  _ListeningData(this.top, this.skipped, this.recent, this.forgotten, this.similar, this.titles);
  final List<PlayStat> top;
  final List<PlayStat> skipped;
  final List<Song> recent;
  final List<Song> forgotten;
  final List<Song> similar;
  final Map<String, Song> titles;
}

class _ListeningTab extends StatefulWidget {
  const _ListeningTab();
  @override
  State<_ListeningTab> createState() => _ListeningTabState();
}

class _ListeningTabState extends State<_ListeningTab> {
  late Future<_ListeningData> _data;
  bool _usbSyncing = false;

  Future<void> _syncUsb() async {
    final s = context.read<AppState>();
    setState(() => _usbSyncing = true);
    try {
      final o = await syncFromUsbPhone(s.db, s.phoneSync());
      if (o.result case final r? when r.plays > 0 || r.ratings > 0) {
        if (r.ratings > 0) await s.refresh();
        if (mounted) setState(() => _data = _load());
      }
      if (mounted) _snack(context, o.message);
    } catch (e) {
      if (mounted) _snack(context, 'USB sync failed: $e');
    } finally {
      if (mounted) setState(() => _usbSyncing = false);
    }
  }

  bool _wifiSyncing = false;

  /// Fetches plays & ratings over Wi-Fi from every paired phone that's
  /// receiving right now (beats-me open).
  Future<void> _syncWifi() async {
    final s = context.read<AppState>();
    final link = s.phones;
    if (link.paired.isEmpty) {
      _snack(context, 'No paired phone yet. Send a mix to the phone over Wi-Fi once to pair it.');
      return;
    }
    setState(() => _wifiSyncing = true);
    final lines = <String>[];
    var changed = false;
    try {
      await link.discover();
      final online = [for (final c in link.choices) if (c.online && c.paired != null) c];
      if (online.isEmpty) {
        lines.add('No paired phone found. Open beats-me on the phone (same Wi-Fi) and try again.');
      }
      for (final c in online) {
        try {
          final r = await link.syncJournal(c.paired!, via: c.found!.uri);
          if (r == null) continue;
          lines.add('${c.name}: ${r.summary}');
          if (link.lastCatalogSyncNote case final note?) lines.add(note);
          if (r.plays > 0 || r.ratings > 0) changed = true;
          if (r.ratings > 0) await s.refresh();
        } catch (e) {
          lines.add('${c.name}: sync failed ($e)');
        }
      }
      if (changed && mounted) setState(() => _data = _load());
    } finally {
      if (mounted) setState(() => _wifiSyncing = false);
    }
    if (mounted) _snack(context, lines.join('\n'));
  }

  @override
  void initState() {
    super.initState();
    _data = _load();
  }

  Future<_ListeningData> _load() async {
    final s = context.read<AppState>();
    final db = s.db;
    final top = await db.mostPlayed(limit: 25);
    final skipped = await db.mostSkipped(limit: 15);
    final titles = <String, Song>{};
    for (final p in [...top, ...skipped]) {
      final song = await db.song(p.path);
      if (song != null) titles[p.path] = song;
    }
    final cur = s.current == null ? null : await db.song(s.current!);
    return _ListeningData(
      top,
      skipped,
      await db.recentlyPlayed(limit: 25),
      await db.forgottenFavorites(limit: 25),
      cur == null ? [] : await db.similar(cur, limit: 15),
      titles,
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppState>();
    return FutureBuilder<_ListeningData>(
      future: _data,
      builder: (c, snap) {
        final d = snap.data;
        if (d == null) return const Center(child: CircularProgressIndicator());
        Widget header(String t) => Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text(t, style: Theme.of(c).textTheme.titleMedium));
        Widget songTile(Song x, [String? sub]) => ListTile(
              dense: true,
              title: Text(x.display, overflow: TextOverflow.ellipsis),
              subtitle: sub == null ? null : Text(sub),
              onTap: () => s.play(x.path),
              trailing: IconButton(
                  tooltip: 'Add to mix',
                  icon: const Icon(Icons.playlist_add),
                  onPressed: () => addToMixOrWarn(context, s.mixer, x)),
            );
        return ListView(children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Wrap(children: [
              TextButton.icon(
                  icon: const Icon(Icons.refresh),
                  label: const Text('Refresh'),
                  onPressed: () => setState(() => _data = _load())),
              TextButton.icon(
                  icon: _usbSyncing
                      ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.usb),
                  label: const Text('Sync from phone (USB)'),
                  onPressed: _usbSyncing ? null : _syncUsb),
              TextButton.icon(
                  icon: _wifiSyncing
                      ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.wifi),
                  label: const Text('Sync plays & ratings from phone'),
                  onPressed: _wifiSyncing ? null : _syncWifi),
            ]),
          ),
          header('Similar to the current song (tempo, genre, tags)'),
          if (d.similar.isEmpty) const ListTile(dense: true, title: Text('Play a song to see matches')),
          for (final x in d.similar) songTile(x, x.avgBpm == null ? null : '${x.avgBpm!.round()} BPM'),
          header('Forgotten favorites (not played in 90 days)'),
          if (d.forgotten.isEmpty) const ListTile(dense: true, title: Text('None')),
          for (final x in d.forgotten) songTile(x),
          header('Most played'),
          if (d.top.isEmpty) const ListTile(dense: true, title: Text('No plays recorded yet')),
          for (final p in d.top)
            if (d.titles[p.path] case final x?)
              songTile(x, '${p.plays} plays · ${p.skips} skips · last ${_ago(p.lastPlayed)}'),
          header('Most skipped'),
          for (final p in d.skipped)
            if (d.titles[p.path] case final x?) songTile(x, '${p.skips} skips · ${p.plays} plays'),
          header('Recently played'),
          for (final x in d.recent) songTile(x),
        ]);
      },
    );
  }
}

class _ShareTab extends StatefulWidget {
  const _ShareTab();
  @override
  State<_ShareTab> createState() => _ShareTabState();
}

class _ShareTabState extends State<_ShareTab> {
  Future<void> _run(Future<String> Function() f) async {
    try {
      final m = await f();
      if (mounted) _snack(context, m);
    } catch (e) {
      if (mounted) _snack(context, 'Failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppState>();
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Shared folder: ${shareDir().path}'),
        const SizedBox(height: 4),
        const Text('BPM, waveform and lyrics sidecar files next to each song are already used by both apps. '
            'beats-me also logs what you play there; it is merged into your history here.'),
        const SizedBox(height: 16),
        Wrap(spacing: 12, runSpacing: 12, children: [
          FilledButton.icon(
            icon: const Icon(Icons.album_outlined),
            label: const Text('Send album list to phone'),
            onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => SendToPhoneDialog(state: s, albumsOnly: true)),
          ),
          FilledButton.icon(
            icon: const Icon(Icons.sync),
            label: const Text('Import plays from beats-me'),
            onPressed: () => _run(() async {
              final n = await importSharedPlays(s.db);
              if (n > 0) await s.checkClassSuggestions();
              return 'Imported $n plays';
            }),
          ),
          FilledButton.tonalIcon(
            icon: const Icon(Icons.phone_android),
            label: const Text('Import phone journal file…'),
            onPressed: () => _run(() async {
              final pick = await FilePicker.pickFiles(
                  type: FileType.custom, allowedExtensions: ['jsonl']);
              final path = pick.isEmpty ? null : pick.first.path;
              if (path == null) return 'No journal selected';
              final r = await s.phoneSync().importJournalByDevice(await File(path).readAsString());
              if (r.ratings > 0) await s.refresh();
              return r.summary;
            }),
          ),
          FilledButton.tonalIcon(
            icon: const Icon(Icons.upload),
            label: const Text('Export bundle'),
            onPressed: () => _run(() async => 'Saved ${(await exportBundleTo(s.db)).path}'),
          ),
          FilledButton.tonalIcon(
            icon: const Icon(Icons.download),
            label: const Text('Import bundle'),
            onPressed: () => _run(() async {
              final pick = await FilePicker.pickFiles(
                  type: FileType.custom, allowedExtensions: ['json']);
              final path = pick.isEmpty ? null : pick.first.path;
              final f = path != null ? File(path) : (await bundleFile().exists() ? bundleFile() : null);
              if (f == null) return 'No bundle selected';
              final r = await importBundleFrom(s.db, f);
              await s.refresh();
              return 'Merged ${r.songs} songs, ${r.mixes} mixes, ${r.plays} plays';
            }),
          ),
        ]),
        const SizedBox(height: 8),
        const Text('A bundle holds ratings, favorites, tags, mixes and play history. '
            'Importing merges: higher rating wins, existing mixes are kept.'),
      ]),
    );
  }
}

class _LoudnessTab extends StatefulWidget {
  const _LoudnessTab();
  @override
  State<_LoudnessTab> createState() => _LoudnessTabState();
}

class _LoudnessTabState extends State<_LoudnessTab> {
  int? _todo;
  int _done = 0, _failed = 0;
  bool _busy = false, _stop = false;

  @override
  void initState() {
    super.initState();
    _count();
  }

  Future<void> _count() async {
    final n = (await context.read<AppState>().db.pathsWithoutLoudness()).length;
    if (mounted) setState(() => _todo = n);
  }

  Future<void> _run() async {
    final db = context.read<AppState>().db;
    final paths = await db.pathsWithoutLoudness();
    setState(() {
      _busy = true;
      _stop = false;
      _done = _failed = 0;
      _todo = paths.length;
    });
    for (final path in paths) {
      if (_stop || !mounted) break;
      double? lufs;
      try {
        lufs = await measureLoudness(path);
      } catch (_) {}
      if (lufs != null) {
        await db.setLoudness(path, lufs);
        _done++;
      } else {
        _failed++;
      }
      if (mounted) setState(() {});
    }
    if (mounted) setState(() => _busy = false);
    await _count();
  }

  @override
  Widget build(BuildContext context) {
    final todo = _todo;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('beats-me can even out volume between songs using each song\'s '
            'measured loudness (LUFS). New scans measure it automatically; songs '
            'scanned before this version can be measured here.'),
        const SizedBox(height: 12),
        Text(todo == null ? 'Counting…' : '$todo songs have no loudness yet'),
        const SizedBox(height: 12),
        Row(children: [
          FilledButton.icon(
              icon: const Icon(Icons.graphic_eq),
              label: const Text('Measure loudness'),
              onPressed: _busy || (todo ?? 0) == 0 ? null : _run),
          const SizedBox(width: 12),
          if (_busy) OutlinedButton(onPressed: () => setState(() => _stop = true), child: const Text('Stop')),
        ]),
        if (_busy || _done + _failed > 0) ...[
          const SizedBox(height: 12),
          if (_busy && (todo ?? 0) > 0) LinearProgressIndicator(value: (_done + _failed) / todo!),
          Text('Measured $_done${_failed > 0 ? ', $_failed could not be decoded' : ''}'),
        ],
      ]),
    );
  }
}

class _BackupTab extends StatefulWidget {
  const _BackupTab();
  @override
  State<_BackupTab> createState() => _BackupTabState();
}

class _BackupTabState extends State<_BackupTab> {
  List<BackupInfo>? _list;
  bool _busy = false;

  BackupService get _svc => context.read<AppState>().backups;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final l = await _svc.list();
    if (mounted) setState(() => _list = l);
  }

  void _say(String msg) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  Future<void> _backup() async {
    setState(() => _busy = true);
    try {
      final f = await _svc.create();
      _say('Backed up to ${f.path}');
    } catch (e) {
      _say('Backup failed: $e');
    }
    if (mounted) setState(() => _busy = false);
    await _reload();
  }

  Future<void> _restore(File zip) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Restore library?'),
        content: Text('Replace the whole library (songs, ratings, mixes, programs, '
            'history and settings) with ${zip.uri.pathSegments.last}?\n\n'
            'A backup of the current library is made first. The restore takes '
            'effect the next time analyze-this starts.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Restore')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await _svc.stageRestore(zip);
      _say('Restore ready — close and reopen analyze-this to finish');
    } on FormatException catch (e) {
      _say('Can\'t restore: ${e.message}');
    } catch (e) {
      _say('Restore failed: $e');
    }
    if (mounted) setState(() => _busy = false);
    await _reload();
  }

  Future<void> _pick() async {
    final r = await FilePicker.pickFiles(
        dialogTitle: 'Choose a backup', type: FileType.custom, allowedExtensions: ['zip']);
    final path = r.isEmpty ? null : r.first.path;
    if (path != null) await _restore(File(path));
  }

  @override
  Widget build(BuildContext context) {
    final l = _list;
    final pending = _svc.restorePending;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.all(12),
        child: Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          FilledButton.icon(
              icon: const Icon(Icons.backup), label: const Text('Back up now'), onPressed: _busy ? null : _backup),
          OutlinedButton.icon(
              icon: const Icon(Icons.restore),
              label: const Text('Restore from file…'),
              onPressed: _busy ? null : _pick),
          OutlinedButton.icon(
              icon: const Icon(Icons.folder_open),
              label: const Text('Open folder'),
              onPressed: () async {
                await _svc.dir.create(recursive: true);
                await Process.run('explorer', [_svc.dir.path]);
              }),
          Text('A backup is made automatically each day at startup '
              '(the newest ${BackupService.keepAuto} are kept).'),
        ]),
      ),
      if (pending)
        MaterialBanner(
          content: const Text('A restore is waiting — it happens the next time analyze-this starts.'),
          actions: [
            TextButton(
                onPressed: () async {
                  await _svc.cancelRestore();
                  setState(() {});
                },
                child: const Text('Cancel restore')),
          ],
        ),
      if (_busy) const LinearProgressIndicator(),
      Expanded(
        child: l == null
            ? const SizedBox.shrink()
            : l.isEmpty
                ? const Center(child: Text('No backups yet'))
                : ListView(children: [
                    for (final b in l)
                      ListTile(
                        dense: true,
                        leading: Icon(b.auto ? Icons.schedule : Icons.backup),
                        title: Text(b.name),
                        subtitle: Text('${b.created.toLocal()}'.split('.').first),
                        trailing: TextButton(
                            onPressed: _busy ? null : () => _restore(b.file), child: const Text('Restore')),
                      ),
                  ]),
      ),
    ]);
  }
}