import 'package:flutter/material.dart';

import '../services/db.dart';
import '../services/planner.dart';

const _inBandColor = Color(0xFF43A047);
const _offBandColor = Color(0xFFFB8C00);

/// Left/right x of each song across [width], proportional to play length
/// (songs of unknown length get the average): `edges[i]..edges[i + 1]`.
List<double> profileEdges(List<Song> songs, double width) {
  if (songs.isEmpty) return const [0];
  final known = [for (final s in songs) if ((s.playSeconds ?? 0) > 0) s.playSeconds!];
  final fallback = known.isEmpty ? 1.0 : known.reduce((a, b) => a + b) / known.length;
  final widths = [for (final s in songs) (s.playSeconds ?? 0) > 0 ? s.playSeconds! : fallback];
  final total = widths.reduce((a, b) => a + b);
  final xs = <double>[0];
  for (final w in widths) {
    xs.add(xs.last + w / total * width);
  }
  return xs;
}

/// The song under [x] given [profileEdges], clamped to the first/last.
int profileIndexAt(List<double> edges, double x) {
  for (var i = 0; i + 1 < edges.length; i++) {
    if (x < edges[i + 1]) return i;
  }
  return edges.length - 2;
}

/// Where a song dragged from [from] lands when dropped over song [over]:
/// kept inside the run of neighbouring songs sharing its part ([partKeys]),
/// so a drag never moves a song into another activity. Null = no move.
int? dropWithinPart(List<int?> partKeys, int from, int over) {
  if (from < 0 || from >= partKeys.length) return null;
  var lo = from, hi = from;
  while (lo > 0 && partKeys[lo - 1] == partKeys[from]) {
    lo--;
  }
  while (hi < partKeys.length - 1 && partKeys[hi + 1] == partKeys[from]) {
    hi++;
  }
  final to = over.clamp(lo, hi);
  return to == from ? null : to;
}

