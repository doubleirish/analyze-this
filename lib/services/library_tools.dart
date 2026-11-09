import 'dart:convert';
import 'dart:io';

import 'db.dart';
import 'genre_names.dart';

// ---- tag cleanup ----

const _small = {'a', 'an', 'and', 'as', 'at', 'but', 'by', 'feat.', 'for', 'in', 'of', 'on', 'or', 'the', 'to', 'vs'};

String _titleCase(String s) {
  final words = s.split(' ');
  return [
    for (var i = 0; i < words.length; i++)
      if (words[i].isEmpty)
        ''
      else if (i > 0 && _small.contains(words[i]))
        words[i]
      else
        words[i][0].toUpperCase() + words[i].substring(1)
  ].join(' ');
}

/// Trims, collapses spaces, writes "feat." consistently, and title-cases
/// names that are entirely lowercase. [moveThe] turns "Beatles, The" into "The Beatles".
String tidyName(String s, {bool moveThe = false}) {
  var t = s.trim().replaceAll(RegExp(r'\s+'), ' ');
  t = t.replaceAllMapped(
      RegExp(r'\b(featuring|feat|ft)\b\.?', caseSensitive: false), (_) => 'feat.');
  if (moveThe) {
    final m = RegExp(r'^(.+),\s*the$', caseSensitive: false).firstMatch(t);
    if (m != null) t = 'The ${m.group(1)}';
  }
  if (t == t.toLowerCase() && t != t.toUpperCase()) t = _titleCase(t);
  return t;
}

String tidyGenre(String s) => canonicalGenre(s);

class TagFix {
  const TagFix(this.paths, this.field, this.from, this.to);
  final List<String> paths;
  final String field;
  final String from;
  final String to;
}

/// Finds artist/album/genre values to normalise. Spellings that differ only in
/// case or spacing are merged into the most common one.
List<TagFix> planTagCleanup(Iterable<Song> songs) {
  final out = <TagFix>[];
  for (final field in ['artist', 'album', 'genre']) {
    String? get(Song s) => switch (field) {
          'artist' => s.artist,
          'album' => s.album,
          _ => s.ownGenre,
        };
    String tidy(String v) => field == 'genre' ? tidyGenre(v) : tidyName(v, moveThe: field == 'artist');

    final byValue = <String, List<String>>{};
    for (final s in songs) {
      final v = get(s);
      if (v == null || v.trim().isEmpty) continue;
      byValue.putIfAbsent(tidy(v), () => []).add(s.path);
    }
    final canon = <String, String>{};
    final best = <String, int>{};
    for (final e in byValue.entries) {
      final k = e.key.toLowerCase();
      if (e.value.length > (best[k] ?? 0)) {
        best[k] = e.value.length;
        canon[k] = e.key;
      }
    }
    final from = <String, Map<String, List<String>>>{};
    for (final s in songs) {
      final v = get(s);
      if (v == null || v.trim().isEmpty) continue;
      final to = canon[tidy(v).toLowerCase()]!;
      if (to != v) from.putIfAbsent(to, () => {}).putIfAbsent(v, () => []).add(s.path);
    }
    for (final e in from.entries) {
      for (final f in e.value.entries) {
        out.add(TagFix(f.value, field, f.key, e.key));
      }
    }
  }
  return out;
}

Future<int> applyTagFixes(MusicDb db, Iterable<TagFix> fixes) async {
  var n = 0;
  for (final f in fixes) {
    switch (f.field) {
      case 'artist':
        await db.setOverrides(f.paths, artist: f.to);
      case 'album':
        await db.setOverrides(f.paths, album: f.to);
      default:
        await db.setOverrides(f.paths, genre: f.to);
    }
    n += f.paths.length;
  }
  return n;
}

// ---- organizing files ----

const defaultPattern = '{artist}/{album}/{title}';
const sidecarSuffixes = ['.bpm', '.lrc', '.wave', '.enrich'];

String sanitizePart(String s) {
  var t = s.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_').trim();
  t = t.replaceAll(RegExp(r'[. ]+$'), '');
  if (t.length > 100) t = t.substring(0, 100).trim();
  return t;
}

String _base(String path) {
  final f = path.split(RegExp(r'[\\/]')).last;
  final i = f.lastIndexOf('.');
  return i > 0 ? f.substring(0, i) : f;
}

String _ext(String path) {
  final f = path.split(RegExp(r'[\\/]')).last;
  final i = f.lastIndexOf('.');
  return i > 0 ? f.substring(i) : '';
}

