import 'dart:convert';
import 'dart:io' show File, Platform, Process;
import 'dart:math' show min;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/activities.dart';
import '../services/app_state.dart';
import '../services/db.dart';
import '../services/m3u_import.dart';
import '../services/mix_controller.dart';
import '../services/planner.dart';

import 'package:shared_core/shared_core.dart';

import 'program_screen.dart';
import 'saved_mixes_screen.dart';
import 'unsaved_guard.dart';
import 'generate_program_dialog.dart';
import 'mix_rotation.dart';
import 'mix_filter_bar.dart';
import 'send_dialog.dart';
import 'send_folder_dialog.dart';
import 'browse_screens.dart';
import 'class_history.dart';
import 'tempo_profile.dart';
import 'mix_add.dart';

class MixTab extends StatefulWidget {
  const MixTab({super.key});

  @override
  State<MixTab> createState() => _MixTabState();
}

class _MixTabState extends State<MixTab> {
  final _name = TextEditingController();
  final _list = ScrollController();

  /// Song picked on the energy graph; highlighted in the list.
  int? _selected;

  @override
  void dispose() {
    _name.dispose();
    _list.dispose();
    super.dispose();
  }

  /// Highlights mix song [i] and scrolls the list to about where it is
  /// (rows vary in height, so by the average row).
  void _select(int i, int count) {
    setState(() => _selected = i);
    if (!_list.hasClients || count == 0) return;
    final pos = _list.position;
    final avg = (pos.maxScrollExtent + pos.viewportDimension) / count;
    final target = (i * avg - pos.viewportDimension / 2 + avg / 2).clamp(0.0, pos.maxScrollExtent);
    _list.animateTo(target, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
  }

  String _fmt(double sec) {
    final s = sec.round();
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  Future<void> _export(MixController s) async {
    final messenger = ScaffoldMessenger.of(context);
    final saved = await FilePicker.saveFile(
      dialogTitle: 'Export mix',
      fileName: '${s.mixName}.m3u8',
      bytes: Uint8List.fromList(utf8.encode(s.mixAsM3u8())),
      type: FileType.custom,
      allowedExtensions: ['m3u8'],
    );
    if (saved == null) return;
    messenger.showSnackBar(
      SnackBar(content: Text('Exported to ${saved.toFilePath()}')),
    );
  }

  Future<void> _exportSheet(MixController s) async {
    final messenger = ScaffoldMessenger.of(context);
    final saved = await FilePicker.saveFile(
      dialogTitle: 'Save class sheet',
      fileName: '${s.mixName}.html',
      bytes: Uint8List.fromList(utf8.encode(s.classSheet())),
      type: FileType.custom,
      allowedExtensions: ['html'],
    );
    if (saved == null) return;
    final path = saved.toFilePath();
    messenger.showSnackBar(
      SnackBar(
        content: Text('Saved $path'),
        action: SnackBarAction(
          label: 'Open in browser',
          onPressed: () => Platform.isWindows
              ? Process.run('cmd', ['/c', 'start', '', path])
              : Process.run(Platform.isMacOS ? 'open' : 'xdg-open', [path]),
        ),
      ),
    );
  }

  /// Second column of the mix list: the song's activity icon, name and RPM.
  Widget _activityCell(BuildContext context, ProgramPart? p) {
    if (p == null) return const SizedBox.shrink();
    return Row(
      children: [
        Icon(iconForKey(roleIconKey(p.kind)), size: 18),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            '${p.name} · ${p.minRpm.round()}–${p.maxRpm.round()} RPM',
            overflow: TextOverflow.ellipsis,
            maxLines: 2,
          ),
        ),
      ],
    );
  }

  ProgramPart? _partOf(MixController s, int i) {
    final pi = i < s.mixPart.length ? s.mixPart[i] : null;
    if (pi == null || pi >= s.program.parts.length) return null;
    return s.program.parts[pi];
  }

