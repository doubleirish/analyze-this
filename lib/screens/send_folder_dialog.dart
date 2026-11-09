import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:shared_core/shared_core.dart';

import '../services/batch_send.dart';

/// Sends every `.beatsmix` file in a folder to a USB/Wi-Fi-debugging phone
/// with adb, one after another, with progress. Files that fail are listed and
/// the rest still go.
class SendFolderDialog extends StatefulWidget {
  const SendFolderDialog({super.key, this.initialFolder, this.adbPath, this.skipAdb = false});
  final String? initialFolder;
  final String? adbPath;

  /// Don't look for adb or phones (tests).
  final bool skipAdb;

  @override
  State<SendFolderDialog> createState() => _SendFolderDialogState();
}

class _SendFolderDialogState extends State<SendFolderDialog> {
  String? _folder;
  List<BeatsmixFile> _files = [];
  final Set<String> _picked = {};

  String? _adb;
  List<AdbDevice> _devices = [];
  String? _serial;
  bool _looked = false;

  bool _busy = false;
  bool _cancel = false;
  int _index = 0;
  String _current = '';
  double? _fileProgress;
  String _what = '';
  List<BatchItemResult> _results = [];

  @override
  void initState() {
    super.initState();
    if (widget.initialFolder != null) _setFolder(widget.initialFolder!);
    _loadDevices();
  }

  void _setFolder(String dir) {
    _folder = dir;
    _files = findBeatsmixFiles(Directory(dir));
    _picked
      ..clear()
      ..addAll(_files.map((f) => f.file.path));
    _results = [];
  }

  Future<void> _chooseFolder() async {
    final dir = await FilePicker.getDirectoryPath(dialogTitle: 'Folder of .beatsmix files');
    if (dir != null && mounted) setState(() => _setFolder(dir));
  }

  Future<void> _loadDevices() async {
    if (widget.skipAdb) {
      setState(() => _looked = true);
      return;
    }
    final adb = await UsbTransport.findAdb([if (widget.adbPath != null) widget.adbPath!]);
    var devices = <AdbDevice>[];
    if (adb != null) {
      try {
        devices = await UsbTransport(adb).devices();
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _adb = adb;
      _devices = devices;
      _looked = true;
      if (_serial == null || !devices.any((d) => d.serial == _serial)) {
        _serial = devices.where((d) => d.ready).firstOrNull?.serial;
      }
    });
  }

  List<BeatsmixFile> get _selected => [for (final f in _files) if (_picked.contains(f.file.path)) f];

  int get _selectedBytes => _selected.fold(0, (a, f) => a + f.bytes);

  Future<void> _send() async {
    final adb = _adb, serial = _serial;
    if (adb == null || serial == null) return;
    final files = _selected;
    final usb = UsbTransport(adb);
    setState(() {
      _busy = true;
      _cancel = false;
      _results = [];
      _index = 0;
      _fileProgress = null;
    });
    final free = await usb.freeBytes(serial);
    if (free != null && free < _selectedBytes && mounted) {
      setState(() {
        _busy = false;
        _results = [
          BatchItemResult('Not enough space', BatchStatus.failed,
              error: 'The phone has ${formatBytes(free)} free; these files are '
                  '${formatBytes(_selectedBytes)}.')
        ];
      });
      return;
    }
    final results = await BatchSender(
      (pkg, {onProgress, cancelled}) =>
          usb.send(serial, pkg, onProgress: onProgress, cancelled: cancelled),
    ).run(
      files,
      cancelled: () => _cancel,
      onItem: (i, name) {
        if (mounted) {
          setState(() {
            _index = i;
            _current = name;
            _fileProgress = null;
            _what = '';
          });
        }
      },
      onProgress: (d, t, what) {
        if (mounted) {
          setState(() {
            _fileProgress = t == 0 ? null : d / t;
            _what = what;
          });
        }
      },
    );
    if (mounted) {
      setState(() {
        _busy = false;
        _results = results;
      });
    }
  }

