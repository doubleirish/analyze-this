import 'package:flutter/material.dart';
import 'package:shared_core/shared_core.dart';

import '../services/app_state.dart';
import '../services/db.dart';
import '../services/tap_tempo.dart';

/// "Fix BPM…": halve/double a wrongly detected tempo, set it outright, or tap it.
Future<void> showBpmFixDialog(BuildContext context, AppState s, Song song) async {
  final current = await s.db.bpmFix(song.path);
  if (!context.mounted) return;
  final fix = await showDialog<(ManualBpm?,)>(
    context: context,
    builder: (_) => _BpmFixDialog(song: song, current: current),
  );
  if (fix == null) return;
  await s.db.setBpmFix(song.path, scale: fix.$1?.scale, bpm: fix.$1?.bpm);
  await s.refresh();
}

class _BpmFixDialog extends StatefulWidget {
  const _BpmFixDialog({required this.song, required this.current});
  final Song song;
  final ManualBpm? current;

  @override
  State<_BpmFixDialog> createState() => _BpmFixDialogState();
}

class _BpmFixDialogState extends State<_BpmFixDialog> {
  final _bpm = TextEditingController();
  final _taps = TapTempo();
  final _clock = Stopwatch()..start();
  double? _tapped;

  @override
  void dispose() {
    _bpm.dispose();
    super.dispose();
  }

  /// Scale relative to the detected tempo, combining with an existing scale fix.
  void _scale(double by) {
    final old = widget.current?.scale ?? 1;
    final cur = widget.current;
    if (cur?.bpm != null) {
      Navigator.pop(context, (ManualBpm(bpm: cur!.bpm! * by),));
      return;
    }
    final next = old * by;
    Navigator.pop(context, (next == 1 ? null : ManualBpm(scale: next),));
  }

  void _setBpm(double? v) {
    if (v == null || v <= 0) return;
    Navigator.pop(context, (ManualBpm(bpm: double.parse(v.toStringAsFixed(1))),));
  }

  @override
  Widget build(BuildContext context) {
    final med = widget.song.medianBpm;
    final cur = widget.current;
    final fixText = cur == null
        ? 'as detected'
        : cur.bpm != null
            ? 'set to ${cur.bpm!.toStringAsFixed(1)}'
            : '×${cur.scale}';
    return AlertDialog(
      title: Text('Fix BPM: ${widget.song.display}'),
      content: SizedBox(
        width: 360,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Current BPM: ${med == null ? '–' : med.toStringAsFixed(1)} ($fixText)'),
          const SizedBox(height: 12),
          Row(children: [
            OutlinedButton(onPressed: () => _scale(0.5), child: const Text('½×')),
            const SizedBox(width: 8),
            OutlinedButton(onPressed: () => _scale(2), child: const Text('2×')),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _bpm,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Set BPM'),
                onSubmitted: (v) => _setBpm(double.tryParse(v)),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(onPressed: () => _setBpm(double.tryParse(_bpm.text)), child: const Text('Set')),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            FilledButton.tonalIcon(
              icon: const Icon(Icons.touch_app),
              label: const Text('Tap tempo'),
              onPressed: () => setState(() => _tapped = _taps.tap(_clock.elapsed)),
            ),
            const SizedBox(width: 12),
            Text(_tapped == null ? (_taps.count == 1 ? 'keep tapping…' : '') : '${_tapped!.toStringAsFixed(1)} BPM'),
            const Spacer(),
            if (_tapped != null) TextButton(onPressed: () => _setBpm(_tapped), child: const Text('Use')),
          ]),
        ]),
      ),
      actions: [
        if (cur != null) TextButton(onPressed: () => Navigator.pop(context, (null,)), child: const Text('Clear fix')),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      ],
    );
  }
}
