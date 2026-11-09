import 'package:flutter/material.dart';

import '../services/mix_controller.dart';

enum UnsavedChoice { save, discard, cancel }

/// Before replacing the mix (auto-fill, clear, load): when it has unsaved
/// changes, asks Save / Discard / Cancel and saves if asked. Returns true
/// when it's fine to go ahead.
Future<bool> confirmUnsavedMix(BuildContext context, MixController s,
    {String action = 'continue'}) async {
  if (!s.dirty || s.mix.isEmpty) return true;
  final choice = await showDialog<UnsavedChoice>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Unsaved changes'),
      content: Text('"${s.mixName}" has changes that are not saved. '
          'Save them before you $action?'),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, UnsavedChoice.cancel),
            child: const Text('Cancel')),
        TextButton(
            onPressed: () => Navigator.pop(ctx, UnsavedChoice.discard),
            child: const Text('Discard')),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, UnsavedChoice.save),
            child: const Text('Save')),
      ],
    ),
  );
  switch (choice) {
    case UnsavedChoice.save:
      await s.saveMix();
      return true;
    case UnsavedChoice.discard:
      return true;
    case UnsavedChoice.cancel:
    case null:
      return false;
  }
}
