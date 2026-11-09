import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/app_state.dart';
import '../services/db.dart';

/// Songs that share an artist and title. The copy in the folder with the most
/// songs is suggested as the one to keep. "Remove" only drops the database
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

  void _reload() => setState(() => _groups = context.read<AppState>().duplicates());

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
          ? 'Each suggested copy (the one in the folder with fewer songs) and its sidecars '
              'will be permanently deleted. This cannot be undone.'
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
          return ListView(children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                Text('${groups.length} duplicate songs; ${removals.length} copies suggested for removal '
                    '(in folders with fewer songs)'),
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
                  subtitle: Text('${g.dirCounts[i]} songs in this folder  ·  '
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
