import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/app_state.dart';
import '../services/db.dart';
import 'duplicate_cleanup.dart';

/// Songs that share an artist and title. Health and estimated quality determine
/// the suggested keeper. "Remove" only drops the database
/// entry; "Delete file" removes it from disk after confirmation.
class DuplicatesScreen extends StatefulWidget {
  const DuplicatesScreen({super.key});

  @override
  State<DuplicatesScreen> createState() => _DuplicatesScreenState();
}

class _DuplicatesScreenState extends State<DuplicatesScreen> {
  late Future<List<DupGroup>> _groups;

  @override
  void initState() {
    super.initState();
    _groups = context.read<AppState>().duplicates();
  }

  void _reload() {
    if (mounted) setState(() { _groups = context.read<AppState>().duplicates(); });
  }

  Future<bool> _confirm(String title, String body, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(action)),
          ],
        ),
      ) ??
      false;

  Future<void> _applyAll(List<Song> songs, {required bool deleteFiles}) async {
    final s = context.read<AppState>();
    final ok = await _confirm(
      deleteFiles ? 'Delete ${songs.length} files from disk?' : 'Remove ${songs.length} songs?',
      deleteFiles
          ? 'Each lower-ranked copy and its sidecars will be permanently deleted, '
              'including healthy Android-compatible copies. Different album versions '
              'can share a title. This cannot be undone.\n\n${songs.map((s) => s.path).join('\n')}'
          : 'The suggested copies are dropped from the library; files stay on disk.',
      deleteFiles ? 'Delete files' : 'Remove',
    );
    if (!ok) return;
    for (final song in songs) {
      deleteFiles ? await s.deleteSongFile(song) : await s.removeFromLibrary(song);
    }
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppState>();
    return Scaffold(
      appBar: AppBar(title: const Text('Duplicate songs')),
      body: FutureBuilder<List<DupGroup>>(
        future: _groups,
        builder: (_, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final groups = snap.data!;
          if (groups.isEmpty) return const Center(child: Text('No duplicates found'));
          final removals = [for (final g in groups) ...g.suggestedRemovals];
          final all = [for (final g in groups) ...g.songs];
          return ListView(children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                Text('${groups.length} duplicate songs; ${removals.length} copies suggested for removal '
                    '(health, estimated bitrate, format)'),
                if (damagedDuplicateCopies(all).isNotEmpty)
                  FilledButton.tonal(
                    onPressed: () async {
                      await confirmDuplicateCleanup(context, all);
                      _reload();
                    },
                    child: const Text('Delete damaged copies…'),
                  ),
                FilledButton.tonal(
                    onPressed: () => _applyAll(removals, deleteFiles: false),
                    child: const Text('Remove all suggested from library')),
                FilledButton.tonal(
                    onPressed: () => _applyAll(removals, deleteFiles: true),
                    child: const Text('Delete all suggested files…')),
              ]),
            ),
            for (final g in groups) ...[
              ListTile(title: Text(g.songs.first.display), tileColor: Colors.white10),
              for (var i = 0; i < g.songs.length; i++)
                ListTile(
                  dense: true,
                  leading: Chip(
                    label: Text(i == g.keeper ? 'Keep' : 'Suggest remove'),
                    backgroundColor:
                        i == g.keeper ? Colors.green.withValues(alpha: 0.3) : Colors.orange.withValues(alpha: 0.3),
                  ),
                  title: Text(g.songs[i].path),
                  subtitle: Text('${g.songs[i].qualityDescription}  ·  '
                      '${g.dirCounts[i]} songs in this folder  ·  '
                      '${g.songs[i].medianBpm?.round() ?? '-'} BPM'),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    IconButton(
                      tooltip: 'Remove from database (file is kept)',
                      icon: const Icon(Icons.remove_circle_outline),
                      onPressed: () async {
                        await s.removeFromLibrary(g.songs[i]);
                        _reload();
                      },
                    ),
                    IconButton(
                      tooltip: 'Delete file from disk',
                      icon: const Icon(Icons.delete_forever),
                      onPressed: () async {
                        if (await _confirm('Delete this file?',
                            '${g.songs[i].path}\n\nThe file and its sidecars are permanently deleted.',
                            'Delete')) {
                          await s.deleteSongFile(g.songs[i]);
                          _reload();
                        }
                      },
                    ),
                  ]),
                ),
            ],
          ]);
        },
      ),
    );
  }
}
