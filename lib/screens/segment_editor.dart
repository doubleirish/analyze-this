import 'dart:async';

import 'package:flutter/material.dart';

import 'package:shared_core/services/queue_service.dart' show PlayMode;

import '../services/app_state.dart';
import '../services/mix_controller.dart';
import '../services/segment_edit.dart';

String _clock(double sec) {
  final s = sec.round().abs();
  return '${sec < 0 ? '-' : ''}${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

/// Edits the sub-exercises of mix song [i] (e.g. the levels of a pyramid) so
/// their lengths match parts of the song, with a trainer note on each. Starts
/// from the song's current plan. Saves through [MixController.setSongSegments].
Future<void> showSegmentEditor(BuildContext context, AppState app, int i) async {
  final s = app.mixer;
  final song = s.mix[i];
  final secs = song.playSeconds ?? 0;
  final plan = s.planAt(i, fallbackSeconds: secs);
  final start = s.songSegments[song.path] ??
      (plan == null || plan.segments.isEmpty
          ? [SegmentEdit(label: 'Segment 1', seconds: secs > 0 ? secs : 60, minRpm: 80, maxRpm: 90)]
          : SegmentEdit.fromPlan(plan));
  final result = await showDialog<List<SegmentEdit>>(
    context: context,
    builder: (_) => _SegmentEditor(app: app, title: song.display, seconds: secs, path: song.path, start: start),
  );
  if (result != null) s.setSongSegments(song.path, result);
}

class _SegmentEditor extends StatefulWidget {
  const _SegmentEditor(
      {required this.app, required this.title, required this.seconds, required this.path, required this.start});
  final AppState app;
  final String title, path;
  final double seconds;
  final List<SegmentEdit> start;

  @override
  State<_SegmentEditor> createState() => _SegmentEditorState();
}

class _SegmentEditorState extends State<_SegmentEditor> {
  late List<SegmentEdit> _edits = List.of(widget.start);

  /// Bumped when rows are rebuilt from outside the text fields.
  int _gen = 0;

  /// Tap-along: seconds into the song of each boundary tapped so far.
  List<double>? _marks;
  StreamSubscription<Duration>? _sub;
  double _pos = 0;

  @override
  void dispose() {
    _sub?.cancel();
    if (_marks != null) widget.app.player.pause();
    super.dispose();
  }

  double _now() => widget.app.player.position.inMilliseconds / 1000 - widget.app.player.clipStart;

  Future<void> _startTap() async {
    widget.app.setMode(PlayMode.mix);
    await widget.app.play(widget.path);
    _sub = widget.app.player.positionStream.listen((_) {
      if (mounted) setState(() => _pos = _now());
    });
    setState(() => _marks = []);
  }

  void _tap() {
    final marks = _marks!;
    if (marks.length >= _edits.length - 1) return;
    setState(() => marks.add(_now().clamp(0.0, widget.seconds).toDouble()));
    if (marks.length == _edits.length - 1) _finishTap();
  }

  void _finishTap() {
    final marks = _marks!;
    _sub?.cancel();
    _sub = null;
    widget.app.player.pause();
    setState(() {
      _edits = editsFromMarks(_edits, marks, widget.seconds);
      _marks = null;
      _gen++;
    });
  }

  void _set(int i, SegmentEdit e) => setState(() => _edits[i] = e);

  @override
  Widget build(BuildContext context) {
    final left = unallocatedSeconds(_edits, widget.seconds);
    final scheme = Theme.of(context).colorScheme;
    final tapping = _marks != null;
    final next = tapping && _marks!.length < _edits.length ? _edits[_marks!.length].label : '';
    return AlertDialog(
      title: Text('Sub-exercises: ${widget.title}', maxLines: 2, overflow: TextOverflow.ellipsis),
      content: SizedBox(
        width: 640,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
                'Song length ${_clock(widget.seconds)} · '
                '${left.abs() < 0.5 ? 'fits exactly' : left > 0 ? '${_clock(left)} unallocated (goes to the last one)' : '${_clock(-left)} over (the end is cut)'}',
                style: TextStyle(color: left < -0.5 ? scheme.error : null)),
            const SizedBox(height: 8),
            SizedBox(
              height: 28,
              child: Row(children: [
                for (var i = 0; i < _edits.length; i++)
                  Expanded(
                    flex: (_edits[i].seconds * 10).round().clamp(1, 1000000),
                    child: Tooltip(
                      message: '${_edits[i].label} ${_clock(_edits[i].seconds)}',
                      child: Container(
                        margin: const EdgeInsets.only(right: 1),
                        color: Color.lerp(scheme.primary, scheme.tertiary, i % 2 == 0 ? 0 : 0.8)!.withValues(alpha: 0.7),
                        alignment: Alignment.center,
                        child: Text(_edits[i].label,
                            overflow: TextOverflow.clip, maxLines: 1, style: const TextStyle(fontSize: 11)),
                      ),
                    ),
                  ),
                if (left > 0.5)
                  Expanded(
                      flex: (left * 10).round().clamp(1, 1000000),
                      child: Container(color: scheme.surfaceContainerHighest)),
              ]),
            ),
            const SizedBox(height: 8),
            if (tapping)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Row(children: [
                    Text(_clock(_pos), style: Theme.of(context).textTheme.headlineSmall),
                    const SizedBox(width: 16),
                    Expanded(child: Text('Tap when "$next" ends (${_marks!.length + 1} of ${_edits.length - 1})')),
                    FilledButton(onPressed: _tap, child: const Text('Tap')),
                    TextButton(onPressed: _finishTap, child: const Text('Done')),
                  ]),
                ),
              ),
            for (var i = 0; i < _edits.length; i++)
              Padding(
                key: ValueKey('$_gen-$i'),
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(children: [
                  Expanded(
                    flex: 3,
                    child: TextFormField(
                      initialValue: _edits[i].label,
                      decoration: const InputDecoration(labelText: 'Name', isDense: true),
                      onChanged: (v) => _edits[i] = _edits[i].copyWith(label: v),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 80,
                    child: TextFormField(
                      initialValue: _edits[i].seconds.toStringAsFixed(_edits[i].seconds % 1 == 0 ? 0 : 1),
                      decoration: const InputDecoration(labelText: 'Seconds', isDense: true),
                      keyboardType: TextInputType.number,
                      onChanged: (v) {
                        final d = double.tryParse(v);
                        if (d != null && d > 0) _set(i, _edits[i].copyWith(seconds: d));
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 4,
                    child: TextFormField(
                      initialValue: _edits[i].note,
                      decoration: const InputDecoration(labelText: 'Trainer note', isDense: true),
                      onChanged: (v) => _edits[i] = _edits[i].copyWith(note: v.trim()),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Move up',
                    icon: const Icon(Icons.arrow_upward, size: 18),
                    onPressed: i == 0
                        ? null
                        : () => setState(() {
                              _edits.insert(i - 1, _edits.removeAt(i));
                              _gen++;
                            }),
                  ),
                  IconButton(
                    tooltip: 'Move down',
                    icon: const Icon(Icons.arrow_downward, size: 18),
                    onPressed: i == _edits.length - 1
                        ? null
                        : () => setState(() {
                              _edits.insert(i + 1, _edits.removeAt(i));
                              _gen++;
                            }),
                  ),
                  IconButton(
                    tooltip: 'Remove',
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: _edits.length <= 1
                        ? null
                        : () => setState(() {
                              _edits.removeAt(i);
                              _gen++;
                            }),
                  ),
                ]),
              ),
            Row(children: [
              TextButton.icon(
                onPressed: () => setState(() {
                  final last = _edits.isEmpty ? null : _edits.last;
                  _edits.add(SegmentEdit(
                      label: 'Segment ${_edits.length + 1}',
                      seconds: left > 1 ? left : 30,
                      minRpm: last?.minRpm ?? 80,
                      maxRpm: last?.maxRpm ?? 90));
                  _gen++;
                }),
                icon: const Icon(Icons.add),
                label: const Text('Add'),
              ),
              TextButton.icon(
                onPressed: _edits.length < 2 || tapping || widget.seconds <= 0 ? null : _startTap,
                icon: const Icon(Icons.touch_app),
                label: const Text('Tap along to the song'),
              ),
            ]),
          ]),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context, <SegmentEdit>[]),
            child: const Text('Reset to automatic')),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
            onPressed: _edits.isEmpty ? null : () => Navigator.pop(context, _edits),
            child: const Text('Save')),
      ],
    );
  }
}
