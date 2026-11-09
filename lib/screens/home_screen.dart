import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../services/app_state.dart';
import '../services/mix_controller.dart';
import '../services/scanner.dart';
import 'library_screen.dart';
import 'browse_screens.dart';
import 'class_history.dart';

import 'package:shared_core/shared_core.dart';

import 'mix_screen.dart';
import 'tools_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 6,
    child: _SongsTabOnRequest(
      child: HomeShortcuts(
        child: Scaffold(
          appBar: AppBar(
            title: const Text('analyze-this'),
            actions: [
              IconButton(
                tooltip: 'Library tools: tidy tags, organize files, history, sharing',
                icon: const Icon(Icons.build),
                onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ToolsScreen())),
              ),
              IconButton(
                tooltip: 'Library insights: stats, discography gaps and program readiness',
                icon: const Icon(Icons.insights),
                onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const InsightsScreen())),
              ),
            ],
            bottom: const TabBar(
              tabs: [
                Tooltip(
                  message: 'Ctrl+1',
                  child: Tab(icon: Icon(Icons.folder_open), text: 'Folders'),
                ),
                Tooltip(
                  message: 'Ctrl+2 · Ctrl+F to search',
                  child: Tab(icon: Icon(Icons.search), text: 'Songs'),
                ),
                Tooltip(
                  message: 'Ctrl+3',
                  child: Tab(icon: Icon(Icons.person), text: 'Artists'),
                ),
                Tooltip(
                  message: 'Ctrl+4',
                  child: Tab(icon: Icon(Icons.album), text: 'Albums'),
                ),
                Tooltip(
                  message: 'Ctrl+5',
                  child: Tab(icon: Icon(Icons.category), text: 'Genres'),
                ),
                Tooltip(
                  message: 'Ctrl+6',
                  child: Tab(icon: Icon(Icons.queue_music), text: 'Mix'),
                ),
              ],
            ),
          ),
          bottomNavigationBar: const MiniPlayer(),
          body: const Column(
            children: [
              ClassSuggestionBanner(),
              Expanded(
                child: TabBarView(
                  children: [FoldersTab(), LibraryTab(), ArtistsTab(), AlbumsTab(), GenresTab(), MixTab()],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Switches to the Songs tab whenever [AppState.showInSongs] is called.
class _SongsTabOnRequest extends StatefulWidget {
  const _SongsTabOnRequest({required this.child});
  final Widget child;

  @override
  State<_SongsTabOnRequest> createState() => _SongsTabOnRequestState();
}

class _SongsTabOnRequestState extends State<_SongsTabOnRequest> {
  late final AppState _state;
  late int _seen;

  @override
  void initState() {
    super.initState();
    _state = context.read<AppState>()..addListener(_check);
    _seen = _state.songsRequestSeq;
  }

  void _check() {
    if (_state.songsRequestSeq == _seen || !mounted) return;
    _seen = _state.songsRequestSeq;
    DefaultTabController.of(context).animateTo(1);
  }

  @override
  void dispose() {
    _state.removeListener(_check);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Desktop keyboard shortcuts for the main window (below the tab controller):
/// Space play/pause, Ctrl+Z undo, Ctrl+Y / Ctrl+Shift+Z redo, Ctrl+S save
/// the mix, Ctrl+F search songs, Ctrl+1…6 switch tabs. While a text field
/// has focus, Space and undo/redo are left to the text field.
class HomeShortcuts extends StatelessWidget {
  const HomeShortcuts({super.key, required this.child});
  final Widget child;

  static bool get _typing {
    final ctx = FocusManager.instance.primaryFocus?.context;
    return ctx != null && (ctx.widget is EditableText || ctx.findAncestorWidgetOfExactType<EditableText>() != null);
  }

  static const _digits = [
    LogicalKeyboardKey.digit1,
    LogicalKeyboardKey.digit2,
    LogicalKeyboardKey.digit3,
    LogicalKeyboardKey.digit4,
    LogicalKeyboardKey.digit5,
    LogicalKeyboardKey.digit6,
  ];

  KeyEventResult _onKey(BuildContext context, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    final k = e.logicalKey;
    if (keys.isAltPressed || keys.isMetaPressed) return KeyEventResult.ignored;
    final mixer = context.read<MixController>();
    if (keys.isControlPressed) {
      if (k == LogicalKeyboardKey.keyZ || k == LogicalKeyboardKey.keyY) {
        if (_typing) return KeyEventResult.ignored;
        if (k == LogicalKeyboardKey.keyY || keys.isShiftPressed) {
          mixer.redo();
        } else {
          mixer.undo();
        }
        return KeyEventResult.handled;
      }
      if (e is! KeyDownEvent) return KeyEventResult.ignored;
      if (k == LogicalKeyboardKey.keyS) {
        if (mixer.mix.isNotEmpty) unawaited(mixer.saveMix());
        return KeyEventResult.handled;
      }
      final tabs = DefaultTabController.of(context);
      if (k == LogicalKeyboardKey.keyF) {
        tabs.animateTo(1);
        WidgetsBinding.instance.addPostFrameCallback((_) => LibraryTab.searchFocus.requestFocus());
        return KeyEventResult.handled;
      }
      final tab = _digits.indexOf(k);
      if (tab >= 0) {
        tabs.animateTo(tab);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (k == LogicalKeyboardKey.space && !keys.isShiftPressed && !_typing) {
      if (e is KeyDownEvent) {
        final p = context.read<PlaybackController>();
        if (p.current != null) unawaited(p.player.playing ? p.player.pause() : p.player.play());
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) => Focus(autofocus: true, onKeyEvent: (_, e) => _onKey(context, e), child: child);
}

/// "2h 05m", "3m 12s", "45s"; "estimating…" when unknown.
String _fmtEta(Duration? d) {
  if (d == null) return 'estimating…';
  final s = d.inSeconds;
  if (s >= 3600) return '${s ~/ 3600}h ${((s % 3600) ~/ 60).toString().padLeft(2, '0')}m';
  if (s >= 60) return '${s ~/ 60}m ${(s % 60).toString().padLeft(2, '0')}s';
  return '${s}s';
}

class _OpLine extends StatelessWidget {
  const _OpLine(this.label, this.unit, this.op);
  final String label;
  final String unit;
  final OpStat op;

  @override
  Widget build(BuildContext context) {
    if (op.total == 0) return const SizedBox.shrink();
    final rate = op.perSec <= 0
        ? '–'
        : op.perSec >= 1
        ? '${op.perSec.toStringAsFixed(1)} $unit/s'
        : '${(op.perSec * 60).toStringAsFixed(1)} $unit/min';
    return Row(
      children: [
        SizedBox(width: 100, child: Text(label)),
        Expanded(child: LinearProgressIndicator(value: (op.done / op.total).clamp(0.0, 1.0))),
        const SizedBox(width: 8),
        SizedBox(
          width: 340,
          child: Text(
            '${op.done}/${op.total}  ·  $rate  ·  ETA ${_fmtEta(op.eta)}',
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.fade,
          ),
        ),
      ],
    );
  }
}

class FoldersTab extends StatelessWidget {
  const FoldersTab({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final pr = s.progress;
    final o = s.options;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              FilledButton.icon(
                icon: const Icon(Icons.create_new_folder),
                label: const Text('Add folder'),
                onPressed: () async {
                  final dir = await FilePicker.getDirectoryPath();
                  if (dir != null) await s.addFolder(dir);
                },
              ),
              const SizedBox(width: 12),
              FilledButton.tonalIcon(
                icon: const Icon(Icons.bolt),
                label: const Text('Quick scan (tags only)'),
                onPressed: s.scanning || s.folders.isEmpty ? null : s.quickScan,
              ),
              const SizedBox(width: 12),
              FilledButton.tonalIcon(
                icon: const Icon(Icons.refresh),
                label: const Text('Full scan'),
                onPressed: s.scanning || s.folders.isEmpty ? null : s.scan,
              ),
              if (s.scanning) ...[
                const SizedBox(width: 12),
                TextButton(onPressed: s.cancelScan, child: const Text('Cancel')),
              ],
              const Spacer(),
              TextButton.icon(
                icon: const Icon(Icons.filter_alt),
                label: const Text('Explicit words'),
                onPressed: () async {
                  final words = await s.explicitWords();
                  if (!context.mounted) return;
                  final c = TextEditingController(text: words.join(', '));
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('Explicit word list'),
                      content: TextField(
                        controller: c,
                        maxLines: 6,
                        decoration: const InputDecoration(
                          helperText: 'Comma separated; songs whose lyrics contain any are flagged',
                        ),
                      ),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
                      ],
                    ),
                  );
                  if (ok == true) {
                    await s.saveExplicitWords([
                      for (final w in c.text.split(','))
                        if (w.trim().isNotEmpty) w.trim(),
                    ]);
                  }
                  c.dispose();
                },
              ),
              const SizedBox(width: 12),
              Text('${s.songCount} songs in database'),
            ],
          ),
          Wrap(
            spacing: 16,
            children: [
              _opt('Analyze missing BPM', o.analyzeBpm, s.scanning, (v) => s.setOptions(o.copyWith(analyzeBpm: v))),
              _opt(
                'Fetch missing lyrics online',
                o.fetchLyrics,
                s.scanning,
                (v) => s.setOptions(o.copyWith(fetchLyrics: v)),
              ),
              _opt(
                'Quick lyrics (LRCLIB + NetEase only)',
                o.quickLyrics,
                s.scanning || !o.fetchLyrics,
                (v) => s.setOptions(o.copyWith(quickLyrics: v)),
              ),
              _opt(
                'Look up genre (Deezer, then MusicBrainz; once per album)',
                o.lookupMusicBrainz,
                s.scanning,
                (v) => s.setOptions(o.copyWith(lookupMusicBrainz: v)),
              ),
              _opt(
                'Also look up missing years (once per album)',
                o.lookupYear,
                s.scanning || !o.lookupMusicBrainz,
                (v) => s.setOptions(o.copyWith(lookupYear: v)),
              ),
              _opt('Check folders for new files on startup', s.scanOnStartup, false, s.setScanOnStartup),
              DropdownButton<String>(
                value: o.localOnly
                    ? 'local'
                    : o.refreshOnline
                    ? 'online'
                    : o.forceFull
                    ? 'verify'
                    : 'normal',
                items: const [
                  DropdownMenuItem(value: 'normal', child: Text('Incremental scan')),
                  DropdownMenuItem(value: 'verify', child: Text('Check all folders (reuse unchanged data)')),
                  DropdownMenuItem(value: 'local', child: Text('Local tempo/tags only (no online lookups)')),
                  DropdownMenuItem(value: 'online', child: Text('Retry missing online data (ignore cooldown)')),
                ],
                onChanged: s.scanning
                    ? null
                    : (mode) {
                        if (mode == null) return;
                        s.setOptions(
                          o.copyWith(
                            forceFull: mode != 'normal',
                            localOnly: mode == 'local',
                            refreshOnline: mode == 'online',
                          ),
                        );
                      },
              ),
              const Text('Failed online lookups wait 30 days before retrying; use retry mode to try sooner.'),
            ],
          ),
          if (s.scanning) ...[
            const SizedBox(height: 8),
            LinearProgressIndicator(value: pr == null || pr.total == 0 ? null : pr.done / pr.total),
            Text(
              [
                if (pr?.currentGenre != null) '[${pr!.currentGenre}]',
                pr?.current.isNotEmpty == true ? pr!.current : 'Starting scan…',
              ].join(' '),
              overflow: TextOverflow.ellipsis,
            ),
            if (pr != null && pr.skippedDirs > 0)
              Text(
                'Skipped ${pr.skippedDirs} finished artist folder${pr.skippedDirs == 1 ? '' : 's'} '
                '(use "Force full rescan" to include them)',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            if (pr != null) ...[
              const SizedBox(height: 4),
              _OpLine('Analyze', 'files', pr.analyze),
              _OpLine('Lyrics', 'songs', pr.lyrics),
              _OpLine('Genre / year', 'lookups', pr.genre),
              Text(
                'Overall ETA: ${pr.etaIsLowerBound ? 'at least ' : ''}${_fmtEta(pr.eta)}'
                '${pr.throttled > 0 ? '  ·  ${pr.throttled} rate-limit responses, slowing down' : ''}',
              ),
            ],
          ],
          const Divider(),
          Expanded(
            child: ListView(
              children: [
                for (final f in s.folders)
                  ListTile(
                    leading: const Icon(Icons.folder),
                    title: Text(f),
                    trailing: IconButton(
                      icon: const Icon(Icons.close),
                      tooltip: 'Remove folder',
                      onPressed: s.scanning ? null : () => s.removeFolder(f),
                    ),
                  ),
                if (s.scanErrors.isNotEmpty) ...[
                  const ListTile(title: Text('Problems during last scan')),
                  for (final e in s.scanErrors.take(50)) ListTile(dense: true, title: Text(e)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _opt(String label, bool v, bool busy, ValueChanged<bool> on) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Checkbox(value: v, onChanged: busy ? null : (b) => on(b ?? false)),
      Text(label),
    ],
  );
}
