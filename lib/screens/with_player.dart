import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_core/shared_core.dart';

import 'output_picker.dart';

MaterialPageRoute<T> playerRoute<T>({required WidgetBuilder builder}) =>
    MaterialPageRoute<T>(
      builder: (context) => _WithPlayer(child: builder(context)),
    );

class _WithPlayer extends StatelessWidget {
  const _WithPlayer({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final loaded = context.select<PlaybackController, bool>(
      (s) => s.current != null,
    );
    return Column(
      children: [
        Expanded(child: child),
        if (loaded) const MiniPlayer(extraActions: [OutputButton()]),
      ],
    );
  }
}