/// The path [s] would have under [root] for [pattern] (tokens {artist}, {album},
/// {year}, {title}, {filename}; "/" separates folders).
String targetPathFor(Song s, String root, [String pattern = defaultPattern]) {
  final vals = {
    'artist': s.artist,
    'album': s.album,
    'year': s.year?.toString(),
    'title': s.title,
    'filename': _base(s.path),
  };
  final parts = <String>[];
  for (final seg in pattern.split(RegExp(r'[\\/]'))) {
    final v = seg.replaceAllMapped(RegExp(r'\{(\w+)\}'), (m) {
      final x = vals[m.group(1)];
      if (x != null && x.trim().isNotEmpty) return x;
      return switch (m.group(1)) {
        'artist' => 'Unknown Artist',
        'album' => 'Unknown Album',
        'title' || 'filename' => _base(s.path),
        _ => '',
      };
    });
    final clean = sanitizePart(v);
    if (clean.isNotEmpty) parts.add(clean);
  }
  final r = root.replaceAll(RegExp(r'[\\/]+$'), '');
  final sep = Platform.pathSeparator;
  return '$r$sep${parts.join(sep)}${_ext(s.path)}';
}

class Move {
  const Move(this.from, this.to);
  final String from;
  final String to;
  Map<String, String> toJson() => {'from': from, 'to': to};
}

class OrganizePlan {
  const OrganizePlan(this.moves, this.skipped);
  final List<Move> moves;

  /// Songs left alone because the target already exists or two songs want the same target.
  final List<String> skipped;
}

bool _samePath(String a, String b) => a.toLowerCase() == b.toLowerCase();

OrganizePlan planOrganize(Iterable<Song> songs, String root,
    {String pattern = defaultPattern, bool Function(String)? exists}) {
  final ex = exists ?? (p) => File(p).existsSync();
  final moves = <Move>[];
  final skipped = <String>[];
  final taken = <String>{};
  for (final s in songs) {
    final to = targetPathFor(s, root, pattern);
    if (_samePath(to, s.path)) continue;
    if (taken.contains(to.toLowerCase()) || ex(to)) {
      skipped.add(s.path);
      continue;
    }
    taken.add(to.toLowerCase());
    moves.add(Move(s.path, to));
  }
  return OrganizePlan(moves, skipped);
}

class Organizer {
  Organizer(this.db);
  final MusicDb db;

  static const _undoKey = 'organize_undo';

  Future<void> _moveFile(String from, String to) async {
    await Directory(File(to).parent.path).create(recursive: true);
    try {
      await File(from).rename(to);
    } on FileSystemException {
      await File(from).copy(to);
      await File(from).delete();
    }
  }

  Future<void> _dropEmptyDirs(String from) async {
    var dir = File(from).parent;
    for (var i = 0; i < 3; i++) {
      try {
        if (dir.listSync().isNotEmpty) return;
        await dir.delete();
        dir = dir.parent;
      } catch (_) {
        return;
      }
    }
  }

  /// Moves the files (with sidecars), updates the database, and remembers
  /// what was moved so [undo] can reverse it. Returns the moves that succeeded.
  Future<List<Move>> apply(Iterable<Move> moves) async {
    final done = <Move>[];
    for (final m in moves) {
      try {
        if (!await File(m.from).exists() || await File(m.to).exists()) continue;
        await _moveFile(m.from, m.to);
        for (final sfx in sidecarSuffixes) {
          if (await File('${m.from}$sfx').exists()) {
            await _moveFile('${m.from}$sfx', '${m.to}$sfx');
          }
        }
        await db.renameSong(m.from, m.to);
        await _dropEmptyDirs(m.from);
        done.add(m);
      } catch (_) {}
    }
    if (done.isNotEmpty) {
      await db.setSetting(_undoKey, jsonEncode([for (final m in done) m.toJson()]));
    }
    return done;
  }

  Future<int> undoableCount() async {
    final v = await db.setting(_undoKey);
    return v == null ? 0 : (jsonDecode(v) as List).length;
  }

  Future<int> undo() async {
    final v = await db.setting(_undoKey);
    if (v == null) return 0;
    final back = [
      for (final m in (jsonDecode(v) as List).reversed)
        Move((m as Map)['to'] as String, m['from'] as String)
    ];
    final done = await apply(back);
    await db.setSetting(_undoKey, jsonEncode([]));
    return done.length;
  }
}

// ---- missing files ----

Future<List<Song>> findMissing(Iterable<Song> songs) async => [
      for (final s in songs)
        if (!await File(s.path).exists()) s
    ];
