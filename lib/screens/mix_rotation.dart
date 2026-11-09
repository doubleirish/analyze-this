import 'package:flutter/material.dart';

import '../services/db.dart';
import '../services/mix_controller.dart';

String _len(Song s) {
  final d = s.playSeconds;
  if (d == null) return '';
  final r = d.round();
  return '${r ~/ 60}:${(r % 60).toString().padLeft(2, '0')}';
}

String _bpm(Song s) => s.medianBpm == null ? '' : '${s.medianBpm!.round()} bpm';

/// Chip menu for [MixController.rotationMixes]: never pick songs used in the
/// last N saved mixes.
class RotationMenu extends StatelessWidget {
  const RotationMenu({super.key, required this.s});
  final MixController s;

  @override
  Widget build(BuildContext context) {
    final n = s.rotationMixes;
    return PopupMenuButton<int>(
      tooltip: 'Rotation: keep songs from your last few mixes out of new picks',
      onSelected: s.setRotationMixes,
      itemBuilder: (_) => [
        for (final v in const [0, 1, 2, 3, 5, 10])
          CheckedPopupMenuItem(
            value: v,
            checked: v == n,
            child: Text(v == 0 ? 'Off (only prefer fresh songs)' : 'Skip songs in the last $v mix${v == 1 ? '' : 'es'}'),
          ),
      ],
      child: Chip(
        avatar: const Icon(Icons.autorenew, size: 18),
        label: Text(n == 0 ? 'Rotation: off' : 'Rotation: last $n'),
      ),
    );
  }
}

/// Finds fresh stand-ins for songs used recently and lets the user pick which
/// to swap; applied as one undo step.
Future<void> showRefreshDialog(BuildContext context, MixController s) async {
  final lastMixes = s.rotationMixes > 0 ? s.rotationMixes : 3;
  final messenger = ScaffoldMessenger.of(context);
  final stale = await s.staleIndexes(lastMixes: lastMixes);
  if (stale.isEmpty) {
    messenger.showSnackBar(SnackBar(
        content: Text('Nothing to refresh: no unlocked song was taught recently or used in the last $lastMixes mixes.')));
    return;
  }
  final picks = await s.refreshPicks(lastMixes: lastMixes);
  if (!context.mounted) return;
  if (picks.isEmpty) {
    messenger.showSnackBar(SnackBar(
        content: Text('${stale.length} recently used song${stale.length == 1 ? '' : 's'}, but no fresh stand-ins fit.')));
    return;
  }
  final chosen = await showDialog<Map<int, Song>>(
      context: context, builder: (_) => _RefreshDialog(s: s, picks: picks, stale: stale.length));
  if (chosen == null || chosen.isEmpty) return;
  s.applyReplacements(chosen);
  messenger.showSnackBar(SnackBar(
      content: Text('Swapped ${chosen.length} song${chosen.length == 1 ? '' : 's'} (Ctrl+Z to undo)')));
}

class _RefreshDialog extends StatefulWidget {
  const _RefreshDialog({required this.s, required this.picks, required this.stale});
  final MixController s;
  final Map<int, Song> picks;
  final int stale;

  @override
  State<_RefreshDialog> createState() => _RefreshDialogState();
}

class _RefreshDialogState extends State<_RefreshDialog> {
  late final Set<int> _on = widget.picks.keys.toSet();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final keys = widget.picks.keys.toList()..sort();
    final missing = widget.stale - keys.length;
    return AlertDialog(
      title: const Text('Refresh mix'),
      content: SizedBox(
        width: 640,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Recently used songs and fresh stand-ins of similar length and tempo.'
              '${missing > 0 ? ' $missing more had no stand-in.' : ''}'),
          const SizedBox(height: 8),
          Flexible(
            child: ListView(shrinkWrap: true, children: [
              for (final i in keys)
                CheckboxListTile(
                  value: _on.contains(i),
                  onChanged: (v) => setState(() => v == true ? _on.add(i) : _on.remove(i)),
                  dense: true,
                  title: Text('${i + 1}. ${widget.s.mix[i].display}',
                      style: theme.textTheme.bodyMedium?.copyWith(decoration: TextDecoration.lineThrough)),
                  subtitle: Text(
                      '→ ${widget.picks[i]!.display}  ·  ${_len(widget.picks[i]!)} ${_bpm(widget.picks[i]!)}'
                      '  (was ${_len(widget.s.mix[i])} ${_bpm(widget.s.mix[i])})'),
                ),
            ]),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: _on.isEmpty
              ? null
              : () => Navigator.pop(context, {for (final i in _on) i: widget.picks[i]!}),
          child: Text('Swap ${_on.length}'),
        ),
      ],
    );
  }
}

/// Plans several mixes of the current program in one go (see [MixController.planSeries]).
Future<void> showSeriesDialog(BuildContext context, MixController s) async {
  final name = TextEditingController(text: s.program.name);
  var count = 4;
  final go = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) => AlertDialog(
        title: const Text('Plan a series'),
        content: SizedBox(
          width: 420,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Fills "${s.program.name}" several times with as few repeats as your library '
                'allows, saves each mix and tags them all series:<name>.'),
            const SizedBox(height: 12),
            TextField(
              controller: name,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Series name', helperText: 'Mixes are named "<name> 1", "<name> 2", …'),
            ),
            const SizedBox(height: 12),
            Row(children: [
              const Text('Mixes:'),
              Expanded(
                child: Slider(
                  value: count.toDouble(),
                  min: 2,
                  max: 12,
                  divisions: 10,
                  label: '$count',
                  onChanged: (v) => set(() => count = v.round()),
                ),
              ),
              Text('$count'),
            ]),
            Text('Saved mixes with the same names are replaced.', style: Theme.of(ctx).textTheme.bodySmall),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Plan')),
        ],
      ),
    ),
  );
  final n = name.text.trim();
  name.dispose();
  if (go != true || n.isEmpty || !context.mounted) return;
  final progress = ValueNotifier(0);
  final messenger = ScaffoldMessenger.of(context);
  final nav = Navigator.of(context);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => AlertDialog(
      content: ValueListenableBuilder<int>(
        valueListenable: progress,
        builder: (_, done, _) => Row(children: [
          const CircularProgressIndicator(),
          const SizedBox(width: 16),
          Text('Planning mix ${done + 1 > count ? count : done + 1} of $count…'),
        ]),
      ),
    ),
  );
  try {
    final ids = await s.planSeries(n, count, onProgress: (d) => progress.value = d);
    messenger.showSnackBar(SnackBar(content: Text('Saved ${ids.length} mixes tagged series:$n')));
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Series planning failed: $e')));
  } finally {
    nav.pop();
    progress.dispose();
  }
}
