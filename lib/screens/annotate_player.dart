import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_core/shared_core.dart' show TimedNote, activeTimedNote;
import 'package:shared_core/services/queue_service.dart' show PlayMode;

import '../services/app_state.dart';

String _clock(double s) => '${s ~/ 60}:${(s % 60).floor().toString().padLeft(2, '0')}';

/// Plays mix song [i]; pause anywhere and add a trainer note stamped at that
/// position. Notes pop up on later plays here and on the phone.
Future<void> showAnnotatePlayer(BuildContext context, AppState app, int i) {
  final song = app.mixer.mix[i];
  return showDialog<void>(
    context: context,
    builder: (_) => _Annotate(app: app, path: song.path, title: song.display, seconds: song.playSeconds ?? 0),
  );
}

class _Annotate extends StatefulWidget {
  const _Annotate({required this.app, required this.path, required this.title, required this.seconds});
  final AppState app;
  final String path, title;
  final double seconds;

  @override
  State<_Annotate> createState() => _AnnotateState();
}

class _AnnotateState extends State<_Annotate> {
  StreamSubscription<Duration>? _sub;
  double _pos = 0;
  bool _started = false;

  AppState get _app => widget.app;
  double _now() => _app.player.position.inMilliseconds / 1000 - _app.player.clipStart;

  @override
  void initState() {
    super.initState();
    _app.mixer.addListener(_changed);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _app.mixer.removeListener(_changed);
    if (_started) _app.player.pause();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _toggle() async {
    if (!_started) {
      _app.setMode(PlayMode.mix);
      await _app.play(widget.path);
      _sub = _app.player.positionStream.listen((_) {
        if (mounted) setState(() => _pos = _now());
      });
      setState(() => _started = true);
    } else if (_app.player.playing) {
      await _app.player.pause();
    } else {
      await _app.player.play();
    }
    if (mounted) setState(() {});
  }

  Future<void> _seekBy(double d) async {
    if (!_started) return;
    final t = (_now() + d).clamp(0.0, widget.seconds > 0 ? widget.seconds : double.infinity);
    await _app.player.seek(Duration(milliseconds: ((t + _app.player.clipStart) * 1000).round()));
  }

  Future<String?> _ask(String title, [String initial = '']) {
    final c = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
            controller: c,
            autofocus: true,
            maxLines: 3,
            decoration: const InputDecoration(hintText: 'Trainer note, e.g. Add a gear for the chorus')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Save')),
        ],
      ),
    );
  }

  Future<void> _addHere() async {
    final at = _started ? _now() : 0.0;
    final wasPlaying = _started && _app.player.playing;
    if (wasPlaying) await _app.player.pause();
    final text = await _ask('Note at ${_clock(at)}');
    if (text != null && text.trim().isNotEmpty) _app.mixer.addTimedNote(widget.path, at, text.trim());
    if (wasPlaying) await _app.player.play();
  }

  Future<void> _edit(int i, TimedNote n) async {
    final text = await _ask('Note at ${_clock(n.at)}', n.text);
    if (text != null) _app.mixer.updateTimedNote(widget.path, i, text: text);
  }

  @override
  Widget build(BuildContext context) {
    final notes = _app.mixer.timedNotes[widget.path] ?? const <TimedNote>[];
    final playing = _started && _app.player.playing;
    final active = activeTimedNote(notes, _pos);
    return AlertDialog(
      title: Text('Annotate: ${widget.title}', maxLines: 2, overflow: TextOverflow.ellipsis),
      content: SizedBox(
        width: 460,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            IconButton(tooltip: 'Back 5 s', icon: const Icon(Icons.replay_5), onPressed: () => _seekBy(-5)),
            IconButton(
                iconSize: 48,
                tooltip: playing ? 'Pause' : 'Play',
                icon: Icon(playing ? Icons.pause_circle : Icons.play_circle),
                onPressed: _toggle),
            IconButton(tooltip: 'Forward 5 s', icon: const Icon(Icons.forward_5), onPressed: () => _seekBy(5)),
            const SizedBox(width: 12),
            Text('${_clock(_pos)}${widget.seconds > 0 ? ' / ${_clock(widget.seconds)}' : ''}'),
          ]),
          if (active != null)
            Card(
                color: Theme.of(context).colorScheme.tertiaryContainer,
                child: Padding(padding: const EdgeInsets.all(8), child: Text('📝 ${active.text}'))),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
                onPressed: _addHere,
                icon: const Icon(Icons.add_comment),
                label: Text(_started ? 'Pause & add note at ${_clock(_pos)}' : 'Add note at 0:00')),
          ),
          const Divider(),
          if (notes.isEmpty)
            const Padding(padding: EdgeInsets.all(8), child: Text('No notes yet. Play, then add one at any point.'))
          else
            Flexible(
              child: ListView(shrinkWrap: true, children: [
                for (var i = 0; i < notes.length; i++)
                  ListTile(
                    dense: true,
                    leading: Text(_clock(notes[i].at)),
                    title: Text(notes[i].text, maxLines: 2, overflow: TextOverflow.ellipsis),
                    onTap: () => _edit(i, notes[i]),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      IconButton(
                          tooltip: 'Play from here',
                          icon: const Icon(Icons.play_arrow),
                          onPressed: () async {
                            if (!_started) await _toggle();
                            await _app.player.seek(
                                Duration(milliseconds: ((notes[i].at + _app.player.clipStart) * 1000).round()));
                            await _app.player.play();
                          }),
                      IconButton(
                          tooltip: 'Earlier by 1 s',
                          icon: const Icon(Icons.remove),
                          onPressed: () => _app.mixer
                              .updateTimedNote(widget.path, i, at: (notes[i].at - 1).clamp(0.0, double.infinity))),
                      IconButton(
                          tooltip: 'Later by 1 s',
                          icon: const Icon(Icons.add),
                          onPressed: () => _app.mixer.updateTimedNote(widget.path, i, at: notes[i].at + 1)),
                      IconButton(
                          tooltip: 'Delete',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => _app.mixer.removeTimedNote(widget.path, i)),
                    ]),
                  ),
              ]),
            ),
        ]),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Done'))],
    );
  }
}
