import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_core/shared_core.dart';

import '../services/db.dart';
import '../services/mix_controller.dart';
import '../services/mix_library.dart';
import 'class_history.dart';

/// Manages the saved mixes: search, filter (tag, length, pinned, archived),
/// sort, list or grid view, icons, and single or bulk actions (load, pin,
/// archive, tag, rename, duplicate, delete with undo).
class SavedMixesScreen extends StatefulWidget {
  const SavedMixesScreen({super.key, this.onLoad});

  /// Loads a mix into the Mix tab. Defaults to [MixController.loadMix]; pass
  /// the Mix tab's guarded load so unsaved changes are checked first. The
  /// screen closes once the mix is loaded (if the load is cancelled it stays).
  final Future<void> Function(MixInfo m)? onLoad;

  @override
  State<SavedMixesScreen> createState() => _SavedMixesScreenState();
}

class _SavedMixesScreenState extends State<SavedMixesScreen> {
  static const _viewKey = 'saved_mixes_view';
  static const _sortKey = 'saved_mixes_sort';

  final _search = TextEditingController();
  List<MixSummary>? _mixes;
  Map<int, DateTime> _taught = const {};
  Map<int, int> _damaged = const {};
  Map<int, List<String>> _art = const {};
  List<String> _allTags = const [];
  MixSort _sort = MixSort.name;
  String? _tag;
  MixLength _length = MixLength.any;
  bool _pinnedOnly = false, _archived = false, _grid = false;
  final Set<int> _selected = {};

  MixController get _c => context.read<MixController>();

  @override
  void initState() {
    super.initState();
    _restorePrefs();
    _reload();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _restorePrefs() async {
    final db = _c.db;
    final view = await db.setting(_viewKey);
    final sort = await db.setting(_sortKey);
    if (!mounted) return;
    setState(() {
      _grid = view == 'grid';
      _sort = MixSort.values.firstWhere((s) => s.name == sort, orElse: () => _sort);
    });
  }

  Future<void> _reload() async {
    final db = _c.db;
    final m = await db.mixSummaries();
    final t = await db.lastTaught();
    final d = await db.damagedCountByMix();
    final a = await db.mixArtPaths();
    final tags = await db.allMixTags();
    if (!mounted) return;
    setState(() {
      _mixes = m;
      _taught = t;
      _damaged = d;
      _art = a;
      _allTags = tags;
      if (_tag != null && !tags.contains(_tag)) _tag = null;
      _selected.retainAll({for (final x in m) x.id});
    });
  }

  List<MixSummary> _visible() => arrangeMixes(
      _mixes ?? const [],
      MixFilter(
          query: _search.text,
          tag: _tag,
          length: _length,
          pinnedOnly: _pinnedOnly,
          archived: _archived),
      _sort,
      taught: _taught);

  static String _len(double sec) {
    final m = sec ~/ 60, s = (sec % 60).round();
    return m >= 60
        ? '${m ~/ 60}h ${(m % 60).toString().padLeft(2, '0')}m'
        : '$m:${s.toString().padLeft(2, '0')}';
  }

  static String _date(int? ms) {
    if (ms == null) return 'unknown date';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  void _snack(String msg, {SnackBarAction? action}) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(msg), action: action));