  /// Warning text when the song's tempo is outside its part's RPM range
  /// (half and double time count as a match), else null.
  String? _tempoWarning(MixController s, int i, Song song) {
    final p = _partOf(s, i);
    final bpm = song.medianBpm;
    if (p == null || bpm == null || !p.music) return null;
    final jump = min(bpmJump(bpm, p.targetRpm), bpmJump(p.targetRpm, bpm));
    if (jump <= p.rpmTolerance) return null;
    return '${bpm.round()} BPM does not match ${p.minRpm.round()}–${p.maxRpm.round()} RPM for ${p.name}';
  }

  Future<void> _suggestPart(MixController s, int part) {
    final p = s.program.parts[part];
    return showDialog<void>(
      context: context,
      builder: (_) => _SuggestDialog(
        title: '${p.name}: ${p.minRpm.round()}–${p.maxRpm.round()} RPM',
        role: p.kind,
        hint:
            'Filter applies to every ${p.kind.label.toLowerCase()} part, on top of the Mix filter',
        load: () => s.suggestForPart(part),
        onPick: (song) => addToPartOrWarn(context, s, song, part),
      ),
    );
  }

  Future<void> _suggestRole(MixController s, PartRole role) => showDialog<void>(
    context: context,
    builder: (_) => _SuggestDialog(
      title: '${role.label} music',
      role: role,
      hint:
          'Songs at ${role.label.toLowerCase()} tempo; the filter is kept for auto-fill too',
      load: () => s.suggestForRole(role),
      onPick: (song) => addToMixOrWarn(context, s, song),
    ),
  );

