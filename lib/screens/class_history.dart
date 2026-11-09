import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/app_state.dart';
import '../services/class_history.dart';
import '../services/db.dart';

String formatTaughtDay(DateTime d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)}';
}

/// Asks for the class date (default today) and logs the class with a
/// snapshot of [paths]. Returns true if it was logged.
Future<bool> markAsTaught(BuildContext context,
    {int? mixId, required String mixName, required List<String> paths}) async {
  if (paths.isEmpty) return false;
  final app = context.read<AppState>();
  final messenger = ScaffoldMessenger.of(context);
  final now = DateTime.now();
  final day = await showDatePicker(
    context: context,
    initialDate: now,
    firstDate: DateTime(now.year - 5),
    lastDate: now,
    helpText: 'When was "$mixName" taught?',
    confirmText: 'Mark as taught',
  );
  if (day == null) return false;
  final at = DateTime(day.year, day.month, day.day, now.hour, now.minute);
  await app.logClass(mixId: mixId, mixName: mixName, paths: paths, taughtAt: at);
  messenger.showSnackBar(
      SnackBar(content: Text('Logged "$mixName" as taught on ${formatTaughtDay(at)}')));
  return true;
}

/// Logged classes (all, or one mix's), newest first, with delete.
class ClassHistoryDialog extends StatefulWidget {
  const ClassHistoryDialog({super.key, this.mixId, this.title});
  final int? mixId;
  final String? title;

  @override
  State<ClassHistoryDialog> createState() => _ClassHistoryDialogState();
}

class _ClassHistoryDialogState extends State<ClassHistoryDialog> {
  List<ClassSession>? _sessions;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final s = await context.read<AppState>().db.classSessions(mixId: widget.mixId);
    if (mounted) setState(() => _sessions = s);
  }

  Future<void> _delete(ClassSession s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete class?'),
        content: Text('Remove "${s.mixName}" taught on ${formatTaughtDay(s.taughtAt)} '
            'from the class history?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await context.read<AppState>().deleteClassSession(s.id);
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final list = _sessions;
    return AlertDialog(
      title: Text(widget.title ?? 'Class history'),
      content: SizedBox(
        width: 480,
        height: 400,
        child: list == null
            ? const Center(child: CircularProgressIndicator())
            : list.isEmpty
                ? const Center(child: Text('No classes logged yet'))
                : ListView.builder(
                    itemCount: list.length,
                    itemBuilder: (_, i) {
                      final s = list[i];
                      return ListTile(
                        dense: true,
                        leading: Icon(s.source == 'auto' ? Icons.auto_awesome : Icons.event_available),
                        title: Text(s.mixName),
                        subtitle: Text([
                          formatTaughtDay(s.taughtAt),
                          '${s.paths.length} song${s.paths.length == 1 ? '' : 's'}',
                          if (s.source == 'auto') 'from play history',
                        ].join(' · ')),
                        trailing: IconButton(
                          tooltip: 'Delete',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => _delete(s),
                        ),
                      );
                    },
                  ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
      ],
    );
  }
}

/// 'Taught "X" on [date]?' for the newest class the play history suggests.
class ClassSuggestionBanner extends StatelessWidget {
  const ClassSuggestionBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final list = context.select<AppState, List<ClassSuggestion>>((a) => a.classSuggestions);
    if (list.isEmpty) return const SizedBox.shrink();
    final s = list.first;
    final app = context.read<AppState>();
    return MaterialBanner(
      leading: const Icon(Icons.event_available),
      content: Text('Taught "${s.mixName}" on ${formatTaughtDay(s.start)}? '
          '${s.matched} of its ${s.total} songs were played together'
          '${list.length > 1 ? ' (+${list.length - 1} more)' : ''}.'),
      actions: [
        TextButton(onPressed: () => app.dismissClassSuggestion(s), child: const Text('Dismiss')),
        FilledButton(onPressed: () => app.acceptClassSuggestion(s), child: const Text('Log it')),
      ],
    );
  }
}
