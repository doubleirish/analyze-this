import 'dart:io';

import 'package:analyze_this/screens/send_folder_dialog.dart';
import 'package:analyze_this/services/batch_send.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_core/shared_core.dart';

void main() {
  late Directory dir;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('batch_send_test');
    for (final n in ['b.beatsmix', 'A.BEATSMIX', 'c.beatsmix', 'notes.txt']) {
      File(p.join(dir.path, n)).writeAsStringSync('x');
    }
    Directory(p.join(dir.path, 'sub')).createSync();
    File(p.join(dir.path, 'sub', 'd.beatsmix')).writeAsStringSync('x');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('finds only top-level .beatsmix files, sorted by name', () {
    expect(findBeatsmixFiles(dir).map((f) => f.name), ['A', 'b', 'c']);
    expect(findBeatsmixFiles(Directory(p.join(dir.path, 'nope'))), isEmpty);
  });

  test('a failing file is reported and the rest still go; staging is cleaned', () async {
    final staging = Directory(p.join(dir.path, 'stage'));
    final sent = <String>[];
    final b = BatchSender(
      (pkg, {onProgress, cancelled}) async {
        final name = File(p.join(pkg.path, 'n')).readAsStringSync();
        if (name == 'b') throw TransferException('phone said no');
        sent.add(name);
        return UsbResult(3, 1, 100, name == 'A');
      },
      staging: staging,
      extract: (zip, to) async {
        to.createSync(recursive: true);
        File(p.join(to.path, 'n')).writeAsStringSync(p.basenameWithoutExtension(zip.path));
        return to;
      },
    );
    final started = <String>[];
    final r = await b.run(findBeatsmixFiles(dir), onItem: (i, n) => started.add('$i$n'));
    expect(started, ['0A', '1b', '2c']);
    expect(r.map((e) => e.status),
        [BatchStatus.imported, BatchStatus.failed, BatchStatus.sent]);
    expect(r[1].error, 'phone said no');
    expect(sent, ['A', 'c']);
    expect(staging.existsSync() ? staging.listSync() : [], isEmpty);
  });

  test('cancelling marks the remaining files cancelled', () async {
    var n = 0;
    final b = BatchSender(
      (pkg, {onProgress, cancelled}) async => UsbResult(1, 0, 1, true),
      staging: Directory(p.join(dir.path, 'stage')),
      extract: (zip, to) async => to..createSync(recursive: true),
    );
    final r = await b.run(findBeatsmixFiles(dir), cancelled: () => n++ >= 1);
    expect(r.map((e) => e.status), [BatchStatus.imported, BatchStatus.cancelled, BatchStatus.cancelled]);
  });

  testWidgets('dialog lists the files in a folder, all ticked', (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: SendFolderDialog(initialFolder: dir.path, skipAdb: true))));
    await tester.pump();
    expect(find.textContaining('3 of 3 selected'), findsOneWidget);
    expect(find.text('A'), findsOneWidget);
    await tester.tap(find.text('Select none'));
    await tester.pump();
    expect(find.textContaining('0 of 3 selected'), findsOneWidget);
  });
}
