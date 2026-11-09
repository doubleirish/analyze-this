import 'dart:convert';

import 'package:path/path.dart' as p;

/// One track line of an M3U/M3U8 playlist.
class M3uEntry {
  const M3uEntry(this.line, this.path, {this.duration, this.title, this.isStream = false});

  /// The line as written in the playlist (trimmed).
  final String line;

  /// [line] resolved against the playlist folder (file:// URIs decoded).
  final String path;

  /// Seconds from the preceding `#EXTINF`, when known (non-negative).
  final double? duration;
  final String? title;

  /// http(s) and other non-file URLs: never a library song.
  final bool isStream;
}

/// Track entries of M3U/M3U8 [text] in order, with their `#EXTINF` length
/// and title. Relative entries resolve against [baseDir].
List<M3uEntry> parseM3uEntries(String text, {String? baseDir}) {
  final out = <M3uEntry>[];
  final extinf = RegExp(r'^#EXTINF:\s*(-?\d+(?:\.\d+)?)[^,]*,?(.*)$', caseSensitive: false);
  double? duration;
  String? title;
  for (var line in text.replaceFirst('\uFEFF', '').split(RegExp(r'\r?\n'))) {
    line = line.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('#')) {
      final m = extinf.firstMatch(line);
      if (m != null) {
        final d = double.tryParse(m.group(1)!);
        duration = d != null && d >= 0 ? d : null;
        final t = m.group(2)!.trim();
        title = t.isEmpty ? null : t;
      }
      continue;
    }
    var path = line;
    var stream = false;
    if (line.toLowerCase().startsWith('file:')) {
      try {
        path = Uri.parse(line).toFilePath();
      } catch (_) {
        stream = true;
      }
    } else if (RegExp(r'^[a-z][a-z0-9+.-]+://', caseSensitive: false).hasMatch(line)) {
      stream = true;
    }
    if (!stream && baseDir != null && !_isAbsolute(path)) path = p.join(baseDir, path);
    out.add(M3uEntry(line, path, duration: duration, title: title, isStream: stream));
    duration = null;
    title = null;
  }
  return out;
}

/// Playlist bytes as text: UTF-8 (BOM or valid UTF-8, always for .m3u8),
/// otherwise Latin-1 as classic .m3u files often are.
String decodePlaylist(List<int> bytes, {bool m3u8 = false}) {
  if (m3u8) return utf8.decode(bytes, allowMalformed: true);
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return latin1.decode(bytes);
  }
}

bool _isAbsolute(String path) =>
    p.isAbsolute(path) || p.windows.isAbsolute(path) || p.posix.isAbsolute(path);

/// Case-insensitive key with one separator style and `.`/`..` resolved.
String normalizedPathKey(String path) =>
    p.posix.normalize(path.replaceAll('\\', '/')).toLowerCase();

String _fileNameKey(String path) => p.posix.basename(path.replaceAll('\\', '/')).toLowerCase();

enum M3uMatchKind { exact, normalized, fileName }

/// Why an entry found no library song.
enum M3uSkipReason {
  notFound('not in the library'),
  ambiguous('several library files have this name'),
  stream('not a local file'),
  duplicate('already earlier in the playlist');

  const M3uSkipReason(this.label);
  final String label;
}

typedef LibraryFile = ({String path, double? duration});

/// The library match for an entry, or why there is none.
class M3uMatch {
  const M3uMatch.found(String this.path, M3uMatchKind this.kind) : reason = null;
  const M3uMatch.skipped(M3uSkipReason this.reason)
      : path = null,
        kind = null;
  final String? path;
  final M3uMatchKind? kind;
  final M3uSkipReason? reason;
}

/// Seconds an `#EXTINF` length may differ from the library length for a
/// file-name match.
const m3uDurationTolerance = 2.0;

/// Matches each entry to a [library] file: exact path, then the same path
/// ignoring case / separators / `..`, then the file name (case-insensitive)
/// whose length is within [m3uDurationTolerance] of the `#EXTINF` length (the
/// closest wins) — or, when the playlist gives no length, the only library
/// file with that name. One result per entry, in order.
List<M3uMatch> matchM3uEntries(List<M3uEntry> entries, Iterable<LibraryFile> library) {
  final exact = <String>{};
  final byNorm = <String, String>{};
  final byName = <String, List<LibraryFile>>{};
  for (final f in library) {
    exact.add(f.path);
    byNorm.putIfAbsent(normalizedPathKey(f.path), () => f.path);
    (byName[_fileNameKey(f.path)] ??= []).add(f);
  }
  return [
    for (final e in entries)
      if (e.isStream)
        const M3uMatch.skipped(M3uSkipReason.stream)
      else if (exact.contains(e.path))
        M3uMatch.found(e.path, M3uMatchKind.exact)
      else if (byNorm[normalizedPathKey(e.path)] case final n?)
        M3uMatch.found(n, M3uMatchKind.normalized)
      else
        _byFileName(e, byName[_fileNameKey(e.path)] ?? const []),
  ];
}

M3uMatch _byFileName(M3uEntry e, List<LibraryFile> candidates) {
  if (candidates.isEmpty) return const M3uMatch.skipped(M3uSkipReason.notFound);
  final want = e.duration;
  if (want == null) {
    return candidates.length == 1
        ? M3uMatch.found(candidates.single.path, M3uMatchKind.fileName)
        : const M3uMatch.skipped(M3uSkipReason.ambiguous);
  }
  LibraryFile? best;
  double? bestDiff;
  for (final c in candidates) {
    final d = c.duration;
    if (d == null) continue;
    final diff = (d - want).abs();
    if (diff <= m3uDurationTolerance && (bestDiff == null || diff < bestDiff)) {
      best = c;
      bestDiff = diff;
    }
  }
  return best == null
      ? const M3uMatch.skipped(M3uSkipReason.notFound)
      : M3uMatch.found(best.path, M3uMatchKind.fileName);
}

/// A playlist line that was not imported.
class M3uSkip {
  const M3uSkip(this.line, this.reason);
  final String line;
  final M3uSkipReason reason;
}

class M3uImportResult {
  const M3uImportResult({required this.matched, required this.total, required this.skipped});

  /// Songs put in the mix.
  final int matched;

  /// Track entries in the playlist.
  final int total;
  final List<M3uSkip> skipped;
}
