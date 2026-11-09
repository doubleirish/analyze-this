import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_core/shared_core.dart';

import '../services/activities.dart';
import '../services/mix_controller.dart';
import '../services/planner.dart';
import 'generate_program_dialog.dart';

class _Row {
  _Row(ProgramPart p)
      : name = TextEditingController(text: p.name),
        minutes = TextEditingController(text: _n(p.minutes)),
        minRpm = TextEditingController(text: _n(p.minRpm)),
        maxRpm = TextEditingController(text: _n(p.maxRpm)),
        notes = TextEditingController(text: p.execution),
        baseGear = TextEditingController(text: p.baseGear?.toString() ?? ''),
        gearTop = TextEditingController(text: p.gearTop?.toString() ?? ''),
        music = p.music,
        purpose = p.purpose,
        feel = p.feel,
        maxStddev = p.maxStddev,
        role = p.role,
        variant = p.variant;

  final TextEditingController name, minutes, minRpm, maxRpm, notes, baseGear, gearTop;
  bool music;
  final String purpose, feel;
  final double? maxStddev;

  /// null = worked out from the name.
  PartRole? role;
  String? variant;
  final key = UniqueKey();

  PartRole get kind => role ?? PartRole.infer(name.text);

  static String _n(double v) => v == v.roundToDouble() ? v.round().toString() : v.toString();

  ProgramPart toPart() {
    final lo = double.tryParse(minRpm.text) ?? 80;
    final hi = double.tryParse(maxRpm.text) ?? lo;
    return ProgramPart(
      name.text.trim().isEmpty ? 'Part' : name.text.trim(),
      (double.tryParse(minutes.text) ?? 5).clamp(0.5, 120),
      lo < hi ? lo : hi,
      lo < hi ? hi : lo,
      purpose: purpose,
      feel: feel,
      execution: notes.text,
      music: music,
      maxStddev: maxStddev,
      role: role,
      variant: kind == PartRole.tabata ? variant : null,
      baseGear: int.tryParse(baseGear.text.trim())?.clamp(1, 24),
      gearTop: int.tryParse(gearTop.text.trim())?.clamp(1, 23),
    );
  }

  void dispose() {
    for (final c in [name, minutes, minRpm, maxRpm, notes, baseGear, gearTop]) {
      c.dispose();
    }
  }
}

/// Build a class program: an ordered list of parts with a duration and RPM range.
class ProgramScreen extends StatefulWidget {
  const ProgramScreen({super.key, this.initial});

  /// Program to start editing (e.g. a freshly generated one); defaults to the current program.
  final Program? initial;

  @override
  State<ProgramScreen> createState() => _ProgramScreenState();
}

class _ProgramScreenState extends State<ProgramScreen> {
  late final TextEditingController _name;
  late List<_Row> _rows;

  @override
  void initState() {
    super.initState();
    final p = widget.initial ?? context.read<MixController>().program;
    _name = TextEditingController(text: p.builtin ? '${p.name} (copy)' : p.name);
    _rows = [for (final x in p.parts) _Row(x)];
  }

  @override
  void dispose() {
    _name.dispose();
    for (final r in _rows) {
      r.dispose();
    }
    super.dispose();
  }

  void _load(Program p) => setState(() {
        for (final r in _rows) {
          r.dispose();
        }
        _name.text = p.builtin ? '${p.name} (copy)' : p.name;
        _rows = [for (final x in p.parts) _Row(x)];
      });

  Program _program() => Program(_name.text, [for (final r in _rows) r.toPart()]);

