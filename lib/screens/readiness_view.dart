import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/app_state.dart';
import '../services/planner.dart';
import '../services/readiness.dart';

/// Insights: whether the library has enough songs for each part of a program
/// (with the Mix filters), plus RPM-band coverage per role.
class ProgramReadinessView extends StatefulWidget {
  const ProgramReadinessView({super.key});

  @override
  State<ProgramReadinessView> createState() => _ProgramReadinessViewState();
}

class _ProgramReadinessViewState extends State<ProgramReadinessView> {
  /// Selected program; null = the current mix program.
  Program? _program;
  Future<(List<PartReadiness>, List<RoleCoverage>)>? _data;

  Future<(List<PartReadiness>, List<RoleCoverage>)> _load(AppState s, Program p) async => (
        await programReadiness(s.db, p, base: s.mixer.mixBase, recentWeeks: s.recentWeeks),
        await rpmCoverage(s.db, p),
      );

  void _select(AppState s, Program p) => setState(() {
        _program = p;
        _data = _load(s, p);
      });

  static String _rpm(ProgramPart p) => p.minRpm.round() == p.maxRpm.round()
      ? '${p.minRpm.round()}'
      : '${p.minRpm.round()}–${p.maxRpm.round()}';

  static String _num(double v) => v % 1 == 0 ? '${v.round()}' : v.toStringAsFixed(1);

  Widget _chip(ReadinessStatus st) {
    final (label, color) = switch (st) {
      ReadinessStatus.ok => ('OK', Colors.green),
      ReadinessStatus.thin => ('Thin', Colors.orange),
      ReadinessStatus.empty => ('Empty', Colors.red),
    };
    return Chip(
      label: Text(label),
      backgroundColor: color.withValues(alpha: 0.25),
      side: BorderSide(color: color),
      visualDensity: VisualDensity.compact,
    );
  }

  Widget _coverage(BuildContext ctx, RoleCoverage c) {
    final max = c.bands.fold(1, (a, b) => b.songs > a ? b.songs : a);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 4),
        child: Text('${c.role.label} (${_num(c.minRpm)}–${_num(c.maxRpm)} RPM)',
            style: Theme.of(ctx).textTheme.titleSmall),
      ),
      for (final b in c.bands)
        Row(children: [
          SizedBox(width: 90, child: Text('${_num(b.lo)}–${_num(b.hi)}')),
          Expanded(child: LinearProgressIndicator(value: b.songs / max, minHeight: 10)),
          SizedBox(width: 60, child: Text('  ${b.songs}')),
        ]),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final current = s.mixer.program;
    final options = [current, for (final p in s.mixer.programs) if (p.name != current.name) p];
    final program = _program ?? current;
    _data ??= _load(s, program);
    var selected = options.indexWhere((p) => identical(p, program));
    if (selected < 0) selected = options.indexWhere((p) => p.name == program.name);
    return ListView(padding: const EdgeInsets.all(16), children: [
      Row(children: [
        const Text('Program: '),
        DropdownButton<int>(
          value: selected < 0 ? 0 : selected,
          items: [
            for (var i = 0; i < options.length; i++)
              DropdownMenuItem(
                  value: i, child: Text(i == 0 ? '${options[i].name} (current mix)' : options[i].name)),
          ],
          onChanged: (i) {
            if (i != null) _select(s, options[i]);
          },
        ),
        IconButton(
          tooltip: 'Recount',
          icon: const Icon(Icons.refresh),
          onPressed: () => _select(s, program),
        ),
      ]),
      Text('Uses the Mix filters. Fresh = not taught in the last ${s.recentWeeks} '
          'week${s.recentWeeks == 1 ? '' : 's'}. Thin = fewer than $thinFactor× the songs '
          'needed are fresh. Click a part to see its songs.'),
      FutureBuilder<(List<PartReadiness>, List<RoleCoverage>)>(
        future: _data,
        builder: (ctx, snap) {
          if (snap.hasError) return Text('Could not check readiness: ${snap.error}');
          final d = snap.data;
          if (d == null) {
            return const Padding(
                padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()));
          }
          final (parts, coverage) = d;
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                showCheckboxColumn: false,
                columns: const [
                  DataColumn(label: Text('Part')),
                  DataColumn(label: Text('Role')),
                  DataColumn(label: Text('RPM')),
                  DataColumn(label: Text('Mins'), numeric: true),
                  DataColumn(label: Text('Candidates'), numeric: true),
                  DataColumn(label: Text('Needed'), numeric: true),
                  DataColumn(label: Text('Fresh'), numeric: true),
                  DataColumn(label: Text('Status')),
                ],
                rows: [
                  for (final r in parts)
                    DataRow(
                      onSelectChanged: (_) {
                        Navigator.of(ctx).popUntil((route) => route.isFirst);
                        s.showInSongs(r.query.copyWith(limit: 500));
                      },
                      cells: [
                        DataCell(Text(r.part.name)),
                        DataCell(Text(r.part.kind.label)),
                        DataCell(Text(_rpm(r.part))),
                        DataCell(Text(_num(r.part.minutes))),
                        DataCell(Text('${r.candidates}')),
                        DataCell(Text('${r.needed}')),
                        DataCell(Text('${r.fresh}')),
                        DataCell(_chip(r.status)),
                      ],
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text('Library tempo coverage by role (half/double time folded in)',
                  style: Theme.of(ctx).textTheme.titleMedium),
            ),
            for (final c in coverage) _coverage(ctx, c),
          ]);
        },
      ),
    ]);
  }
}
