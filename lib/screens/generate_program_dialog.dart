import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:shared_core/shared_core.dart';

import '../services/activities.dart';
import '../services/planner.dart';
import '../services/program_generator.dart';
import '../services/readiness.dart';

/// Pick a length, class style and intensity, then rearrange the generated
/// program: drag activities to reorder them, and drag (or click +) activities
/// from the list on the right to add them. The warm-up, cool-down and stretch
/// can each be switched off; their minutes go to the main block. Changing the
/// length keeps any rearranging; a new style, intensity or shuffle asks first.
/// Returns the chosen [Program] under the typed name (or the suggested one),
/// made unique against [existingNames].
///
/// [bookends] seeds those switches and [onBookends] reports every change, so
/// the choice can be remembered for next time. With [readiness] (e.g.
/// [programReadiness] with the Mix filters), each activity shows how many
/// library songs fit it.
Future<Program?> showGenerateProgramDialog(
  BuildContext context,
  Iterable<String> existingNames, {
  Bookends bookends = const Bookends(),
  ValueChanged<Bookends>? onBookends,
  Future<List<PartReadiness>> Function(Program p)? readiness,
}) =>
    showDialog<Program>(
        context: context,
        builder: (_) => _GenerateDialog(existingNames.toList(), bookends, onBookends, readiness));

class _GenerateDialog extends StatefulWidget {
  const _GenerateDialog(this.existing, this.bookends, this.onBookends, this.readiness);
  final List<String> existing;
  final Bookends bookends;
  final ValueChanged<Bookends>? onBookends;
  final Future<List<PartReadiness>> Function(Program p)? readiness;

  @override
  State<_GenerateDialog> createState() => _GenerateDialogState();
}

/// Identifies an activity for readiness results across rebuilds.
String _partKey(ProgramPart p) => '${p.name}|${p.kind.name}|${p.minRpm}|${p.maxRpm}|${p.minutes}';

class _GenerateDialogState extends State<_GenerateDialog> {
  int _minutes = 45;
  ClassStyle _style = ClassStyle.intervals;
  Intensity _intensity = Intensity.moderate;
  int _seed = Random().nextInt(1 << 30);
  late Bookends _bookends = widget.bookends;
  late ProgramDraft _draft;
  final _name = TextEditingController();

  /// One per activity, so tiles keep their identity while being moved.
  late List<Key> _keys;
  bool _edited = false;

  Map<String, PartReadiness> _ready = {};
  Timer? _readyTimer;
  int _readyGen = 0;

  @override
  void initState() {
    super.initState();
    _regenerate();
    _scheduleReadiness();
  }

  @override
  void dispose() {
    _readyTimer?.cancel();
    _name.dispose();
    super.dispose();
  }

  void _regenerate() {
    final p = generateProgram(
        minutes: _minutes,
        style: _style,
        intensity: _intensity,
        bookends: _bookends,
        random: Random(_seed));
    _draft = ProgramDraft.of(p, style: _style, intensity: _intensity);
    _keys = [for (final _ in _draft.activities) UniqueKey()];
    _edited = false;
  }

