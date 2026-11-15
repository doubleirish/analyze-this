import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/output_controller.dart';

/// Mini-player button that opens the "Play on…" sheet.
class OutputButton extends StatelessWidget {
  const OutputButton({super.key});

  @override
  Widget build(BuildContext context) {
    final o = context.watch<OutputController>();
    return IconButton(
      tooltip: o.isCasting ? 'Playing on ${o.casting!.name}' : 'Play on…',
      icon: Icon(o.isCasting ? Icons.cast_connected : Icons.speaker_group_outlined,
          color: o.isCasting ? Theme.of(context).colorScheme.primary : null),
      onPressed: () => showOutputSheet(context),
    );
  }
}

Future<void> showOutputSheet(BuildContext context) {
  final o = context.read<OutputController>();
  o.refreshLocal();
  if (o.castDevices.isEmpty) o.scanCast();
  return showDialog<void>(
    context: context,
    builder: (_) => ChangeNotifierProvider.value(value: o, child: const _OutputDialog()),
  );
}

class _OutputDialog extends StatelessWidget {
  const _OutputDialog();

  @override
  Widget build(BuildContext context) {
    final o = context.watch<OutputController>();
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Play on…'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (o.error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(o.error!, style: TextStyle(color: theme.colorScheme.error)),
                ),
              Row(children: [
                Expanded(child: Text('This computer', style: theme.textTheme.titleSmall)),
                IconButton(
                  tooltip: 'Refresh devices',
                  icon: const Icon(Icons.refresh),
                  onPressed: o.refreshLocal,
                ),
                TextButton.icon(
                  icon: const Icon(Icons.bluetooth),
                  label: const Text('Bluetooth settings'),
                  onPressed: () => Process.run('cmd', ['/c', 'start', 'ms-settings:bluetooth']),
                ),
              ]),
              _tile(
                icon: Icons.computer,
                title: 'System default',
                selected: !o.isCasting && o.local.name == 'auto',
                onTap: o.selectDefault,
              ),
              for (final d in o.localDevices)
                _tile(
                  icon: Icons.speaker,
                  title: d.description.isEmpty ? d.name : d.description,
                  selected: !o.isCasting && o.local.name == d.name,
                  onTap: () => o.selectLocal(d),
                ),
              if (!o.isCasting) ...[
                const SizedBox(height: 4),
                Text('Audio delay: ${o.delayMs} ms', style: theme.textTheme.bodySmall),
                Slider(
                  value: o.delayMs.toDouble().clamp(0, 500),
                  max: 500,
                  divisions: 50,
                  label: '${o.delayMs} ms',
                  onChanged: (v) => o.setDelayMs(v.round()),
                ),
                Text('Raise this if the beat flash, waveform or lyrics run ahead of the sound '
                    '(Bluetooth is usually 150–300 ms).', style: theme.textTheme.bodySmall),
              ],
              const Divider(height: 24),
              Row(children: [
                Expanded(child: Text('Chromecast / Google Cast', style: theme.textTheme.titleSmall)),
                if (o.scanning)
                  const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                else
                  IconButton(tooltip: 'Search again', icon: const Icon(Icons.refresh), onPressed: o.scanCast),
              ]),
              for (final d in o.castDevices)
                _tile(
                  icon: Icons.cast,
                  title: d.name,
                  subtitle: d.model,
                  selected: o.casting == d,
                  busy: o.connecting == d,
                  onTap: o.casting == d ? null : () => o.cast(d),
                ),
              if (o.isCasting)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.stop_circle_outlined),
                    label: const Text('Stop casting'),
                    onPressed: o.stopCasting,
                  ),
                ),
              const SizedBox(height: 8),
              Text('Casting loses crossfade and loudness levelling. The first time, allow '
                  'analyze-this through the Windows firewall so the device can fetch songs.',
                  style: theme.textTheme.bodySmall),
            ],
          ),
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
    );
  }

  Widget _tile({
    required IconData icon,
    required String title,
    String? subtitle,
    required bool selected,
    bool busy = false,
    VoidCallback? onTap,
  }) =>
      ListTile(
        dense: true,
        leading: Icon(icon),
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: subtitle == null ? null : Text(subtitle),
        trailing: busy
            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
            : selected
                ? const Icon(Icons.check)
                : null,
        selected: selected,
        onTap: onTap,
      );
}
