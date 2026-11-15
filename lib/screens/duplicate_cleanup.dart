import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/app_state.dart';
import '../services/db.dart';

String duplicateDetails(Song best, List<Song> hidden) => [
  'Best copy: ${best.qualityDescription}\n${best.path}',
  '${hidden.length} hidden duplicate${hidden.length == 1 ? '' : 's'}:',
  for (final s in hidden) '${s.qualityDescription}\n${s.path}',
].join('\n');

Future<void> showDuplicateDetails(BuildContext context, Song best, List<Song> hidden) async {
  final songs = [best, ...hidden];
  final clean = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Duplicate copies'),
      content: SingleChildScrollView(child: SelectableText(duplicateDetails(best, hidden))),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Close')),
        if (damagedDuplicateCopies(songs).isNotEmpty)
          TextButton(onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Clean duplicates…')),
      ],
    ),
  );
  if (clean == true && context.mounted) await confirmDuplicateCleanup(context, songs);
}

Future<bool> confirmDuplicateCleanup(BuildContext context, Iterable<Song> selection) async {
  final songs = selection.toList();
  final damaged = damagedDuplicateCopies(songs);
  if (damaged.isEmpty) return false;
  final state = context.read<AppState>();
  final messenger = ScaffoldMessenger.of(context);
  var busy = false;
  return await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => PopScope(
        canPop: !busy,
        child: AlertDialog(
          title: Text('Delete ${damaged.length} damaged copies?'),
          content: SingleChildScrollView(
            child: Text([
              'Only copies tagged corrupt with a healthy copy in the same album '
                  'are eligible. Healthy MP3/WMA copies are kept. Files and sidecars '
                  'are permanently deleted; this cannot be undone.',
              'Missing, changed or no-longer-damaged files, and groups without an '
                  'unchanged healthy file, will be skipped.',
              for (final s in damaged) '${s.path}\n${s.qualityDescription}',
              if (busy) 'Checking replacements and deleting…',
            ].join('\n\n')),
          ),
          actions: [
            TextButton(onPressed: busy ? null : () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            FilledButton(
              onPressed: busy ? null : () async {
                setState(() { busy = true; });
                try {
                  final count = await state.cleanDuplicates(songs);
                  messenger.showSnackBar(SnackBar(content: Text(
                      'Deleted $count damaged copies; ${damaged.length - count} skipped.')));
                } catch (e) {
                  messenger.showSnackBar(SnackBar(content: Text(
                      'Cleanup stopped: $e. Completed deletions remain applied.')));
                }
                if (ctx.mounted) {
                  setState(() { busy = false; });
                  Navigator.pop(ctx, true);
                }
              },
              child: Text(busy ? 'Deleting…' : 'Delete damaged copies'),
            ),
          ],
        ),
      ),
    ),
  ) ?? false;
}