  /// Recounts matching songs shortly after the program stops changing.
  void _scheduleReadiness() {
    final f = widget.readiness;
    if (f == null) return;
    _readyTimer?.cancel();
    _readyTimer = Timer(const Duration(milliseconds: 250), () async {
      final gen = ++_readyGen;
      final program = _draft.build();
      try {
        final r = await f(program);
        if (!mounted || gen != _readyGen) return;
        super.setState(() => _ready = {for (final x in r) _partKey(x.part): x});
      } catch (_) {
        // readiness is a hint; ignore failures
      }
    });
  }

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    _scheduleReadiness();
  }

  Future<bool> _confirmDiscard() async {
    if (!_edited) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Start the program again?'),
        content: const Text('A new style, intensity or shuffle builds a new program, '
            'losing the activities you added, removed or moved.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep mine')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Start again')),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _settings(void Function() change) async {
    if (!await _confirmDiscard() || !mounted) return;
    setState(() {
      change();
      _regenerate();
    });
  }

  /// A new length keeps the rearranged activities; only their minutes change.
  void _setLength(int m) => setState(() {
        _minutes = m;
        if (!_edited) {
          _regenerate();
          return;
        }
        final dropped = _draft.setMinutes(m.toDouble());
        if (dropped > 0) _keys.removeRange(_keys.length - dropped, _keys.length);
      });

  /// Switches the warm-up, cool-down or stretch on or off. The activities are
  /// kept; only the minutes are fitted again.
  void _setBookend(PartRole role, bool on) => setState(() {
        if (!_draft.setIncluded(role, on)) return;
        _bookends = _draft.bookends;
        widget.onBookends?.call(_bookends);
      });

  void _insert(int at, ProgramPart p) => setState(() {
        if (_draft.insert(at, p)) {
          _keys.insert(at.clamp(0, _keys.length), UniqueKey());
          _edited = true;
        }
      });

  void _remove(int i) => setState(() {
        if (_draft.removeAt(i) != null) {
          _keys.removeAt(i);
          _edited = true;
        }
      });

  void _move(int from, int to) => setState(() {
        _draft.move(from, to);
        _keys.insert(to, _keys.removeAt(from));
        _edited = true;
      });

  static String _mins(double m) => m.toStringAsFixed(m % 1 == 0 ? 0 : 1);
  static String _describe(ProgramPart p) =>
      '${_mins(p.minutes)} min · ${p.minRpm.round()}–${p.maxRpm.round()} RPM';

  /// Where an activity dropped at the end lands, given the fixed parts that
  /// are switched on.
  String get _endOfClass => _draft.included(PartRole.cooldown)
      ? 'before the cool-down'
      : _draft.included(PartRole.stretch)
          ? 'before the stretch'
          : 'at the end';

  /// Each activity (with its fitted minutes) and the recovery after it, if any.
  List<(ProgramPart, ProgramPart?)> _laidOut() {
    final out = <(ProgramPart, ProgramPart?)>[];
    for (final p in _draft.mainBlock) {
      if (isActivity(p)) {
        out.add((p, null));
      } else if (out.isNotEmpty) {
        out.last = (out.last.$1, p);
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final program = _draft.build();
    final suggested = uniqueProgramName(program.name, widget.existing);
    final typed = _name.text.trim();
    final name = typed.isEmpty ? suggested : uniqueProgramName(typed, widget.existing);
    final height = (MediaQuery.sizeOf(context).height - 260).clamp(360.0, 640.0);
    return AlertDialog(
      title: const Text('Generate a class program'),
      content: SizedBox(
        width: 900,
        height: height,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Text('Length'),
            Expanded(
              child: Slider(
                value: _minutes.toDouble(),
                min: minGeneratedMinutes.toDouble(),
                max: maxGeneratedMinutes.toDouble(),
                divisions: (maxGeneratedMinutes - minGeneratedMinutes) ~/ 5,
                label: '$_minutes min',
                onChanged: (v) => _setLength(v.round()),
              ),
            ),
            Text('$_minutes min'),
          ]),
          Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            DropdownButton<ClassStyle>(
              value: _style,
              onChanged: (v) => _settings(() => _style = v ?? _style),
              items: [
                for (final s in ClassStyle.values)
                  DropdownMenuItem(value: s, child: Text(s.label)),
              ],
            ),
            SegmentedButton<Intensity>(
              showSelectedIcon: false,
              segments: [
                for (final i in Intensity.values)
                  ButtonSegment(value: i, label: Text(i.name[0].toUpperCase() + i.name.substring(1))),
              ],
              selected: {_intensity},
              onSelectionChanged: (v) => _settings(() => _intensity = v.first),
            ),
            OutlinedButton.icon(
                onPressed: () => _settings(() => _seed = Random().nextInt(1 << 30)),
                icon: const Icon(Icons.shuffle),
                label: const Text('Shuffle')),
            if (_edited)
              TextButton.icon(
                  onPressed: () => setState(_regenerate),
                  icon: const Icon(Icons.undo),
                  label: const Text('Undo my changes')),
          ]),
          const SizedBox(height: 6),
          Text(
              '${_style.blurb} A new style, intensity or shuffle starts the program again; '
              'a new length keeps your changes.',
              style: theme.textTheme.bodySmall),
          const Divider(),
          Expanded(
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: _programList(theme, name, program)),
              const VerticalDivider(width: 24),
              SizedBox(width: 270, child: _palette(theme)),
            ]),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
            onPressed: () => Navigator.pop(context, Program(name, program.parts)),
            child: const Text('Use this program')),
      ],
    );
  }

  Widget _programList(ThemeData theme, String name, Program program) {
    final laid = _laidOut();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      TextField(
        controller: _name,
        decoration: InputDecoration(
          isDense: true,
          labelText: 'Name',
          hintText: name,
          helperText: _name.text.trim().isNotEmpty && name != _name.text.trim()
              ? 'Saved as "$name" (that name is taken)'
              : null,
        ),
        onChanged: (_) => setState(() {}),
      ),
      const SizedBox(height: 4),
      Text(
          'Drag the handles to reorder. A recovery follows every second activity. '
          'Switch off the warm-up, cool-down or stretch to give its minutes to the class.',
          style: theme.textTheme.bodySmall),
      const SizedBox(height: 4),
      Expanded(
        child: ReorderableListView.builder(
          buildDefaultDragHandles: false,
          header: _bookendTile(theme, PartRole.warmup),
          footer: Column(children: [
            _endDropZone(theme),
            _bookendTile(theme, PartRole.cooldown),
            _bookendTile(theme, PartRole.stretch),
          ]),
          itemCount: laid.length,
          onReorderItem: _move,
          itemBuilder: (_, i) => _activityTile(theme, i, laid[i].$1, laid[i].$2),
        ),
      ),
    ]);
  }

  /// Warm-up, cool-down and stretch: shown in place but not movable, each with
  /// a switch. One that is switched off stays as a greyed row.
  Widget _bookendTile(ThemeData theme, PartRole role) {
    final on = _draft.included(role);
    final p = _draft.bookend(role);
    final blocked = !on && !_draft.canSetIncluded(role, true);
    final grey = theme.disabledColor;
    return Card(
      key: ValueKey('bookend-${role.name}'),
      margin: const EdgeInsets.symmetric(vertical: 2),
      color: on ? theme.colorScheme.surfaceContainerHighest : null,
      child: ListTile(
        dense: true,
        leading: Icon(iconForKey(roleIconKey(role)), size: 20, color: on ? null : grey),
        title: Text(on ? p.name : '${p.name} — off',
            style: on ? null : theme.textTheme.bodyLarge?.copyWith(color: grey)),
        subtitle: Text(
            on
                ? _describe(p)
                : blocked
                    ? 'No room: remove an activity first'
                    : 'Its ${_mins(p.minutes)} min go to the main block',
            style: on ? null : theme.textTheme.bodySmall?.copyWith(color: grey)),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          if (on)
            Tooltip(
                message: role == PartRole.warmup ? 'Stays at the start' : 'Stays at the end',
                child: Icon(Icons.lock_outline, size: 16, color: grey)),
          Tooltip(
            message: blocked
                ? 'No room: remove an activity first'
                : on
                    ? 'Leave out the ${bookendLabel(role).toLowerCase()}'
                    : 'Put the ${bookendLabel(role).toLowerCase()} back',
            child: Switch(
              value: on,
              onChanged: blocked ? null : (v) => _setBookend(role, v),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _dropMarker(ThemeData theme) => Container(
        height: 4,
        margin: const EdgeInsets.symmetric(vertical: 2),
        decoration: BoxDecoration(
            color: theme.colorScheme.primary, borderRadius: BorderRadius.circular(2)),
      );

  Widget _activityTile(ThemeData theme, int i, ProgramPart a, ProgramPart? recovery) =>
      DragTarget<ProgramPart>(
        key: _keys[i],
        onWillAcceptWithDetails: (d) => _draft.canAdd(d.data),
        onAcceptWithDetails: (d) => _insert(i, d.data),
        builder: (_, candidates, _) => Column(mainAxisSize: MainAxisSize.min, children: [
          if (candidates.isNotEmpty) _dropMarker(theme),
          Card(
            margin: const EdgeInsets.symmetric(vertical: 2),
            child: ListTile(
              dense: true,
              leading: Row(mainAxisSize: MainAxisSize.min, children: [
                ReorderableDragStartListener(
                  index: i,
                  child: const MouseRegion(
                    cursor: SystemMouseCursors.grab,
                    child: Tooltip(message: 'Drag to move', child: Icon(Icons.drag_indicator)),
                  ),
                ),
                const SizedBox(width: 8),
                Icon(iconForKey(roleIconKey(a.kind)), size: 20),
              ]),
              title: Text(a.name),
              subtitle: Text(_describe(a)),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                if (_ready[_partKey(a)] case final r?) _readyBadge(theme, r),
                IconButton(
                  tooltip: 'Remove',
                  icon: const Icon(Icons.close),
                  onPressed: _draft.canRemove(i) ? () => _remove(i) : null,
                ),
              ]),
            ),
          ),
          if (recovery != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 0, 2),
              child: Row(children: [
                Icon(iconForKey(roleIconKey(PartRole.recovery)), size: 16, color: theme.hintColor),
                const SizedBox(width: 6),
                Text('${recovery.name} · ${_mins(recovery.minutes)} min',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
              ]),
            ),
        ]),
      );

  /// How many library songs fit an activity: green / orange / red as in Insights.
  Widget _readyBadge(ThemeData theme, PartReadiness r) {
    final color = switch (r.status) {
      ReadinessStatus.ok => Colors.green,
      ReadinessStatus.thin => Colors.orange,
      ReadinessStatus.empty => theme.colorScheme.error,
    };
    return Tooltip(
      message: r.candidates == 0
          ? 'No library songs fit this activity with the current Mix filters'
          : '${r.candidates} songs fit (${r.fresh} not taught recently); about ${r.needed} needed',
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.library_music, size: 16, color: color),
        const SizedBox(width: 2),
        Text('${r.candidates}', style: theme.textTheme.bodySmall?.copyWith(color: color)),
      ]),
    );
  }

  Widget _endDropZone(ThemeData theme) => DragTarget<ProgramPart>(
        key: const ValueKey('drop-at-end'),
        onWillAcceptWithDetails: (d) => _draft.canAdd(d.data),
        onAcceptWithDetails: (d) => _insert(_draft.activities.length, d.data),
        builder: (_, candidates, rejected) {
          final full = rejected.isNotEmpty;
          return Container(
            width: double.infinity,
            margin: const EdgeInsets.symmetric(vertical: 4),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              border: Border.all(
                  color: candidates.isNotEmpty
                      ? theme.colorScheme.primary
                      : full
                          ? theme.colorScheme.error
                          : theme.dividerColor),
              borderRadius: BorderRadius.circular(8),
              color: candidates.isNotEmpty ? theme.colorScheme.primary.withValues(alpha: 0.08) : null,
            ),
            child: Text(
              full
                  ? 'No room: remove an activity or make the class longer'
                  : 'Drop an activity here to add it $_endOfClass',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
          );
        },
      );

  Widget _palette(ThemeData theme) {
    final catalog = activityCatalog(_intensity);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Activities', style: theme.textTheme.titleSmall),
      Text('Drag one into the program, or click + to add it at the end.',
          style: theme.textTheme.bodySmall),
      const SizedBox(height: 4),
      Expanded(
        child: ListView(children: [for (final a in catalog) _paletteTile(theme, a)]),
      ),
    ]);
  }

  Widget _paletteTile(ThemeData theme, ProgramPart a) {
    final canAdd = _draft.canAdd(a);
    ListTile tile({Widget? trailing}) => ListTile(
          dense: true,
          leading: Icon(iconForKey(roleIconKey(a.kind)), size: 20),
          title: Text(a.name),
          subtitle: Text('${a.minRpm.round()}–${a.maxRpm.round()} RPM'),
          trailing: trailing,
        );
    final row = tile(
      trailing: IconButton(
        tooltip: canAdd ? 'Add at the end' : 'No room: remove an activity or make the class longer',
        icon: const Icon(Icons.add_circle_outline),
        onPressed: canAdd ? () => _insert(_draft.activities.length, a) : null,
      ),
    );
    return Tooltip(
      message: a.purpose,
      waitDuration: const Duration(milliseconds: 700),
      child: Draggable<ProgramPart>(
        data: a,
        // the list is on the left: sideways drags pick an activity up,
        // vertical ones scroll the palette
        affinity: Axis.horizontal,
        feedback: Material(
          elevation: 6,
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(width: 250, child: tile()),
        ),
        childWhenDragging: Opacity(opacity: 0.4, child: row),
        child: MouseRegion(cursor: SystemMouseCursors.grab, child: row),
      ),
    );
  }
}