  /// Auto-fill with a look at the filters first: the Mix-wide one and one per
  /// kind of part (so warm-up and cool-down can use calmer music).
  Future<void> _fillDialog(MixController s) async {
    if (!await confirmUnsavedMix(context, s, action: 'auto-fill')) return;
    if (!mounted) return;
    final t = s.program;
    final roles = <PartRole>[
      for (final r in PartRole.values)
        if (t.parts.any((p) => p.music && p.kind == r)) r,
    ];
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Auto-fill ${t.name}'),
        content: SizedBox(
          width: 640,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('All parts'),
                const SizedBox(height: 6),
                const MixFilterBar(),
                const Divider(height: 24),
                const Text('Music for particular parts (optional)'),
                for (final r in roles) ...[
                  const SizedBox(height: 10),
                  MixFilterBar(role: r),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Fill'),
          ),
        ],
      ),
    );
    if (go == true && mounted) await _fill(s, t);
  }

  Future<void> _generate(MixController s) async {
    final nav = Navigator.of(context);
    final p = await showGenerateProgramDialog(
      context,
      [for (final x in s.programs) x.name],
      bookends: s.generatorBookends,
      onBookends: s.setGeneratorBookends,
      readiness: s.readinessOf,
    );
    if (p == null) return;
    await nav.push(
      MaterialPageRoute(builder: (_) => ProgramScreen(initial: p)),
    );
  }

  Future<void> _fill(MixController s, Program t) async {
    final messenger = ScaffoldMessenger.of(context);
    final missed = await s.fillProgram(t);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          missed > 0
              ? '$missed parts had no matching songs; loosen the Mix filters'
              : s.lastFillReport,
        ),
      ),
    );
  }

  Future<void> _swap(MixController s, int i) async {
    final messenger = ScaffoldMessenger.of(context);
    if (!await s.swap(i)) {
      messenger.showSnackBar(
        const SnackBar(content: Text('No similar song to swap in')),
      );
    }
  }

  Widget _damagedBanner(MixController s) {
    final n = s.damagedIndexes.length;
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.errorContainer,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(children: [
        Icon(Icons.broken_image_outlined, color: scheme.onErrorContainer),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            '$n song${n == 1 ? ' has' : 's have'} damaged audio and may skip or stop mid-class.',
            style: TextStyle(color: scheme.onErrorContainer),
          ),
        ),
        FilledButton.icon(
          icon: const Icon(Icons.healing),
          label: Text(n == 1 ? 'Replace it' : 'Replace all $n'),
          onPressed: () => _replaceAll(s),
        ),
      ]),
    );
  }

  Future<void> _replaceAll(MixController s) async {
    final messenger = ScaffoldMessenger.of(context);
    final (done, total) = await s.replaceAllDamaged();
    messenger.showSnackBar(SnackBar(
      content: Text(done == total
          ? 'Replaced $done damaged song${done == 1 ? '' : 's'} with similar ones'
          : 'Replaced $done of $total; no match left for the rest (loosen the Mix filter)'),
      action: done > 0 ? SnackBarAction(label: 'Undo', onPressed: s.undo) : null,
    ));
  }

  /// Picks a stand-in for damaged mix[i]: closest length and tempo first.
  Future<void> _noteDialog(MixController s, Song song) async {
    final c = TextEditingController(text: s.songNotes[song.path] ?? '');
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Cue: ${song.display}', maxLines: 2, overflow: TextOverflow.ellipsis),
        content: SizedBox(
          width: 420,
          child: TextField(
            controller: c,
            autofocus: true,
            maxLength: 200,
            maxLines: 3,
            minLines: 1,
            decoration: const InputDecoration(
                hintText: 'e.g. Out of the saddle on the chorus', helperText: 'Shown in class mode on the phone'),
            onSubmitted: (v) => Navigator.pop(ctx, v),
          ),
        ),
        actions: [
          if (s.songNotes[song.path] != null)
            TextButton(onPressed: () => Navigator.pop(ctx, ''), child: const Text('Remove')),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Save')),
        ],
      ),
    );
    c.dispose();
    if (v != null) s.setSongNote(song.path, v);
  }

  Future<void> _replaceDialog(MixController s, int i) async {
    final cur = s.mix[i];
    final cands = s.replacementsFor(i);
    final pick = await showDialog<Song>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Replace ${cur.display}'),
        content: SizedBox(
          width: 560,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              '${s.damagedReasons[cur.path] ?? 'Damaged audio'}\n'
              'Now: ${cur.medianBpm?.round() ?? '-'} BPM, ${cur.playSeconds == null ? '?' : _fmt(cur.playSeconds!)}',
              style: Theme.of(ctx).textTheme.bodySmall,
            ),
            const Divider(),
            Flexible(
              child: FutureBuilder<List<Song>>(
                future: cands,
                builder: (ctx, snap) {
                  final list = snap.data;
                  if (list == null) {
                    return const Padding(
                        padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()));
                  }
                  if (list.isEmpty) return const Text('No similar song left; loosen the Mix filter');
                  return ListView(shrinkWrap: true, children: [
                    for (final c in list)
                      ListTile(
                        dense: true,
                        title: Text(c.display),
                        subtitle: Text(_likeText(cur, c)),
                        trailing: IconButton(
                          tooltip: 'Preview 30 s',
                          icon: const Icon(Icons.play_circle),
                          onPressed: () => context.read<AppState>().togglePreview(c),
                        ),
                        onTap: () => Navigator.pop(ctx, c),
                      ),
                  ]);
                },
              ),
            ),
          ]),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel'))],
      ),
    );
    if (pick != null && i < s.mix.length && s.mix[i].path == cur.path) s.replaceAt(i, pick);
  }

  String _likeText(Song cur, Song c) {
    String diff(double? a, double? b, String Function(double) f) =>
        a == null || b == null ? '' : ' (${b >= a ? '+' : '−'}${f((b - a).abs())})';
    return '${c.medianBpm?.round() ?? '-'} BPM${diff(cur.medianBpm, c.medianBpm, (d) => d.round().toString())}'
        '   ${c.playSeconds == null ? '?' : _fmt(c.playSeconds!)}${diff(cur.playSeconds, c.playSeconds, _fmt)}'
        '${c.genre == null || c.genre!.isEmpty ? '' : '   ${c.genre}'}';
  }

  Future<void> _clear(MixController s) async {
    if (await confirmUnsavedMix(context, s, action: 'clear the mix')) s.clearMix();
  }

  Future<void> _importPlaylist(MixController s) async {
    final messenger = ScaffoldMessenger.of(context);
    final pick = await FilePicker.pickFiles(
        dialogTitle: 'Import playlist',
        type: FileType.custom,
        allowedExtensions: ['m3u', 'm3u8']);
    final path = pick.isEmpty ? null : pick.first.path;
    if (path == null || !mounted) return;
    var replace = true;
    if (s.mix.isNotEmpty) {
      final choice = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Import playlist'),
          content: const Text('Replace the current mix with the playlist, or add its songs at the end?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Add to end')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Replace')),
          ],
        ),
      );
      if (choice == null || !mounted) return;
      replace = choice;
      if (replace && !await confirmUnsavedMix(context, s, action: 'replace the mix')) return;
    }
    final M3uImportResult r;
    try {
      final file = File(path);
      final text = decodePlaylist(await file.readAsBytes(),
          m3u8: path.toLowerCase().endsWith('.m3u8'));
      final name = file.uri.pathSegments.last.replaceFirst(RegExp(r'\.m3u8?$', caseSensitive: false), '');
      r = await s.importPlaylist(text, baseDir: file.parent.path, replace: replace, name: name);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not read the playlist: $e')));
      return;
    }
    final summary = 'Imported ${r.matched} of ${r.total} songs';
    if (r.skipped.isEmpty) {
      messenger.showSnackBar(SnackBar(
        content: Text(summary),
        action: SnackBarAction(label: 'Undo', onPressed: s.undo),
      ));
      return;
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(summary),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: ExpansionTile(
              title: Text('${r.skipped.length} skipped'),
              children: [
                for (final k in r.skipped)
                  ListTile(
                    dense: true,
                    title: Text(k.line, style: const TextStyle(fontFamily: 'monospace')),
                    subtitle: Text(k.reason.label),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          if (r.matched > 0)
            TextButton(
              onPressed: () {
                s.undo();
                Navigator.pop(ctx);
              },
              child: const Text('Undo'),
            ),
          FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
        ],
      ),
    );
  }

  Future<void> _load(MixController s, MixInfo m) async {
    if (await confirmUnsavedMix(context, s, action: 'load "${m.name}"')) {
      await s.loadMix(m);
    }
  }

  Future<void> _refillPart(MixController s, int part) async {
    final messenger = ScaffoldMessenger.of(context);
    final added = await s.refillPart(part);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          added == 0
              ? 'No songs added to ${s.program.parts[part].name}'
              : 'Re-filled ${s.program.parts[part].name} with $added songs',
        ),
        action: SnackBarAction(label: 'Undo', onPressed: s.undo),
      ),
    );
  }

  Future<void> _suggest(MixController s) => showDialog<void>(
    context: context,
    builder: (_) => _SuggestDialog(
      title: 'Next song suggestions',
      hint: 'Close to the last song\'s tempo, using the Mix filter',
      load: s.suggestNext,
      onPick: (song) => addToMixOrWarn(context, s, song),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final s = context.watch<MixController>();
    if (_name.text != s.mixName) _name.text = s.mixName;
    final jumps = s.jumps.toSet();
    final left = s.remainingSeconds;
    return Padding(
      padding: const EdgeInsets.all(12),
      child: LayoutBuilder(
        builder: (context, box) => Column(
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: box.maxHeight * 0.6),
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        PopupMenuButton<Program>(
                          tooltip: 'Pick a program, then auto-fill it using the Mix filters below',
                          onSelected: s.selectProgram,
                          itemBuilder: (_) => [
                            for (final t in s.programs)
                              PopupMenuItem(
                                value: t,
                                child: Text(
                                  '${t.name} (${t.minutes.round()} min)',
                                ),
                              ),
                          ],
                          child: Chip(
                            avatar: const Icon(Icons.view_list),
                            label: Text('Program: ${s.program.name}'),
                          ),
                        ),
                        FilledButton.tonalIcon(
                          onPressed: () => _fillDialog(s),
                          icon: const Icon(Icons.auto_awesome),
                          label: const Text('Auto-fill program'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => _generate(s),
                          icon: const Icon(Icons.auto_fix_high),
                          label: const Text('Generate program'),
                        ),
                        PopupMenuButton<PartRole>(
                          tooltip: 'Find warm-up, climb, sprint, recovery or cool-down music',
                          onSelected: (r) => _suggestRole(s, r),
                          itemBuilder: (_) => [
                            for (final r in PartRole.values)
                              if (r != PartRole.steady)
                                PopupMenuItem(value: r, child: Text(r.label)),
                          ],
                          child: const Chip(
                            avatar: Icon(Icons.queue_music),
                            label: Text('Music for…'),
                          ),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const ProgramScreen(),
                            ),
                          ),
                          icon: const Icon(Icons.edit_note),
                          label: const Text('Edit programs'),
                        ),
                        SizedBox(
                          width: 110,
                          child: TextFormField(
                            key: ValueKey(s.targetMinutes),
                            initialValue: s.targetMinutes.round().toString(),
                            decoration: const InputDecoration(
                              labelText: 'Class mins',
                              isDense: true,
                            ),
                            onFieldSubmitted: (v) {
                              final m = double.tryParse(v);
                              if (m != null && m > 0) s.setTargetMinutes(m);
                            },
                          ),
                        ),
                        Text(
                          left >= 0
                              ? '${_fmt(left)} left'
                              : '${_fmt(-left)} over',
                          style: TextStyle(
                            color: left < 0 ? Colors.redAccent : null,
                          ),
                        ),
                        OutlinedButton.icon(
                          onPressed: s.mix.isEmpty ? null : () => _suggest(s),
                          icon: const Icon(Icons.skip_next),
                          label: const Text('Suggest next'),
                        ),
                        OutlinedButton.icon(
                          onPressed: s.mix.isEmpty
                              ? null
                              : () => showSimilar(context, s.mix.last),
                          icon: const Icon(Icons.auto_awesome_motion),
                          label: const Text('More like last song'),
                        ),
                        FilledButton.tonalIcon(
                          onPressed: s.mix.isEmpty
                              ? null
                              : () => _exportSheet(s),
                          icon: const Icon(Icons.print),
                          label: const Text('Class sheet'),
                        ),
                        FilterChip(
                          tooltip: 'Never pick explicit songs for this class',
                          avatar: const Icon(Icons.child_friendly, size: 18),
                          label: const Text('Clean class'),
                          selected: s.cleanClass,
                          onSelected: s.setCleanClass,
                        ),
                        RotationMenu(s: s),
                        OutlinedButton.icon(
                          onPressed: s.mix.isEmpty ? null : () => showRefreshDialog(context, s),
                          icon: const Icon(Icons.refresh),
                          label: const Text('Refresh'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => showSeriesDialog(context, s),
                          icon: const Icon(Icons.date_range),
                          label: const Text('Plan series…'),
                        ),
                        if (s.explicitInMix.isNotEmpty)
                          Tooltip(
                            message: 'Explicit: ${s.explicitInMix.map((m) => m.display).join(', ')}',
                            child: Chip(
                              avatar: const ExplicitBadge(),
                              label: Text('${s.explicitInMix.length} explicit'),
                              backgroundColor: s.cleanClass ? Colors.red.withValues(alpha: 0.25) : null,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        SizedBox(
                          width: 220,
                          child: TextField(
                            controller: _name,
                            decoration: const InputDecoration(
                              labelText: 'Mix name',
                              isDense: true,
                            ),
                            onChanged: s.setMixName,
                          ),
                        ),
                        FilledButton.icon(
                          onPressed: s.mix.isEmpty
                              ? null
                              : () async {
                                  final nav = Navigator.of(context);
                                  await app.playMix();
                                  nav.push(
                                    MaterialPageRoute(
                                      builder: (_) => const NowPlayingScreen(),
                                    ),
                                  );
                                },
                          icon: const Icon(Icons.play_arrow),
                          label: const Text('Play mix'),
                        ),
                        Tooltip(
                          message: s.dirty
                              ? 'Save the changes (Ctrl+S)'
                              : 'Save (Ctrl+S)',
                          child: FilledButton.icon(
                            onPressed: s.mix.isEmpty ? null : s.saveMix,
                            icon: const Icon(Icons.save),
                            label: Text(s.dirty ? 'Save*' : 'Save'),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Undo (Ctrl+Z)',
                          icon: const Icon(Icons.undo),
                          onPressed: s.canUndo ? s.undo : null,
                        ),
                        IconButton(
                          tooltip: 'Redo (Ctrl+Y)',
                          icon: const Icon(Icons.redo),
                          onPressed: s.canRedo ? s.redo : null,
                        ),
                        FilledButton.tonalIcon(
                          onPressed: s.mix.isEmpty ? null : () => _export(s),
                          icon: const Icon(Icons.ios_share),
                          label: const Text('Export .m3u8 (PC paths only)'),
                        ),
                        FilledButton.tonalIcon(
                          onPressed: () => _importPlaylist(s),
                          icon: const Icon(Icons.playlist_add),
                          label: const Text('Import playlist…'),
                        ),
                        FilledButton.icon(
                          onPressed: s.mix.isEmpty
                              ? null
                              : () => showDialog<void>(
                                  context: context,
                                  builder: (_) => SendToPhoneDialog(state: app),
                                ),
                          icon: const Icon(Icons.phone_android),
                          label: const Text('Send to phone…'),
                        ),
                        FilledButton.tonalIcon(
                          onPressed: () => showDialog<void>(
                              context: context, builder: (_) => const SendFolderDialog()),
                          icon: const Icon(Icons.drive_folder_upload_outlined),
                          label: const Text('Send folder to phone…'),
                        ),
                        ListenableBuilder(
                          listenable: app.phones,
                          builder: (context, _) {
                            final pull = app.phones.pull;
                            if (pull == null) return const SizedBox.shrink();
                            final rep = app.phones.lastPullReport;
                            return InputChip(
                              avatar: const Icon(Icons.qr_code_2, size: 18),
                              label: Text(
                                rep == null
                                    ? 'Serving "${app.phones.pullMixName}" to phone (code ${pull.token})'
                                    : 'Phone imported a mix · still serving',
                              ),
                              tooltip: 'The phone can download from this PC until you stop it',
                              deleteIcon: const Icon(
                                Icons.stop_circle_outlined,
                              ),
                              deleteButtonTooltipMessage: 'Stop serving',
                              onDeleted: app.phones.stopPull,
                            );
                          },
                        ),
                        TextButton(
                          onPressed: s.mix.isEmpty ? null : () => _clear(s),
                          child: const Text('Clear'),
                        ),
                        ActionChip(
                          tooltip: 'Saved mixes',
                          avatar: const Icon(Icons.folder_open),
                          label: const Text('Saved mixes'),
                          onPressed: s.savedMixes.isEmpty
                              ? null
                              : () => Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      // The Mix tab's load entry point (any
                                      // unsaved-changes guard goes here too).
                                      builder: (_) => SavedMixesScreen(onLoad: (m) => _load(s, m)),
                                    ),
                                  ),
                        ),
                        ActionChip(
                          tooltip: 'Log that you taught this mix (snapshots its songs)',
                          avatar: const Icon(Icons.event_available),
                          label: const Text('Mark as taught'),
                          onPressed: s.mix.isEmpty
                              ? null
                              : () => markAsTaught(context,
                                  mixId: s.mixDbId, mixName: s.mixName, paths: s.paths),
                        ),
                        ActionChip(
                          tooltip: 'Classes you have taught',
                          avatar: const Icon(Icons.history),
                          label: const Text('Class history'),
                          onPressed: () => showDialog<void>(
                              context: context, builder: (_) => const ClassHistoryDialog()),
                        ),
                        Text('${s.mix.length} songs, ${_fmt(s.mixSeconds)}'),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: const MixFilterBar(),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          for (var i = 0; i < s.program.parts.length; i++)
                            if (s.program.parts[i].music)
                              InputChip(
                                avatar: s.mix.isNotEmpty && s.partWarning(i) != null
                                    ? Icon(Icons.warning_amber,
                                        size: 16, color: Theme.of(context).colorScheme.error)
                                    : Icon(
                                        iconForKey(
                                          roleIconKey(s.program.parts[i].kind),
                                        ),
                                        size: 16,
                                      ),
                                tooltip: [
                                  if (s.mix.isNotEmpty && s.partWarning(i) != null)
                                    '${s.partWarning(i)!} — re-fill to rebalance',
                                  s.program.parts[i].execution,
                                ].where((t) => t.isNotEmpty).join('\n'),
                                label: Text(
                                  '${i + 1}. ${s.program.parts[i].name} '
                                  '${s.program.parts[i].minRpm.round()}–${s.program.parts[i].maxRpm.round()} RPM '
                                  '(${_fmt(s.partSeconds(i))} / ${s.program.parts[i].minutes.toStringAsFixed(1)} min)',
                                ),
                                onPressed: () => _suggestPart(s, i),
                                deleteIcon: const Icon(Icons.autorenew, size: 18),
                                deleteButtonTooltipMessage:
                                    'Re-fill this part (keeps its locked songs)',
                                onDeleted: () => _refillPart(s, i),
                              ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 120,
                      width: double.infinity,
                      child: TempoProfile(
                        songs: s.mix,
                        parts: [
                          for (var i = 0; i < s.mix.length; i++) s.partAt(i),
                        ],
                        partKeys: [
                          for (var i = 0; i < s.mix.length; i++) i < s.mixPart.length ? s.mixPart[i] : null,
                        ],
                        selected: _selected != null && _selected! < s.mix.length ? _selected : null,
                        onSelect: (i) => _select(i, s.mix.length),
                        onMove: (from, to) {
                          s.reorderMix(from, to > from ? to + 1 : to);
                          setState(() => _selected = to);
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const Divider(),
            if (s.damagedIndexes.isNotEmpty) _damagedBanner(s),
            Expanded(
              child: s.mix.isEmpty
                  ? const Center(child: Text('Add songs from the Songs tab'))
                  : ReorderableListView.builder(
                      scrollController: _list,
                      buildDefaultDragHandles: true,
                      itemCount: s.mix.length,
                      onReorderItem: (o, n) =>
                          s.reorderMix(o, n > o ? n + 1 : n),
                      itemBuilder: (_, i) {
                        final song = s.mix[i];
                        final warn = _tempoWarning(s, i, song);
                        return ListTile(
                          key: ValueKey(song.path),
                          dense: true,
                          selected: i == _selected,
                          leading: song.damaged
                              ? Row(mainAxisSize: MainAxisSize.min, children: [
                                  DamagedBadge(reason: s.damagedReasons[song.path]),
                                  const SizedBox(width: 4),
                                  Text('${i + 1}'),
                                ])
                              : warn == null
                              ? Text('${i + 1}')
                              : Tooltip(
                                  message: warn,
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(
                                        Icons.warning_amber,
                                        color: Colors.orange,
                                        size: 18,
                                      ),
                                      const SizedBox(width: 4),
                                      Text('${i + 1}'),
                                    ],
                                  ),
                                ),
                          title: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                flex: 3,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(children: [
                                      if (song.isExplicit) ...[
                                        const ExplicitBadge(size: 14),
                                        const SizedBox(width: 6),
                                      ],
                                      Flexible(
                                        child: Text(
                                          song.display,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ]),
                                    Text(
                                      '${song.medianBpm?.round() ?? '-'} BPM   ${song.playSeconds == null ? '' : _fmt(song.playSeconds!)}${song.trimmed ? ' ✂' : ''}'
                                      '${song.damaged ? '   ⚠ damaged audio: replace it' : ''}'
                                      '${warn == null ? '' : '   ⚠ tempo off for this part'}'
                                      '${jumps.contains(i) ? '   ⚠ big tempo jump to next song' : ''}',
                                      style: Theme.of(context).textTheme.bodySmall,
                                    ),
                                    if (s.songNotes[song.path] != null)
                                      Text(
                                        '💬 ${s.songNotes[song.path]}',
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                            fontStyle: FontStyle.italic,
                                            color: Theme.of(context).colorScheme.primary),
                                      ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                flex: 2,
                                child: _activityCell(context, _partOf(s, i)),
                              ),
                            ],
                          ),
                          onTap: () {
                            app.setMode(PlayMode.mix);
                            app.play(song.path);
                          },
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip: s.songNotes[song.path] == null
                                    ? 'Add a coaching cue for this song (shown and spoken on the phone)'
                                    : 'Edit coaching cue',
                                isSelected: s.songNotes[song.path] != null,
                                icon: const Icon(Icons.chat_bubble_outline),
                                selectedIcon: const Icon(Icons.chat_bubble),
                                onPressed: () => _noteDialog(s, song),
                              ),
                              IconButton(
                                tooltip: s.isLocked(i)
                                    ? 'Locked: auto-fill keeps this song. Click to unlock'
                                    : 'Lock: keep this song when auto-filling',
                                isSelected: s.isLocked(i),
                                icon: const Icon(Icons.lock_open),
                                selectedIcon: const Icon(Icons.lock),
                                onPressed: () => s.toggleLock(i),
                              ),
                              IconButton(
                                tooltip: app.previewing == song.path
                                    ? 'Stop preview'
                                    : 'Preview 30 s',
                                icon: Icon(
                                  app.previewing == song.path
                                      ? Icons.stop_circle
                                      : Icons.play_circle,
                                ),
                                onPressed: () => app.togglePreview(song),
                              ),
                              if (song.damaged)
                                IconButton(
                                  tooltip: 'Replace with a song of similar length and tempo',
                                  icon: Icon(Icons.healing,
                                      color: Theme.of(context).colorScheme.error),
                                  onPressed: () => _replaceDialog(s, i),
                                )
                              else
                              IconButton(
                                tooltip: 'Swap for a similar song',
                                icon: const Icon(Icons.swap_horiz),
                                onPressed: () => _swap(s, i),
                              ),
                              IconButton(
                                tooltip: 'Make first song',
                                icon: const Icon(Icons.vertical_align_top),
                                onPressed: () => s.moveToStart(i),
                              ),
                              IconButton(
                                tooltip: 'Make last song',
                                icon: const Icon(Icons.vertical_align_bottom),
                                onPressed: () => s.moveToEnd(i),
                              ),
                              IconButton(
                                tooltip: 'Remove',
                                icon: const Icon(Icons.close),
                                onPressed: () => s.removeFromMix(i),
                              ),
                              const SizedBox(width: 28),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Song suggestions with the Mix filter shown on top; changing a filter searches again.
class _SuggestDialog extends StatefulWidget {
  const _SuggestDialog({
    required this.title,
    required this.load,
    required this.onPick,
    this.role,
    this.hint,
  });
  final String title;
  final String? hint;

  /// Edits this role's own filter instead of the Mix-wide one.
  final PartRole? role;
  final Future<List<Song>> Function() load;
  final void Function(Song) onPick;

  @override
  State<_SuggestDialog> createState() => _SuggestDialogState();
}

class _SuggestDialogState extends State<_SuggestDialog> {
  late Future<List<Song>> _songs = widget.load();

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SizedBox(
      width: 640,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MixFilterBar(
            role: widget.role,
            onChanged: () => setState(() => _songs = widget.load()),
          ),
          if (widget.hint != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                widget.hint!,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          const Divider(),
          Flexible(
            child: FutureBuilder<List<Song>>(
              future: _songs,
              builder: (context, snap) {
                final songs = snap.data;
                if (songs == null) {
                  return const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                if (songs.isEmpty) {
                  return const Text('No songs match; loosen the filters above');
                }
                return ListView(
                  shrinkWrap: true,
                  children: [
                    for (final song in songs)
                      ListTile(
                        dense: true,
                        title: Text(song.display),
                        subtitle: Text(
                          '${song.medianBpm?.round() ?? '-'} BPM'
                          '${song.genre == null || song.genre!.isEmpty ? '' : ' · ${song.genre}'}'
                          '${song.year == null ? '' : ' · ${song.year}'}',
                        ),
                        onTap: () {
                          widget.onPick(song);
                          Navigator.pop(context);
                        },
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Close'),
      ),
    ],
  );
}