  String _describe(BatchItemResult r) => switch (r.status) {
        BatchStatus.imported => 'imported · ${r.sent} file(s), ${formatBytes(r.bytes)}, '
            '${r.skipped} song(s) already there',
        BatchStatus.sent => 'copied, not confirmed yet — unlock the phone / open beats-me',
        BatchStatus.cancelled => 'skipped (cancelled)',
        BatchStatus.failed => 'failed: ${r.error}',
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ready = _devices.where((d) => d.ready).toList();
    final canSend = !_busy && _selected.isNotEmpty && _adb != null && _serial != null;
    final ok = _results.where((r) => r.ok).length;
    return AlertDialog(
      title: const Text('Send a folder to the phone'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Expanded(
                    child: Text(_folder ?? 'No folder chosen',
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium)),
                TextButton.icon(
                    onPressed: _busy ? null : _chooseFolder,
                    icon: const Icon(Icons.folder_open),
                    label: const Text('Choose folder…')),
              ]),
              const SizedBox(height: 8),
              if (!_looked)
                const LinearProgressIndicator()
              else if (_adb == null)
                const Text('adb was not found. Install Android platform-tools and switch on USB '
                    'debugging (or Wireless debugging) on the phone.')
              else if (_devices.isEmpty)
                Row(children: [
                  const Expanded(child: Text('No phone found. Connect it and allow USB debugging.')),
                  TextButton(onPressed: _loadDevices, child: const Text('Search again')),
                ])
              else
                Row(children: [
                  const Text('Phone: '),
                  DropdownButton<String>(
                    value: _serial,
                    hint: const Text('Choose'),
                    onChanged: _busy ? null : (v) => setState(() => _serial = v),
                    items: [
                      for (final d in _devices)
                        DropdownMenuItem(
                            value: d.ready ? d.serial : null,
                            enabled: d.ready,
                            child: Text(d.ready ? d.label : '${d.label} — ${d.advice}')),
                    ],
                  ),
                  IconButton(
                      tooltip: 'Search again',
                      onPressed: _busy ? null : _loadDevices,
                      icon: const Icon(Icons.refresh)),
                ]),
              if (_looked && _adb != null && _devices.isNotEmpty && ready.isEmpty)
                Text('No phone is ready: ${_devices.first.advice}',
                    style: TextStyle(color: theme.colorScheme.error)),
              const Divider(),
              if (_folder != null && _files.isEmpty)
                const Text('No .beatsmix files in this folder.'),
              if (_files.isNotEmpty) ...[
                Row(children: [
                  Expanded(
                      child: Text('${_selected.length} of ${_files.length} selected · '
                          '${formatBytes(_selectedBytes)}')),
                  TextButton(
                      onPressed: _busy
                          ? null
                          : () => setState(() => _picked.length == _files.length
                              ? _picked.clear()
                              : _picked.addAll(_files.map((f) => f.file.path))),
                      child: Text(_picked.length == _files.length ? 'Select none' : 'Select all')),
                ]),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 260),
                  child: ListView(shrinkWrap: true, children: [
                    for (final f in _files)
                      CheckboxListTile(
                        dense: true,
                        controlAffinity: ListTileControlAffinity.leading,
                        value: _picked.contains(f.file.path),
                        onChanged: _busy
                            ? null
                            : (v) => setState(
                                () => v == true ? _picked.add(f.file.path) : _picked.remove(f.file.path)),
                        title: Text(f.name, overflow: TextOverflow.ellipsis),
                        subtitle: Text(formatBytes(f.bytes)),
                      ),
                  ]),
                ),
              ],
              if (_busy) ...[
                const SizedBox(height: 12),
                Text('Sending ${_index + 1} of ${_selected.length}: $_current'),
                const SizedBox(height: 4),
                LinearProgressIndicator(value: _fileProgress),
                if (_what.isNotEmpty)
                  Text(p.basename(_what), style: theme.textTheme.bodySmall, overflow: TextOverflow.ellipsis),
              ],
              if (_results.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text('$ok of ${_results.length} sent', style: theme.textTheme.titleSmall),
                for (final r in _results)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Icon(r.ok ? Icons.check_circle_outline : Icons.error_outline,
                          size: 16, color: r.ok ? Colors.green : theme.colorScheme.error),
                      const SizedBox(width: 6),
                      Expanded(child: Text('${r.name}: ${_describe(r)}', style: theme.textTheme.bodySmall)),
                    ]),
                  ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        if (_busy)
          TextButton(onPressed: _cancel ? null : () => setState(() => _cancel = true), child: const Text('Cancel'))
        else
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
        FilledButton.icon(
          onPressed: canSend ? _send : null,
          icon: const Icon(Icons.phone_android),
          label: Text(_busy ? 'Sending…' : 'Send ${_selected.length} file(s)'),
        ),
      ],
    );
  }
}
