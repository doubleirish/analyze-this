import 'package:flutter/material.dart';

enum PlaylistTextFormat { tracks, m3u }

typedef PlaylistText = ({String text, PlaylistTextFormat format});

class PlaylistTextDialog extends StatefulWidget {
  const PlaylistTextDialog({super.key});

  @override
  State<PlaylistTextDialog> createState() => _PlaylistTextDialogState();
}

class _PlaylistTextDialogState extends State<PlaylistTextDialog> {
  final text = TextEditingController();
  var format = PlaylistTextFormat.tracks;

  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Paste playlist'),
    content: SizedBox(
      width: 580,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<PlaylistTextFormat>(
              initialValue: format,
              decoration: const InputDecoration(labelText: 'Text format'),
              items: const [
                DropdownMenuItem(
                  value: PlaylistTextFormat.tracks,
                  child: Text('Artist - Title list'),
                ),
                DropdownMenuItem(
                  value: PlaylistTextFormat.m3u,
                  child: Text('M3U / file paths'),
                ),
              ],
              onChanged: (value) => setState(() => format = value ?? format),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: text,
              minLines: 5,
              maxLines: 10,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                labelText: 'Playlist text',
                hintText: format == PlaylistTextFormat.tracks
                    ? 'Artist - Title\n"Title" by Artist'
                    : '#EXTM3U\nC:\\Music\\song.mp3',
              ),
            ),
            const SizedBox(height: 8),
            Text(
              format == PlaylistTextFormat.tracks
                  ? 'One song per line. Uncertain matches and damaged songs are skipped.'
                  : 'One file path per line, or paste M3U text. Relative paths match by filename.',
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: text.text.trim().isEmpty
            ? null
            : () => Navigator.pop<PlaylistText>(context, (
                text: text.text,
                format: format,
              )),
        child: const Text('Import'),
      ),
    ],
  );
}
