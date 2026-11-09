// Headless import behind tools\import-beatsmix-local.ps1: installs .beatsmix
// files into a beats-me mixtape root (same as opening them in the app).
// Runs through `flutter test`; skipped unless IMPORT_FILES is set.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_core/shared_core.dart';

void main() {
  final env = Platform.environment;
  final files = (env['IMPORT_FILES'] ?? '').split('|').where((s) => s.isNotEmpty).toList();

  test('import .beatsmix files into a beats-me root', () async {
    final root = Directory(env['IMPORT_ROOT']!);
    await root.create(recursive: true);
    final importer = MixtapeImporter(root);
    final work = Directory(p.join(Directory.systemTemp.path, 'beatsmix_import_$pid'));
    var failed = 0;
    for (final f in files) {
      try {
        final r = await ZipTransport.import(File(f), work, importer);
        stdout.writeln('OK   ${p.basename(f)}: ${r.paths.length} songs '
            '(${r.copied} copied, ${r.reused + r.reusedOther} reused)'
            '${r.errors.isEmpty ? '' : ', ${r.errors.length} error(s)'}');
      } catch (e) {
        failed++;
        stdout.writeln('FAIL ${p.basename(f)}: $e');
      }
    }
    if (await work.exists()) await work.delete(recursive: true);
    stdout.writeln('Imported ${files.length - failed} of ${files.length} into ${root.path}');
    expect(failed, 0);
  }, skip: files.isEmpty ? 'set IMPORT_FILES' : false, timeout: const Timeout(Duration(minutes: 30)));
}
