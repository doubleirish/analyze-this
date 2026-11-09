import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shared_core/shared_core.dart' show WaveformData, fmtTime, leadingSilence;

import '../services/app_state.dart';
import '../services/db.dart';

/// Edits where [song] starts and stops playing. Trim belongs to the song, so
/// every mix (and the phone) plays it trimmed; plans, fills and totals use
/// the trimmed length.
Future<void> showTrimDialog(BuildContext context, AppState s, Song song) => showDialog<void>(
    context: context, builder: (_) => _TrimDialog(state: s, song: song));

class _TrimDialog extends StatefulWidget {
  const _TrimDialog({required this.state, required this.song});
  final AppState state;
  final Song song;
  @override
  State<_TrimDialog> createState() => _TrimDialogState();
}

class _TrimDialogState extends State<_TrimDialog> {
  late final double _len = math.max(1, widget.song.duration ?? 1);
  late RangeValues _r = RangeValues(
      (widget.song.trimStart ?? 0).clamp(0, _len), (widget.song.trimEnd ?? _len).clamp(0, _len));
  WaveformData? _wave;

  /// Shortest playing length allowed.
  static const _minPlay = 10.0;

  @override
  void initState() {
    super.initState();
    widget.state.waveformFor(widget.song.path).then((w) {
      if (mounted) setState(() => _wave = w);
    });
  }

  double? get _start => _r.start < 0.05 ? null : _round(_r.start);
  double? get _end => _r.end > _len - 0.05 ? null : _round(_r.end);
  static double _round(double v) => (v * 10).round() / 10;

  /// Trailing silence of the waveform (seconds), like [leadingSilence].
  double _trailingSilence(WaveformData w, {int threshold = 8}) {
    final bucket = w.duration / w.peaks.length;
    var i = w.peaks.length - 1;
    while (i >= 0 && w.peaks[i] < threshold) {
      i--;
    }
    return (w.peaks.length - 1 - i) * bucket;
  }

  Future<void> _apply() async {
    await widget.state.setTrim(widget.song.path, _start, _end);
  }

  Future<void> _preview(bool atEnd) async {
    await _apply();
    await widget.state.previewTrimmed(widget.song.path, atEnd: atEnd);
  }

  @override
  Widget build(BuildContext context) {
    final w = _wave;
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text('Trim: ${widget.song.display}', maxLines: 2, overflow: TextOverflow.ellipsis),
      content: SizedBox(
        width: 560,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Choose where the song starts and stops in every mix — e.g. skip a long '
              'intro or end before a fade. The phone fades out briefly at a trimmed end.'),
          const SizedBox(height: 12),
          SizedBox(
            height: 64,
            child: CustomPaint(
              size: const Size(double.infinity, 64),
              painter: _TrimPainter(w, _r.start / _len, _r.end / _len, cs.primary, cs.outlineVariant),
            ),
          ),
          RangeSlider(
            min: 0,
            max: _len,
            values: _r,
            labels: RangeLabels(fmtTime(_r.start), fmtTime(_r.end)),
            onChanged: (v) {
              if (v.end - v.start < _minPlay) return;
              setState(() => _r = v);
            },
          ),
          Text('Starts ${fmtTime(_r.start)} · ends ${fmtTime(_r.end)} · plays ${fmtTime(_r.end - _r.start)} '
              'of ${fmtTime(_len)}'),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            OutlinedButton.icon(
                icon: const Icon(Icons.play_arrow), label: const Text('Hear start'), onPressed: () => _preview(false)),
            OutlinedButton.icon(
                icon: const Icon(Icons.skip_next), label: const Text('Hear ending'), onPressed: () => _preview(true)),
            if (w != null)
              OutlinedButton.icon(
                icon: const Icon(Icons.content_cut),
                label: const Text('Cut silence'),
                onPressed: () {
                  final a = leadingSilence(w);
                  final b = _len - _trailingSilence(w);
                  if (b - a >= _minPlay) {
                    setState(() => _r = RangeValues(a < 1 ? 0 : math.max(0, a - 0.2), math.min(_len, b + 0.3)));
                  }
                },
              ),
            TextButton(onPressed: () => setState(() => _r = RangeValues(0, _len)), child: const Text('Whole song')),
          ]),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
            onPressed: () async {
              final nav = Navigator.of(context);
              await _apply();
              nav.pop();
            },
            child: const Text('Save')),
      ],
    );
  }
}

class _TrimPainter extends CustomPainter {
  _TrimPainter(this.wave, this.a, this.b, this.on, this.off);
  final WaveformData? wave;
  final double a, b;
  final Color on, off;

  @override
  void paint(Canvas canvas, Size size) {
    final w = wave;
    final mid = size.height / 2;
    final pOn = Paint()..color = on;
    final pOff = Paint()..color = off;
    if (w == null || w.peaks.isEmpty) {
      canvas.drawRect(Rect.fromLTRB(0, mid - 1, size.width, mid + 1), pOff);
    } else {
      final n = size.width.floor();
      for (var x = 0; x < n; x++) {
        final f = x / n;
        final pk = w.peaks[(f * w.peaks.length).floor().clamp(0, w.peaks.length - 1)] / 255 * mid;
        canvas.drawRect(Rect.fromLTRB(x.toDouble(), mid - pk, x + 1.0, mid + pk + 1), f >= a && f <= b ? pOn : pOff);
      }
    }
    final line = Paint()
      ..color = on
      ..strokeWidth = 2;
    canvas.drawLine(Offset(a * size.width, 0), Offset(a * size.width, size.height), line);
    canvas.drawLine(Offset(b * size.width, 0), Offset(b * size.width, size.height), line);
  }

  @override
  bool shouldRepaint(_TrimPainter o) => o.wave != wave || o.a != a || o.b != b;
}
