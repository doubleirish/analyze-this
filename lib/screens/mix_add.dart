import 'package:flutter/material.dart';

import '../services/db.dart';
import '../services/mix_controller.dart';

const _refused = 'is damaged and can\'t go in a mix (see Tools › Damaged audio)';

void _say(BuildContext context, String m) {
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }
}

/// Adds [song] to the mix, or explains why a damaged song can't be added.
/// Returns whether it was added.
bool addToMixOrWarn(BuildContext context, MixController mixer, Song song, {bool atEnd = true}) {
  final ok = mixer.addToMix(song, atEnd: atEnd);
  if (!ok) _say(context, '${song.display} $_refused');
  return ok;
}

/// Adds [song] to [part], or explains why not.
bool addToPartOrWarn(BuildContext context, MixController mixer, Song song, int part) {
  final ok = mixer.addToPart(song, part);
  if (!ok) _say(context, '${song.display} $_refused');
  return ok;
}

/// Adds [songs] in one undoable step, reporting any damaged ones left out.
void addAllToMixOrWarn(BuildContext context, MixController mixer, Iterable<Song> songs) {
  final skipped = mixer.addAllToMix(songs);
  if (skipped > 0) {
    _say(context, 'Left out $skipped damaged song${skipped == 1 ? '' : 's'} (see Tools › Damaged audio)');
  }
}

/// Small red "damaged" marker for song rows, with the reason as tooltip.
class DamagedBadge extends StatelessWidget {
  const DamagedBadge({super.key, this.reason, this.size = 18});
  final String? reason;
  final double size;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: 'Damaged audio${reason == null ? '' : ': $reason'}\nKept out of new mixes',
        child: Icon(Icons.broken_image_outlined, size: size, color: Theme.of(context).colorScheme.error),
      );
}