  Future<String?> _askText(String title, String initial, String action,
      {String label = 'Name', List<String> suggestions = const []}) {
    final ctl = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextField(
            controller: ctl,
            autofocus: true,
            decoration: InputDecoration(labelText: label),
            onSubmitted: (v) => Navigator.pop(ctx, v),
          ),
          if (suggestions.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final s in suggestions)
                ActionChip(label: Text(s), onPressed: () => Navigator.pop(ctx, s)),
            ]),
          ],
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctl.text), child: Text(action)),
        ],
      ),
    ).whenComplete(ctl.dispose);
  }

  // ---- single-mix actions ----

  Future<void> _load(MixSummary m) async {
    final c = _c;
    final messenger = ScaffoldMessenger.of(context);
    await (widget.onLoad ?? c.loadMix)(m);
    if (mounted && c.mixDbId == m.id) {
      Navigator.pop(context);
      final n = c.damagedIndexes.length;
      if (n > 0) {
        messenger.showSnackBar(SnackBar(
          content: Text('$n song${n == 1 ? '' : 's'} in this mix ${n == 1 ? 'has' : 'have'} damaged audio'),
          action: SnackBarAction(label: 'Replace all', onPressed: () => c.replaceAllDamaged()),
        ));
      }
    }
  }

  Future<void> _markTaught(MixSummary m) async {
    final paths = await _c.db.mixPaths(m.id);
    if (!mounted) return;
    if (await markAsTaught(context, mixId: m.id, mixName: m.name, paths: paths)) {
      await _reload();
    }
  }

  Future<void> _history(MixSummary m) async {
    await showDialog<void>(
        context: context,
        builder: (_) => ClassHistoryDialog(mixId: m.id, title: 'Classes taught: ${m.name}'));
    await _reload();
  }

  Future<void> _rename(MixSummary m) async {
    final name = (await _askText('Rename mix', m.name, 'Rename'))?.trim();
    if (name == null || name.isEmpty || name == m.name) return;
    try {
      await _c.renameMix(m, name);
    } on MixNameTaken catch (e) {
      _snack(e.toString());
      return;
    }
    await _reload();
  }

  Future<void> _duplicate(MixSummary m) async {
    final taken = {for (final x in _mixes ?? const <MixSummary>[]) x.name};
    var suggestion = '${m.name} (copy)';
    for (var i = 2; taken.contains(suggestion); i++) {
      suggestion = '${m.name} (copy $i)';
    }
    final name = (await _askText('Duplicate mix', suggestion, 'Duplicate'))?.trim();
    if (name == null || name.isEmpty) return;
    try {
      await _c.duplicateMix(m, name);
    } on MixNameTaken catch (e) {
      _snack(e.toString());
      return;
    }
    await _reload();
  }

  Future<void> _pickIcon(MixSummary m) async {
    final db = _c.db;
    final r = await MixIconPicker.show(context, initial: m.icon, artPaths: _art[m.id] ?? const []);
    if (r == null) return;
    await db.setMixIcon(m.id, identical(r, MixIconPicker.collage) ? null : r);
    await _reload();
  }

  Future<void> _editTags(MixSummary m) async {
    final db = _c.db;
    final result = await showDialog<List<String>>(
        context: context, builder: (_) => _TagsDialog(name: m.name, tags: m.tags, known: _allTags));
    if (result == null) return;
    for (final t in m.tags.where((t) => !result.contains(t))) {
      await db.tagMixes([m.id], t, remove: true);
    }
    for (final t in result.where((t) => !m.tags.contains(t))) {
      await db.tagMixes([m.id], t);
    }
    await _reload();
  }

  // ---- bulk actions (also used for one mix) ----

  List<MixSummary> get _selectedMixes =>
      [for (final m in _mixes ?? const <MixSummary>[]) if (_selected.contains(m.id)) m];

  Future<void> _setPinned(List<MixSummary> ms, bool on) async {
    await _c.db.setMixesPinned([for (final m in ms) m.id], on);
    await _reload();
  }

  Future<void> _setArchived(List<MixSummary> ms, bool on) async {
    final ids = [for (final m in ms) m.id];
    await _c.db.setMixesArchived(ids, on);
    _selected.removeAll(ids);
    await _reload();
    if (!mounted) return;
    final what = ms.length == 1 ? '"${ms.single.name}"' : '${ms.length} mixes';
    _snack('${on ? 'Archived' : 'Restored'} $what',
        action: SnackBarAction(
            label: 'Undo',
            onPressed: () async {
              await _c.db.setMixesArchived(ids, !on);
              await _reload();
            }));
  }

  Future<void> _tagSelected() async {
    final ms = _selectedMixes;
    final tag = (await _askText('Tag ${ms.length} mix${ms.length == 1 ? '' : 'es'}', '', 'Add tag',
            label: 'Tag', suggestions: _allTags))
        ?.trim();
    if (tag == null || tag.isEmpty) return;
    await _c.db.tagMixes([for (final m in ms) m.id], tag);
    await _reload();
  }

  Future<void> _delete(List<MixSummary> ms) async {
    if (ms.isEmpty) return;
    final what = ms.length == 1 ? 'the saved mix "${ms.single.name}"' : '${ms.length} saved mixes';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ms.length == 1 ? 'Delete mix?' : 'Delete ${ms.length} mixes?'),
        content: Text('Delete $what? You can undo this right after.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final c = _c;
    final gone = await c.deleteMixes([for (final m in ms) m.id]);
    _selected.clear();
    await _reload();
    if (!mounted) return;
    _snack('Deleted ${ms.length == 1 ? '"${ms.single.name}"' : '${ms.length} mixes'}',
        action: SnackBarAction(
            label: 'Undo',
            onPressed: () async {
              await c.restoreMixes(gone);
              await _reload();
            }));
  }

  void _toggle(MixSummary m) => setState(() {
        if (!_selected.remove(m.id)) _selected.add(m.id);
      });

  // ---- building ----

  Widget _icon(MixSummary m, double size) {
    final n = _damaged[m.id];
    final icon = MixIcon(spec: m.icon, artPaths: _art[m.id] ?? const [], size: size);
    if (n == null) return icon;
    return Badge(
      label: Text('$n'),
      child: Tooltip(message: '$n damaged song${n == 1 ? '' : 's'}: load the mix to replace them', child: icon),
    );
  }

  List<String> _details(MixSummary m) => [
        '${m.songCount} song${m.songCount == 1 ? '' : 's'}',
        _len(m.totalSeconds),
        if (m.programName != null) m.programName!,
        if (_taught[m.id] case final t?) 'taught ${formatTaughtDay(t)}',
        if (_damaged[m.id] case final n?) '$n damaged',
      ];

  Widget _menu(MixSummary m) => PopupMenuButton<String>(
        tooltip: 'More actions',
        onSelected: (v) => switch (v) {
          'taught' => _markTaught(m),
          'history' => _history(m),
          'rename' => _rename(m),
          'duplicate' => _duplicate(m),
          'icon' => _pickIcon(m),
          'tags' => _editTags(m),
          'pin' => _setPinned([m], !m.pinned),
          'archive' => _setArchived([m], !m.archived),
          'select' => _toggle(m),
          _ => _delete([m]),
        },
        itemBuilder: (_) => [
          PopupMenuItem(
              value: 'taught',
              enabled: m.songCount > 0,
              child: const ListTile(leading: Icon(Icons.event_available), title: Text('Mark as taught'))),
          const PopupMenuItem(
              value: 'history', child: ListTile(leading: Icon(Icons.history), title: Text('Class history'))),
          const PopupMenuDivider(),
          const PopupMenuItem(
              value: 'icon', child: ListTile(leading: Icon(Icons.palette_outlined), title: Text('Icon…'))),
          const PopupMenuItem(
              value: 'tags', child: ListTile(leading: Icon(Icons.label_outline), title: Text('Tags…'))),
          const PopupMenuItem(
              value: 'rename', child: ListTile(leading: Icon(Icons.edit_outlined), title: Text('Rename'))),
          const PopupMenuItem(
              value: 'duplicate', child: ListTile(leading: Icon(Icons.copy_outlined), title: Text('Duplicate'))),
          PopupMenuItem(
              value: 'pin',
              child: ListTile(
                  leading: Icon(m.pinned ? Icons.push_pin : Icons.push_pin_outlined),
                  title: Text(m.pinned ? 'Unpin' : 'Pin to top'))),
          PopupMenuItem(
              value: 'archive',
              child: ListTile(
                  leading: Icon(m.archived ? Icons.unarchive_outlined : Icons.archive_outlined),
                  title: Text(m.archived ? 'Restore from archive' : 'Archive'))),
          const PopupMenuItem(
              value: 'select', child: ListTile(leading: Icon(Icons.check_box_outlined), title: Text('Select'))),
          const PopupMenuDivider(),
          const PopupMenuItem(
              value: 'delete', child: ListTile(leading: Icon(Icons.delete_outline), title: Text('Delete'))),
        ],
      );

  Widget _tile(MixSummary m, int? loadedId) {
    final selecting = _selected.isNotEmpty;
    return ListTile(
      selected: m.id == loadedId || _selected.contains(m.id),
      leading: selecting
          ? Checkbox(value: _selected.contains(m.id), onChanged: (_) => _toggle(m))
          : InkWell(onTap: () => _pickIcon(m), child: _icon(m, 44)),
      title: Row(children: [
        if (m.pinned) const Padding(padding: EdgeInsets.only(right: 4), child: Icon(Icons.push_pin, size: 16)),
        Flexible(child: Text(m.name, overflow: TextOverflow.ellipsis)),
      ]),
      subtitle: Text([
        ..._details(m),
        'saved ${_date(m.savedAt)}',
        if (m.tags.isNotEmpty) m.tags.map((t) => '#$t').join(' '),
      ].join(' · ')),
      onTap: selecting ? () => _toggle(m) : () => _load(m),
      onLongPress: () => _toggle(m),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        IconButton(tooltip: 'Load', icon: const Icon(Icons.folder_open), onPressed: () => _load(m)),
        _menu(m),
      ]),
    );
  }

  Widget _card(MixSummary m, int? loadedId) {
    final scheme = Theme.of(context).colorScheme;
    final chosen = _selected.contains(m.id);
    return Card(
      clipBehavior: Clip.antiAlias,
      color: chosen
          ? scheme.secondaryContainer
          : m.id == loadedId
              ? scheme.primaryContainer
              : null,
      child: InkWell(
        onTap: _selected.isNotEmpty ? () => _toggle(m) : () => _load(m),
        onLongPress: () => _toggle(m),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _icon(m, 72),
              const Spacer(),
              Column(children: [
                if (m.pinned) const Icon(Icons.push_pin, size: 16),
                _menu(m),
              ]),
            ]),
            const SizedBox(height: 6),
            Text(m.name, maxLines: 2, overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleSmall),
            Text(_details(m).join(' · '),
                maxLines: 3, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
            if (m.tags.isNotEmpty)
              Text(m.tags.map((t) => '#$t').join(' '),
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
          ]),
        ),
      ),
    );
  }

  PreferredSizeWidget _appBar() {
    if (_selected.isEmpty) {
      return AppBar(title: const Text('Saved mixes'), actions: [
        IconButton(
          tooltip: _grid ? 'List view' : 'Grid view',
          icon: Icon(_grid ? Icons.view_list : Icons.grid_view),
          onPressed: () {
            setState(() => _grid = !_grid);
            _c.db.setSetting(_viewKey, _grid ? 'grid' : 'list');
          },
        ),
      ]);
    }
    final ms = _selectedMixes;
    final allPinned = ms.every((m) => m.pinned);
    return AppBar(
      leading: IconButton(
          tooltip: 'Clear selection',
          icon: const Icon(Icons.close),
          onPressed: () => setState(_selected.clear)),
      title: Text('${_selected.length} selected'),
      actions: [
        IconButton(
            tooltip: 'Select all shown',
            icon: const Icon(Icons.select_all),
            onPressed: () => setState(() => _selected.addAll(_visible().map((m) => m.id)))),
        IconButton(
            tooltip: allPinned ? 'Unpin' : 'Pin',
            icon: Icon(allPinned ? Icons.push_pin : Icons.push_pin_outlined),
            onPressed: () => _setPinned(ms, !allPinned)),
        IconButton(tooltip: 'Add tag', icon: const Icon(Icons.label_outline), onPressed: _tagSelected),
        IconButton(
            tooltip: _archived ? 'Restore from archive' : 'Archive',
            icon: Icon(_archived ? Icons.unarchive_outlined : Icons.archive_outlined),
            onPressed: () => _setArchived(ms, !_archived)),
        IconButton(tooltip: 'Delete', icon: const Icon(Icons.delete_outline), onPressed: () => _delete(ms)),
      ],
    );
  }

  Widget _filters() {
    final archivedCount = (_mixes ?? const <MixSummary>[]).where((m) => m.archived).length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Column(children: [
        Row(children: [
          Expanded(
            child: TextField(
              controller: _search,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Search by name, program or tag',
                isDense: true,
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
          const SizedBox(width: 12),
          const Text('Sort: '),
          DropdownButton<MixSort>(
            value: _sort,
            onChanged: (v) {
              if (v == null) return;
              setState(() => _sort = v);
              _c.db.setSetting(_sortKey, v.name);
            },
            items: [for (final s in MixSort.values) DropdownMenuItem(value: s, child: Text(s.label))],
          ),
        ]),
        const SizedBox(height: 6),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            FilterChip(
              avatar: const Icon(Icons.push_pin_outlined, size: 18),
              label: const Text('Pinned'),
              selected: _pinnedOnly,
              onSelected: (v) => setState(() => _pinnedOnly = v),
            ),
            const SizedBox(width: 6),
            FilterChip(
              avatar: const Icon(Icons.archive_outlined, size: 18),
              label: Text('Archived ($archivedCount)'),
              selected: _archived,
              onSelected: (v) => setState(() {
                _archived = v;
                _selected.clear();
              }),
            ),
            const SizedBox(width: 12),
            DropdownButton<MixLength>(
              value: _length,
              onChanged: (v) => setState(() => _length = v ?? _length),
              items: [for (final l in MixLength.values) DropdownMenuItem(value: l, child: Text(l.label))],
            ),
            const SizedBox(width: 12),
            for (final t in _allTags) ...[
              FilterChip(
                label: Text('#$t'),
                selected: _tag == t,
                onSelected: (v) => setState(() => _tag = v ? t : null),
              ),
              const SizedBox(width: 6),
            ],
          ]),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final loadedId = context.select<MixController, int?>((c) => c.mixDbId);
    final list = _visible();
    return Scaffold(
      appBar: _appBar(),
      body: Column(
        children: [
          _filters(),
          Expanded(
            child: _mixes == null
                ? const Center(child: CircularProgressIndicator())
                : list.isEmpty
                    ? Center(
                        child: Text(_mixes!.isEmpty
                            ? 'No saved mixes yet'
                            : _archived
                                ? 'No archived mixes match'
                                : 'No matching mixes'))
                    : _grid
                        ? GridView.builder(
                            padding: const EdgeInsets.all(8),
                            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                                maxCrossAxisExtent: 220, mainAxisExtent: 210),
                            itemCount: list.length,
                            itemBuilder: (_, i) => _card(list[i], loadedId),
                          )
                        : ListView.builder(
                            itemCount: list.length,
                            itemBuilder: (_, i) => _tile(list[i], loadedId),
                          ),
          ),
        ],
      ),
    );
  }
}

