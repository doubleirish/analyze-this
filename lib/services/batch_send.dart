import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shared_core/shared_core.dart';

/// A `.beatsmix` file found in a folder.
class BeatsmixFile {
  BeatsmixFile(this.file) : name = p.basenameWithoutExtension(file.path);
  final File file;
  final String name;

  int get bytes => file.lengthSync();
}

/// The `.beatsmix` files directly inside [dir], sorted by name.
List<BeatsmixFile> findBeatsmixFiles(Directory dir) {
  if (!dir.existsSync()) return [];
  final files = [
    for (final e in dir.listSync(followLinks: false))
      if (e is File && p.extension(e.path).toLowerCase() == '.beatsmix') BeatsmixFile(e)
  ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return files;
}

enum BatchStatus { sent, imported, failed, cancelled }

class BatchItemResult {
  BatchItemResult(this.name, this.status, {this.sent = 0, this.skipped = 0, this.bytes = 0, this.error});
  final String name;
  final BatchStatus status;
  final int sent, skipped, bytes;
  final String? error;

  bool get ok => status == BatchStatus.sent || status == BatchStatus.imported;
}

/// Sends one extracted package folder to the phone; the default uses adb.
typedef PackageSender = Future<UsbResult> Function(
  Directory pkg, {
  void Function(int done, int total, String what)? onProgress,
  bool Function()? cancelled,
});

/// Sends many `.beatsmix` files to a phone one after another. A file that
/// fails is reported and the rest still go.
class BatchSender {
  BatchSender(this.send, {Directory? staging, this.extract = ZipTransport.extract})
      : staging = staging ?? Directory(p.join(Directory.systemTemp.path, 'beatsmix_batch'));

  final PackageSender send;
  final Directory staging;
  final Future<Directory> Function(File zip, Directory staging) extract;

  /// Runs through [files]. [onItem] is told which file is starting (index, name);
  /// [onProgress] reports bytes of the current file.
  Future<List<BatchItemResult>> run(
    List<BeatsmixFile> files, {
    void Function(int index, String name)? onItem,
    void Function(int done, int total, String what)? onProgress,
    bool Function()? cancelled,
  }) async {
    final results = <BatchItemResult>[];
    for (var i = 0; i < files.length; i++) {
      final f = files[i];
      if (cancelled?.call() ?? false) {
        results.add(BatchItemResult(f.name, BatchStatus.cancelled));
        continue;
      }
      onItem?.call(i, f.name);
      final dir = Directory(p.join(staging.path, 'item'));
      try {
        final pkg = await extract(f.file, dir);
        final r = await send(pkg, onProgress: onProgress, cancelled: cancelled);
        results.add(BatchItemResult(f.name, r.imported ? BatchStatus.imported : BatchStatus.sent,
            sent: r.sent, skipped: r.skipped, bytes: r.bytes));
      } on TransferException catch (e) {
        results.add(e.kind == TransferError.cancelled
            ? BatchItemResult(f.name, BatchStatus.cancelled)
            : BatchItemResult(f.name, BatchStatus.failed, error: e.message));
      } catch (e) {
        results.add(BatchItemResult(f.name, BatchStatus.failed, error: '$e'));
      } finally {
        try {
          if (await dir.exists()) await dir.delete(recursive: true);
        } catch (_) {}
      }
    }
    return results;
  }
}