String _clock(double sec) {
  final s = sec.round();
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

/// The class's energy over time: a bar per song (width = length, height =
/// cadence) over each part's shaded RPM band. Bars show the BPM folded by
/// half/double time towards the band: green inside it, orange outside.
/// Hover for details, click to select a song ([onSelect]) and drag a bar
/// sideways to reorder it within its part ([onMove], final index).
class TempoProfile extends StatefulWidget {
  const TempoProfile({
    super.key,
    required this.songs,
    this.parts = const [],
    this.partKeys = const [],
    this.selected,
    this.onSelect,
    this.onMove,
  });
  final List<Song> songs;

  /// Program part of each song (by index); missing or null = no part.
  final List<ProgramPart?> parts;

  /// Part index of each song, for keeping drags inside a part.
  final List<int?> partKeys;
  final int? selected;
  final ValueChanged<int>? onSelect;
  final void Function(int from, int to)? onMove;

  @override
  State<TempoProfile> createState() => _TempoProfileState();
}

class _TempoProfileState extends State<TempoProfile> {
  int? _hover, _drag, _dropAt;

  ProgramPart? _part(int i) => i < widget.parts.length ? widget.parts[i] : null;

  double _shown(int i) {
    final bpm = widget.songs[i].medianBpm ?? 0;
    final p = _part(i);
    return p == null || bpm <= 0 ? bpm : foldToBand(bpm, p.minRpm, p.maxRpm);
  }

  String _info(int i) {
    final s = widget.songs[i];
    final p = _part(i);
    final v = _shown(i);
    var start = 0.0;
    for (var k = 0; k < i; k++) {
      start += widget.songs[k].playSeconds ?? 0;
    }
    final rpm = v <= 0 ? 'no tempo' : '${v.round()} RPM';
    final band = p == null ? '' : ' · ${p.name} ${p.minRpm.round()}–${p.maxRpm.round()}';
    return '${i + 1}. ${s.display} · $rpm$band · at ${_clock(start)}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final n = widget.songs.length;
    final focus = _drag ?? _hover ?? widget.selected;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(
        height: 18,
        child: Text(
          focus != null && focus < n
              ? _info(focus)
              : n == 0
                  ? ''
                  : 'Class energy: click a bar to find the song, drag it sideways to reorder within its part',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall,
        ),
      ),
      Expanded(
        child: LayoutBuilder(builder: (context, box) {
          final edges = profileEdges(widget.songs, box.maxWidth);
          int at(Offset o) => profileIndexAt(edges, o.dx);
          return MouseRegion(
            onHover: n == 0 ? null : (e) => setState(() => _hover = at(e.localPosition)),
            onExit: (_) => setState(() => _hover = null),
            cursor: widget.onSelect == null ? MouseCursor.defer : SystemMouseCursors.click,
            child: GestureDetector(
              onTapUp: n == 0 || widget.onSelect == null ? null : (d) => widget.onSelect!(at(d.localPosition)),
              onHorizontalDragStart: n == 0 || widget.onMove == null
                  ? null
                  : (d) => setState(() {
                        _drag = at(d.localPosition);
                        _dropAt = null;
                      }),
              onHorizontalDragUpdate: (d) {
                final from = _drag;
                if (from == null) return;
                setState(() => _dropAt = dropWithinPart(widget.partKeys, from, at(d.localPosition)));
              },
              onHorizontalDragEnd: (_) {
                final from = _drag, to = _dropAt;
                setState(() => _drag = _dropAt = null);
                if (from != null && to != null) widget.onMove?.call(from, to);
              },
              onHorizontalDragCancel: () => setState(() => _drag = _dropAt = null),
              child: CustomPaint(
                size: Size(box.maxWidth, box.maxHeight),
                painter: _ProfilePainter(
                  songs: widget.songs,
                  parts: widget.parts,
                  shown: [for (var i = 0; i < n; i++) _shown(i)],
                  edges: edges,
                  color: theme.colorScheme.primary,
                  highlight: focus,
                  dragging: _drag,
                  dropAt: _dropAt,
                  textColor: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          );
        }),
      ),
    ]);
  }
}

class _ProfilePainter extends CustomPainter {
  _ProfilePainter({
    required this.songs,
    required this.parts,
    required this.shown,
    required this.edges,
    required this.color,
    required this.highlight,
    required this.dragging,
    required this.dropAt,
    required this.textColor,
  });
  final List<Song> songs;
  final List<ProgramPart?> parts;
  final List<double> shown;
  final List<double> edges;
  final Color color, textColor;
  final int? highlight, dragging, dropAt;

  ProgramPart? _part(int i) => i < parts.length ? parts[i] : null;

  @override
  void paint(Canvas canvas, Size size) {
    if (songs.isEmpty) return;
    const axis = 12.0; // room for minute ticks
    final h = size.height - axis;
    var hi = 0.0, lo = double.infinity;
    for (var i = 0; i < songs.length; i++) {
      final v = shown[i];
      if (v > 0) {
        hi = v > hi ? v : hi;
        lo = v < lo ? v : lo;
      }
      final p = _part(i);
      if (p != null) {
        if (p.maxRpm > hi) hi = p.maxRpm;
        if (p.minRpm < lo) lo = p.minRpm;
      }
    }
    if (hi <= 0) return;
    // A floor below the lowest value keeps differences visible.
    lo = (lo.isFinite ? lo - 15 : 0).clamp(0, hi - 1).toDouble();
    double y(double v) => h * (1 - ((v - lo) / (hi - lo)).clamp(0.0, 1.0));
    final xs = edges;

    // Bands: one shaded rect per run of consecutive songs in the same part.
    final bandFill = Paint()..color = color.withValues(alpha: 0.12);
    final bandEdge = Paint()
      ..color = color.withValues(alpha: 0.45)
      ..strokeWidth = 1;
    var i = 0;
    while (i < songs.length) {
      final p = _part(i);
      var j = i + 1;
      while (j < songs.length && identical(_part(j), p)) {
        j++;
      }
      if (p != null) {
        final top = y(p.maxRpm), bottom = y(p.minRpm);
        canvas.drawRect(Rect.fromLTRB(xs[i], top, xs[j], bottom), bandFill);
        canvas.drawLine(Offset(xs[i], top), Offset(xs[j], top), bandEdge);
        canvas.drawLine(Offset(xs[i], bottom), Offset(xs[j], bottom), bandEdge);
      }
      i = j;
    }

    for (var k = 0; k < songs.length; k++) {
      final v = shown[k];
      if (v <= 0) continue;
      final p = _part(k);
      final base = p == null ? color : (v >= p.minRpm && v <= p.maxRpm ? _inBandColor : _offBandColor);
      final a = k == dragging ? 0.4 : (k == highlight ? 1.0 : 0.8);
      final left = xs[k] + 1, right = xs[k + 1] - 1;
      final r = Rect.fromLTRB(left, y(v), right > left ? right : left + 1, h);
      canvas.drawRect(r, Paint()..color = base.withValues(alpha: a));
      if (k == highlight) {
        canvas.drawRect(
            r,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2
              ..color = textColor);
      }
    }

    // Insertion marker for a drag: before the target bar when moving left,
    // after it when moving right.
    final from = dragging, to = dropAt;
    if (from != null && to != null) {
      final x = to < from ? xs[to] : xs[to + 1];
      canvas.drawLine(
          Offset(x, 0),
          Offset(x, h),
          Paint()
            ..color = textColor
            ..strokeWidth = 3);
    }

    // Minute ticks along the bottom, every 5 (or 10) minutes.
    var total = 0.0;
    for (final s in songs) {
      total += s.playSeconds ?? 0;
    }
    if (total <= 0) return;
    final step = total > 60 * 60 ? 600.0 : 300.0;
    final tick = Paint()
      ..color = textColor.withValues(alpha: 0.6)
      ..strokeWidth = 1;
    for (var t = step; t < total; t += step) {
      final x = t / total * size.width;
      canvas.drawLine(Offset(x, h), Offset(x, h + 3), tick);
      final tp = TextPainter(
        text: TextSpan(text: '${(t / 60).round()}′', style: TextStyle(fontSize: 9, color: textColor)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(x - tp.width / 2, h + 2));
    }
  }

  @override
  bool shouldRepaint(_ProfilePainter old) => true;
}
