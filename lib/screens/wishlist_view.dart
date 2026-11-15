import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_core/shared_core.dart' show TrackArt;

import '../services/app_state.dart';
import '../services/song_models.dart' show SongQuality;
import '../services/wishlist_controller.dart';
import '../services/wishlist_match.dart';
import 'browse_screens.dart' show openAlbum;

class WishlistPage extends StatelessWidget {
  const WishlistPage({super.key});
  @override
  Widget build(BuildContext context) =>
      const Scaffold(appBar: _WishlistBar(), body: WishlistView());
}

class _WishlistBar extends StatelessWidget implements PreferredSizeWidget {
  const _WishlistBar();
  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);
  @override
  Widget build(BuildContext context) =>
      AppBar(title: const Text('Wish list check'));
}

class WishlistView extends StatefulWidget {
  const WishlistView({super.key});
  @override
  State<WishlistView> createState() => _WishlistViewState();
}

class _WishlistViewState extends State<WishlistView> {
  late WishlistController controller;
  late TextEditingController input;
  WishStatus? filter;

  @override
  void initState() {
    super.initState();
    controller = context.read<AppState>().wishlist;
    input = TextEditingController(text: controller.text);
    input.addListener(_inputChanged);
    controller.addListener(_controllerChanged);
  }

  void _inputChanged() => controller.setText(input.text);
  void _controllerChanged() {
    if (input.text != controller.text) {
      input.value = TextEditingValue(
        text: controller.text,
        selection: TextSelection.collapsed(offset: controller.text.length),
      );
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    input.removeListener(_inputChanged);
    input.dispose();
    controller.removeListener(_controllerChanged);
    super.dispose();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    if (data?.text == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Clipboard has no text')));
      return;
    }
    input.text = data!.text!;
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: controller.summary()));
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Results copied')));
    }
  }

  Future<void> _export() async {
    try {
      final path = await FilePicker.saveFile(
        dialogTitle: 'Save wish list results',
        fileName: 'wish-list.csv',
        bytes: Uint8List.fromList(utf8.encode(controller.csv())),
      );
      if (mounted && path != null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Saved $path')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Export failed: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final busy = c.checking || c.lookingUp;
    return Column(
      children: [
        Flexible(
          flex: 2,
          fit: FlexFit.loose,
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: input,
                    minLines: 3,
                    maxLines: 7,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      labelText: 'Paste tracks, one per line',
                      hintText: 'Artist - Title\n"Title" by Artist\nArtist - Title (Album: Album name)',
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      OutlinedButton.icon(
                        onPressed: _paste,
                        icon: const Icon(Icons.paste),
                        label: const Text('Paste'),
                      ),
                      FilledButton.icon(
                        onPressed: busy || input.text.trim().isEmpty
                            ? null
                            : c.check,
                        icon: const Icon(Icons.search),
                        label: const Text('Check library'),
                      ),
                      OutlinedButton.icon(
                        onPressed:
                            busy ||
                                !c.results.any(
                                  (r) =>
                                      r.status == WishStatus.missing &&
                                      r.entry.artist != null,
                                )
                            ? null
                            : c.findAlbums,
                        icon: const Icon(Icons.cloud_outlined),
                        label: const Text('Find albums online'),
                      ),
                      if (c.lookingUp)
                        TextButton(
                          onPressed: c.cancel,
                          child: const Text('Stop'),
                        ),
                      TextButton.icon(
                        onPressed: c.results.isEmpty ? null : _copy,
                        icon: const Icon(Icons.copy),
                        label: const Text('Copy results'),
                      ),
                      TextButton.icon(
                        onPressed: c.results.isEmpty ? null : _export,
                        icon: const Icon(Icons.save_alt),
                        label: const Text('Save CSV'),
                      ),
                    ],
                  ),
                  const Text(
                    'Results use library records and existing damage checks, not a fresh file scan. '
                    'Online lookup sends missing artist and title names to Deezer; albums are suggestions.',
                  ),
                  if (c.checking) const LinearProgressIndicator(),
                  if (c.lookingUp) ...[
                    LinearProgressIndicator(
                      value: c.total == 0 ? null : c.done / c.total,
                    ),
                    Text('Album lookups: ${c.done} / ${c.total}'),
                  ],
                  if (c.error != null)
                    Text(
                      c.error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  if (c.results.isNotEmpty)
                    Wrap(
                      spacing: 8,
                      children: [
                        ChoiceChip(
                          label: Text('All ${c.results.length}'),
                          selected: filter == null,
                          onSelected: (_) => setState(() => filter = null),
                        ),
                        for (final status in WishStatus.values)
                          ChoiceChip(
                            label: Text(
                              '${statusLabel(status)} ${c.results.where((r) => r.status == status).length}',
                            ),
                            selected: filter == status,
                            onSelected: (_) => setState(() => filter = status),
                          ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ),
        Expanded(
          flex: 3,
          child: c.results.isEmpty
              ? const Center(child: Text('Paste a list and check your library'))
              : ListView.builder(
                  itemCount: c.results.length,
                  itemBuilder: (context, i) {
                    final result = c.results[i];
                    if (filter != null && result.status != filter) {
                      return const SizedBox.shrink();
                    }
                    final album = c.origins[i];
                    final artist = result.entry.artist;
                    final ownedAlbum = album == null || artist == null
                        ? null
                        : album.libraryAlbum(artist, c.library);
                    return ExpansionTile(
                      leading: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(switch (result.status) {
                            WishStatus.owned => Icons.check_circle_outline,
                            WishStatus.damaged => Icons.broken_image_outlined,
                            WishStatus.missing => Icons.search_off,
                            WishStatus.ambiguous => Icons.help_outline,
                          }),
                          if (result.songs.isNotEmpty) ...[
                            const SizedBox(width: 8),
                            TrackArt(path: result.songs.first.path, size: 40),
                          ],
                        ],
                      ),
                      title: Text(result.entry.line),
                      subtitle: Text(
                        [
                          statusLabel(result.status),
                          if (result.status == WishStatus.ambiguous)
                            'Possible matches need review',
                          if (album != null)
                            'Possible album: ${album.title}${album.date == null ? '' : ' (${album.date})'}'
                                ' — ${ownedAlbum != null ? 'matching album in library' : 'no matching album in library'}',
                          if (c.origins.containsKey(i) && album == null)
                            'No album found on Deezer',
                          if (result.status == WishStatus.missing &&
                              artist == null)
                            'Artist needed for album lookup',
                          if (c.lookupErrors[i] != null) c.lookupErrors[i]!,
                        ].join('\n'),
                      ),
                      children: [
                        for (final song in result.songs)
                          ListTile(
                            leading: TrackArt(path: song.path, size: 40),
                            title: Text(song.display),
                            subtitle: Text(
                              [
                                song.album ?? 'Unknown album',
                                song.qualityDescription,
                                if (song.damaged)
                                  c.health[song.path]?.reason ??
                                      'tagged damaged',
                                if (!song.damaged) 'Not marked damaged',
                                song.path,
                              ].join('\n'),
                            ),
                            trailing: song.album == null
                                ? null
                                : TextButton(
                                    onPressed: () => openAlbum(
                                      context,
                                      song.album,
                                      song.artist,
                                    ),
                                    child: const Text('Open album'),
                                  ),
                          ),
                        if (result.songs.any((s) => s.damaged) &&
                            result.songs.any((s) => !s.damaged) &&
                            result.status == WishStatus.owned)
                          const Padding(
                            padding: EdgeInsets.all(8),
                            child: Text(
                              'A matching copy is not marked damaged; verify its version and album before replacing.',
                            ),
                          ),
                        if (ownedAlbum != null)
                          TextButton(
                            onPressed: () => openAlbum(
                              context,
                              ownedAlbum.album,
                              ownedAlbum.artist,
                            ),
                            child: const Text('Open matching album'),
                          ),
                      ],
                    );
                  },
                ),
        ),
      ],
    );
  }
}
