import 'dart:convert';
import 'dart:io';

import 'db.dart';
import 'phone_sync.dart';

/// Folder both apps use to exchange data (`%APPDATA%\music-share`).
Directory shareDir() {
  final base = Platform.environment['APPDATA'] ?? Platform.environment['HOME'] ?? '.';
  return Directory('$base${Platform.pathSeparator}music-share');
}

File playsLog([Directory? dir]) =>
    File('${(dir ?? shareDir()).path}${Platform.pathSeparator}plays.jsonl');

File bundleFile([Directory? dir]) =>
    File('${(dir ?? shareDir()).path}${Platform.pathSeparator}bundle.json');

/// Imports plays other apps (beats-me) appended to the shared log. Plays
/// already in the database are skipped, so this is safe to run repeatedly.
/// Paths not in the library are matched like phone plays (see [PathResolver]);
/// unmatched ones are kept as logged.
Future<int> importSharedPlays(MusicDb db, {Directory? dir}) async {
  final f = playsLog(dir);
  if (!await f.exists()) return 0;
  final rows = <Map<String, Object?>>[];
  for (final line in await f.readAsLines()) {
    if (line.trim().isEmpty) continue;
    try {
      final m = (jsonDecode(line) as Map).cast<String, Object?>();
      if (m['app'] != 'analyze-this') rows.add(m);
    } catch (_) {}
  }
  final resolver = PathResolver(db);
  final refs = [for (final r in rows) TrackRef.fromMap(r)];
  await resolver.prime(refs);
  for (var i = 0; i < rows.length; i++) {
    if (await resolver.resolve(refs[i]) case final p?) rows[i] = {...rows[i], 'path': p};
  }
  return (await PhoneSync(db).importPlayRows(rows)).length;
}

Future<File> exportBundleTo(MusicDb db, [File? file]) async {
  final f = file ?? bundleFile();
  await f.parent.create(recursive: true);
  await f.writeAsString(const JsonEncoder.withIndent('  ').convert(await db.exportBundle()));
  return f;
}

Future<BundleResult> importBundleFrom(MusicDb db, [File? file]) async {
  final f = file ?? bundleFile();
  return db.importBundle((jsonDecode(await f.readAsString()) as Map).cast<String, dynamic>());
}
