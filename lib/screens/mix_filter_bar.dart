import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/app_state.dart';
import '../services/mix_controller.dart';
import '../services/planner.dart';

/// Genre / artist / year filter for the Mix page. With [role] it edits that
/// role's own filter (e.g. warm-up music), laid over the Mix-wide one.
class MixFilterBar extends StatefulWidget {
  const MixFilterBar({super.key, this.role, this.onChanged});
  final PartRole? role;

  /// Called after the filter has been stored, so callers can search again.
  final VoidCallback? onChanged;

  @override
  State<MixFilterBar> createState() => _MixFilterBarState();
}

class _MixFilterBarState extends State<MixFilterBar> {
  List<String> _artists = [];
  Future<List<PartSupply>>? _supply;
  String? _supplyKey;

  /// Song counts for the role, recounted only when something they depend on changes.
  Future<List<PartSupply>> _supplyFor(MixController s, MixFilter f) {
    final c = s.carriedLimits;
    final key = [
      f.toJson(), s.mixFilter.toJson(), c.clean, c.minRating, s.rotationMixes,
      identityHashCode(s.program), s.mixDbId,
    ].join('|');
    if (key != _supplyKey || _supply == null) {
      _supplyKey = key;
      _supply = s.supplyFor(widget.role!);
    }
    return _supply!;
  }

  Widget _supplyLine(BuildContext context, PartSupply p) {
    final t = Theme.of(context).textTheme.bodySmall;
    final color = p.eligible == 0
        ? Theme.of(context).colorScheme.error
        : p.eligible < 5
            ? Colors.orange.shade800
            : null;
    final why = p.why;
    return Text(
      '${p.minRpm.round()}–${p.maxRpm.round()} RPM: ${p.eligible} song${p.eligible == 1 ? '' : 's'} fit'
      '${why.isEmpty ? '' : ' (of ${p.tempo} at this tempo: $why)'}',
      style: t?.copyWith(color: color),
    );
  }

  /// Chips for the limits the Mix filter can't edit: they come from the
  /// Songs tab, Clean class or rotation.
  List<Widget> _carriedChips(MixController s) {
    final c = s.carriedLimits;
    Widget chip(IconData icon, String label, String tip) => Tooltip(
          message: tip,
          child: Chip(
            avatar: Icon(icon, size: 16),
            label: Text(label),
            visualDensity: VisualDensity.compact,
          ),
        );
    return [
      if (c.clean)
        chip(Icons.explicit_outlined, 'No explicit',
            s.cleanClass ? 'Clean class is on' : 'Copied from the Songs tab'),
      if (c.minRating > 0)
        chip(Icons.star_outline, '${c.minRating}★ or more', 'Copied from the Songs tab'),
      if (s.rotationMixes > 0)
        chip(Icons.history, 'Not in last ${s.rotationMixes} mix${s.rotationMixes == 1 ? '' : 'es'}',
            'Rotation (Mix toolbar)'),
    ];
  }

  @override
  void initState() {
    super.initState();
    context.read<AppState>().db.artistNames().then((a) {
      if (mounted) setState(() => _artists = a);
    });
  }

  MixFilter _value(MixController s) =>
      widget.role == null ? s.mixFilter : s.roleFilters[widget.role] ?? const MixFilter();

  Future<void> _set(MixController s, MixFilter f) async {
    if (widget.role == null) {
      await s.setMixFilter(f);
    } else {
      await s.setRoleFilter(widget.role!, f);
    }
    widget.onChanged?.call();
  }

  Widget _suggest(String label, String value, List<String> options, double width,
      void Function(String) commit) {
    return SizedBox(
      width: width,
      child: Autocomplete<String>(
        key: ValueKey('$label|$value'),
        initialValue: TextEditingValue(text: value),
        optionsBuilder: (v) {
          final t = v.text.trim().toLowerCase();
          if (t.isEmpty) return options.take(40);
          // options arrive most-songs-first; prefix matches rank above substring matches
          final starts = <String>[], inside = <String>[];
          for (final o in options) {
            final l = o.toLowerCase();
            if (l.startsWith(t)) {
              starts.add(o);
            } else if (l.contains(t)) {
              inside.add(o);
            }
          }
          return [...starts, ...inside].take(40);
        },
        onSelected: commit,
        fieldViewBuilder: (context, c, focus, submit) => Focus(
          // typed text counts when you click away, not only on Enter
          onFocusChange: (has) {
            if (!has && c.text.trim() != value) commit(c.text.trim());
          },
          child: TextField(
            controller: c,
            focusNode: focus,
            decoration: InputDecoration(
              labelText: label,
              isDense: true,
              suffixIcon: value.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Any',
                      iconSize: 16,
                      icon: const Icon(Icons.close),
                      onPressed: () => commit('')),
            ),
            onSubmitted: (v) => commit(v.trim()),
          ),
        ),
      ),
    );
  }

  Widget _year(String label, int? value, void Function(int?) commit) => SizedBox(
        width: 84,
        child: TextFormField(
          key: ValueKey('$label|$value'),
          initialValue: value?.toString() ?? '',
          keyboardType: TextInputType.number,
          decoration: InputDecoration(labelText: label, isDense: true),
          onFieldSubmitted: (v) => commit(int.tryParse(v.trim())),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final s = context.watch<MixController>();
    final genres = context.select<AppState, List<String>>((a) => a.genres);
    final f = _value(s);
    final bar = Wrap(spacing: 10, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
      if (widget.role != null) Text('${widget.role!.label} music:'),
      _suggest('Genre', f.genre, genres, 170, (v) => _set(s, f.copyWith(genre: v))),
      _suggest('Artist', f.artist, _artists, 190, (v) => _set(s, f.copyWith(artist: v))),
      _year('Year from', f.minYear,
          (y) => _set(s, y == null ? f.copyWith(clearMinYear: true) : f.copyWith(minYear: y))),
      _year('Year to', f.maxYear,
          (y) => _set(s, y == null ? f.copyWith(clearMaxYear: true) : f.copyWith(maxYear: y))),
      TextButton(
          onPressed: f.isEmpty ? null : () => _set(s, const MixFilter()),
          child: const Text('Reset')),
      if (widget.role == null)
        TextButton(
            onPressed: () async {
              await s.useSongsFilters();
              widget.onChanged?.call();
            },
            child: const Text('Use Songs filters')),
      if (widget.role == null) ..._carriedChips(s),
    ]);
    if (widget.role == null) return bar;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        bar,
        FutureBuilder<List<PartSupply>>(
          future: _supplyFor(s, f),
          builder: (context, snap) {
            final list = snap.data;
            if (list == null || list.isEmpty) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [for (final p in list) _supplyLine(context, p)],
              ),
            );
          },
        ),
      ],
    );
  }
}