  @override
  Widget build(BuildContext context) {
    final s = context.watch<MixController>();
    final total = _rows.fold<double>(0, (a, r) => a + (double.tryParse(r.minutes.text) ?? 0));
    return Scaffold(
      appBar: AppBar(title: const Text('Class programs'), actions: [
        PopupMenuButton<Program>(
          tooltip: 'Start from an existing program',
          icon: const Icon(Icons.library_books),
          onSelected: _load,
          itemBuilder: (_) => [
            for (final p in s.programs) PopupMenuItem(value: p, child: Text(p.name)),
          ],
        ),
      ]),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(children: [
          Row(children: [
            SizedBox(
              width: 280,
              child: TextField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'Program name', isDense: true),
              ),
            ),
            const SizedBox(width: 12),
            Text('${_rows.length} parts, ${total.toStringAsFixed(1)} min'),
            const Spacer(),
            TextButton.icon(
              onPressed: () async {
                final g = await showGenerateProgramDialog(
                  context,
                  [for (final x in s.programs) x.name],
                  bookends: s.generatorBookends,
                  onBookends: s.setGeneratorBookends,
                  readiness: s.readinessOf,
                );
                if (g != null) _load(g);
              },
              icon: const Icon(Icons.auto_fix_high),
              label: const Text('Generate…'),
            ),
            TextButton.icon(
              onPressed: () => setState(() => _rows.add(_Row(const ProgramPart('New part', 5, 80, 90)))),
              icon: const Icon(Icons.add),
              label: const Text('Add part'),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: _rows.isEmpty
                  ? null
                  : () async {
                      final nav = Navigator.of(context);
                      final p = _program();
                      await s.saveProgram(p);
                      s.selectProgram(s.program);
                      nav.pop();
                    },
              icon: const Icon(Icons.save),
              label: const Text('Save & use'),
            ),
          ]),
          const SizedBox(height: 8),
          if (s.userPrograms.any((u) => u.name == _name.text.trim()))
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () async {
                  final p = s.userPrograms.firstWhere((u) => u.name == _name.text.trim());
                  await s.deleteProgram(p);
                },
                icon: const Icon(Icons.delete_outline),
                label: const Text('Delete this saved program'),
              ),
            ),
          Expanded(
            child: ReorderableListView.builder(
              buildDefaultDragHandles: true,
              itemCount: _rows.length,
              onReorderItem: (o, n) => setState(() => _rows.insert(n, _rows.removeAt(o))),
              itemBuilder: (_, i) {
                final r = _rows[i];
                return Card(
                  key: r.key,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 40, 8),
                    child: Column(children: [
                      Row(children: [
                        Text('${i + 1}'),
                        const SizedBox(width: 8),
                        ListenableBuilder(
                          listenable: r.name,
                          builder: (_, _) => Icon(iconForKey(roleIconKey(r.kind))),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: r.name,
                            decoration: const InputDecoration(labelText: 'Part', isDense: true),
                          ),
                        ),
                        const SizedBox(width: 8),
                        _num(r.minutes, 'Mins', onChanged: () => setState(() {})),
                        _num(r.minRpm, 'RPM from'),
                        _num(r.maxRpm, 'RPM to'),
                        Tooltip(
                          message: 'Pick songs for this part',
                          child: Checkbox(
                            value: r.music,
                            onChanged: (v) => setState(() => r.music = v ?? true),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Remove part',
                          icon: const Icon(Icons.close),
                          onPressed: () => setState(() => _rows.removeAt(i).dispose()),
                        ),
                      ]),
                      Row(children: [
                        DropdownButton<PartRole?>(
                          value: r.role,
                          hint: Text('Auto: ${r.kind.label}'),
                          underline: const SizedBox.shrink(),
                          items: [
                            const DropdownMenuItem<PartRole?>(value: null, child: Text('Auto (from name)')),
                            for (final role in PartRole.values)
                              DropdownMenuItem<PartRole?>(
                                  value: role,
                                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                                    Icon(iconForKey(roleIconKey(role)), size: 18),
                                    const SizedBox(width: 6),
                                    Text(role.label),
                                  ])),
                          ],
                          onChanged: (v) => setState(() => r.role = v),
                        ),
                        if (r.kind == PartRole.tabata) ...[
                          const SizedBox(width: 12),
                          DropdownButton<String>(
                            value: tabataVariant(r.variant).id,
                            underline: const SizedBox.shrink(),
                            items: [
                              for (final v in tabataVariants)
                                DropdownMenuItem(value: v.id, child: Text(v.label)),
                            ],
                            onChanged: (v) => setState(() => r.variant = v),
                          ),
                        ],
                        const SizedBox(width: 12),
                        _num(r.baseGear, 'Base gear'),
                        _num(r.gearTop, 'Top +gears'),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextField(
                            controller: r.notes,
                            decoration: const InputDecoration(labelText: 'Execution notes', isDense: true),
                          ),
                        ),
                      ]),
                    ]),
                  ),
                );
              },
            ),
          ),
        ]),
      ),
    );
  }

  Widget _num(TextEditingController c, String label, {VoidCallback? onChanged}) => Padding(
        padding: const EdgeInsets.only(right: 8),
        child: SizedBox(
          width: 80,
          child: TextField(
            controller: c,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: label, isDense: true),
            onChanged: onChanged == null ? null : (_) => onChanged(),
          ),
        ),
      );
}