/// Edits one mix's tags: remove chips, add new or known tags.
class _TagsDialog extends StatefulWidget {
  const _TagsDialog({required this.name, required this.tags, required this.known});
  final String name;
  final List<String> tags, known;

  @override
  State<_TagsDialog> createState() => _TagsDialogState();
}

class _TagsDialogState extends State<_TagsDialog> {
  late final _tags = List.of(widget.tags);
  final _ctl = TextEditingController();

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  void _add(String t) {
    t = t.trim();
    if (t.isEmpty || _tags.contains(t)) return;
    setState(() => _tags.add(t));
    _ctl.clear();
  }

  @override
  Widget build(BuildContext context) {
    final unused = [for (final t in widget.known) if (!_tags.contains(t)) t];
    return AlertDialog(
      title: Text('Tags: ${widget.name}'),
      content: SizedBox(
        width: 360,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final t in _tags) InputChip(label: Text(t), onDeleted: () => setState(() => _tags.remove(t))),
            if (_tags.isEmpty) const Text('No tags yet'),
          ]),
          const SizedBox(height: 8),
          TextField(
            controller: _ctl,
            decoration: InputDecoration(
              labelText: 'New tag',
              hintText: 'e.g. Tuesday, hills, beginners',
              suffixIcon: IconButton(icon: const Icon(Icons.add), onPressed: () => _add(_ctl.text)),
            ),
            onSubmitted: _add,
          ),
          if (unused.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final t in unused) ActionChip(label: Text(t), onPressed: () => _add(t)),
            ]),
          ],
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            _add(_ctl.text);
            Navigator.pop(context, _tags);
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
