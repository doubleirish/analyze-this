import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import 'db.dart';

/// A library backup on disk.
class BackupInfo {
  final File file;
  final DateTime created;
  final bool auto;
  const BackupInfo(this.file, this.created, this.auto);
  String get name => p.basename(file.path);
}

/// Zipped snapshots of the library database (songs, ratings, mixes,
/// programs, history and every setting live there). Restores are staged and
/// swapped in by [applyPendingRestore] at the next start, before the
/// database is opened.
class BackupService {
  BackupService(this.db, this.supportDir);

  final MusicDb db;
  final Directory supportDir;

  static const keepAuto = 5;
  static const _dbEntry = 'library.db';
  static const _infoEntry = 'backup.json';
  static const pendingName = 'restore_pending.db';

  Directory get dir => Directory(p.join(supportDir.path, 'backups'));

  static String _stamp(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}${two(t.month)}${two(t.day)}-${two(t.hour)}${two(t.minute)}${two(t.second)}';
  }

  /// Writes a new backup zip and returns it.
  Future<File> create({bool auto = false, String? label}) async {
    await dir.create(recursive: true);
    final now = DateTime.now();
    final tmp = File(p.join(dir.path, '.snapshot-${now.microsecondsSinceEpoch}.db'));
    try {
      await db.copyTo(tmp.path);
      final bytes = await tmp.readAsBytes();
      final info = utf8.encode(jsonEncode({
        'app': 'analyze-this',
        'schema': await db.schemaVersion(),
        'created': now.toIso8601String(),
        'auto': auto,
        'label': ?label,
      }));
      final archive = Archive()
        ..add(ArchiveFile.bytes(_infoEntry, info))
        ..add(ArchiveFile.bytes(_dbEntry, bytes));
      final suffix = auto ? '-auto' : (label != null ? '-$label' : '');
      var out = File(p.join(dir.path, 'analyze-this-${_stamp(now)}$suffix.zip'));
      for (var i = 2; await out.exists(); i++) {
        out = File(p.join(dir.path, 'analyze-this-${_stamp(now)}$suffix-$i.zip'));
      }
      final part = File('${out.path}.part');
      await part.writeAsBytes(ZipEncoder().encodeBytes(archive), flush: true);
      await part.rename(out.path);
      return out;
    } finally {
      if (await tmp.exists()) await tmp.delete();
    }
  }

  /// Backups in the backup folder, newest first.
  Future<List<BackupInfo>> list() async {
    if (!await dir.exists()) return [];
    final out = <BackupInfo>[];
    await for (final e in dir.list()) {
      if (e is! File || !e.path.toLowerCase().endsWith('.zip')) continue;
      out.add(BackupInfo(e, (await e.stat()).modified, p.basename(e.path).contains('-auto')));
    }
    out.sort((a, b) => b.created.compareTo(a.created));
    return out;
  }

  /// Makes an automatic backup unless one was made in the last day, then
  /// keeps only the newest [keepAuto] automatic ones. Manual backups are
  /// never pruned.
  Future<File?> autoBackupIfDue({DateTime? now}) async {
    now ??= DateTime.now();
    final autos = [for (final b in await list()) if (b.auto) b];
    File? made;
    if (autos.isEmpty || now.difference(autos.first.created) >= const Duration(hours: 20)) {
      made = await create(auto: true);
    }
    final all = [for (final b in await list()) if (b.auto) b];
    for (final b in all.skip(keepAuto)) {
      try {
        await b.file.delete();
      } catch (_) {}
    }
    return made;
  }

  /// Checks [zip] and stages its database to replace the current one at the
  /// next start. A backup of the current library is made first. Throws a
  /// [FormatException] explaining why a file can't be restored.
  Future<void> stageRestore(File zip) async {
    final bytes = await zip.readAsBytes();
    final db0 = validateBackup(bytes, currentSchema: await db.schemaVersion());
    await create(label: 'pre-restore');
    final pending = File(p.join(supportDir.path, '$pendingName.part'));
    await pending.writeAsBytes(db0, flush: true);
    await pending.rename(p.join(supportDir.path, pendingName));
  }

  /// Cancels a staged restore.
  Future<void> cancelRestore() async {
    final f = File(p.join(supportDir.path, pendingName));
    if (await f.exists()) await f.delete();
  }

  bool get restorePending => File(p.join(supportDir.path, pendingName)).existsSync();

  /// Returns the database bytes from a backup zip after checking it: only
  /// the two expected top-level entries are read (so no path in the zip is
  /// ever written), the database must be SQLite, and its schema must not be
  /// newer than this app understands.
  static Uint8List validateBackup(List<int> zipBytes, {required int currentSchema}) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(zipBytes);
    } catch (_) {
      throw const FormatException('Not a zip file');
    }
    ArchiveFile? find(String name) {
      for (final f in archive) {
        if (f.isFile && f.name == name) return f;
      }
      return null;
    }

    final infoFile = find(_infoEntry);
    final dbFile = find(_dbEntry);
    if (infoFile == null || dbFile == null) {
      throw const FormatException('Not an analyze-this backup');
    }
    final Object? info;
    try {
      info = jsonDecode(utf8.decode(infoFile.content));
    } catch (_) {
      throw const FormatException('Backup description is unreadable');
    }
    if (info is! Map || info['app'] != 'analyze-this') {
      throw const FormatException('Not an analyze-this backup');
    }
    final data = dbFile.content;
    const magic = 'SQLite format 3\u0000';
    if (data.length < 100 || String.fromCharCodes(data.sublist(0, 16)) != magic) {
      throw const FormatException('Backup database is damaged');
    }
    // PRAGMA user_version is stored big-endian at offset 60 of the header.
    final version = ByteData.sublistView(data, 60, 64).getUint32(0);
    if (version > currentSchema) {
      throw FormatException('Backup is from a newer version of analyze-this '
          '(schema $version, this app understands $currentSchema)');
    }
    return data;
  }

  /// Swaps a staged restore into [dbPath]. Call before opening the database.
  static Future<bool> applyPendingRestore(Directory supportDir, String dbPath) async {
    final pending = File(p.join(supportDir.path, pendingName));
    if (!await pending.exists()) return false;
    for (final s in ['-wal', '-shm', '-journal']) {
      final f = File('$dbPath$s');
      if (await f.exists()) await f.delete();
    }
    final cur = File(dbPath);
    if (await cur.exists()) await cur.delete();
    await pending.rename(dbPath);
    return true;
  }
}
