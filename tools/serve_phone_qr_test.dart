// Headless server behind tools\serve-phone-qr.ps1: serves the .beatsmix files
// of a folder to beats-me over Wi-Fi ("Scan QR code" on the phone) and prints
// the QR code as text. Runs through `flutter test`; skipped unless
// BEATSMIX_DIR is set. Stop it with Ctrl+C.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:analyze_this/services/ascii_qr.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_core/shared_core.dart';

void main() {
  final env = Platform.environment;
  final dir = env['BEATSMIX_DIR'];

  test('serve .beatsmix files to the phone', () async {
    final work = Directory(env['BEATSMIX_WORK'] ??
        p.join(Directory.systemTemp.path, 'beatsmix_pull_$pid'));
    final files = Directory(dir!)
        .listSync()
        .whereType<File>()
        .where((f) => p.extension(f.path).toLowerCase() == '.beatsmix')
        .where((f) => RegExp(
                '^${(env['BEATSMIX_NAME'] ?? '*').split('*').map(RegExp.escape).join('.*')}\$',
                caseSensitive: false)
            .hasMatch(p.basenameWithoutExtension(f.path)))
        .toList()
      ..sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
    if (files.isEmpty) {
      stdout.writeln('No .beatsmix files in $dir');
      fail('nothing to serve');
    }

    // The pull server only serves packages labelled "pull", so each file is
    // unpacked and its manifest relabelled.
    stdout.writeln('Preparing ${files.length} mix(es)…');
    final root = Directory(p.join(work.path, 'root'));
    final names = <String>[];
    for (final f in files) {
      final tmp = Directory(p.join(work.path, 'extract'));
      final pkg = await ZipTransport.extract(f, tmp);
      final mf = File(p.join(pkg.path, manifestName));
      final j = jsonDecode(await mf.readAsString()) as Map<String, dynamic>;
      j['transport'] = Transport.pull;
      final dest = labelDir(root, Transport.pull, j['id'] as String);
      await dest.parent.create(recursive: true);
      if (await dest.exists()) await dest.delete(recursive: true);
      await mf.writeAsString(jsonEncode(j));
      await pkg.rename(dest.path);
      names.add('${j['name']}');
    }

    final server = PullServer(
      root: root,
      name: env['BEATSMIX_PC'] ?? Platform.localHostname,
      onPhoneDone: (id, report) => stdout.writeln('Phone finished $id: $report'),
    );
    await server.start();
    final link = await server.link();
    final text = link.toString();
    stdout.writeln('');
    stdout.writeln(asciiQr(text));
    stdout.writeln('');
    stdout.writeln('On the phone: beats-me › Mixtapes › Scan QR code.');
    stdout.writeln('Serving ${names.length} mix(es):');
    for (final n in names) {
      stdout.writeln('  • $n');
    }
    stdout.writeln('');
    stdout.writeln('Link:    $text');
    stdout.writeln('Address: ${link.hosts.join(', ')}  port ${link.port}  code ${link.token}');
    stdout.writeln('The phone must be on the same Wi-Fi. If it cannot connect, allow TCP port '
        '${link.port} through the Windows firewall (Private network).');
    stdout.writeln('Press Ctrl+C to stop.');
    stdout.writeln('READY');
    await Completer<void>().future;
  }, skip: dir == null ? 'set BEATSMIX_DIR (use tools\\serve-phone-qr.ps1)' : false,
      timeout: Timeout.none);
}
