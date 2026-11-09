export 'package:shared_core/services/audio_check.dart' show Mp3Probe, probeMp3, probeMp3File;

import 'dart:math' as math;

import 'package:shared_core/shared_core.dart' show Mp3Probe;

import 'db.dart';
import 'discography.dart' show albumKey;

enum HealthKind { missing, duplicate, file }

enum HealthSeverity { warn, error }

/// Tunable limits for the per-file checks.
class HealthLimits {
  const HealthLimits({
    this.minBytes = 10 * 1024,
    this.minSeconds = 5,
    this.maxSeconds = 3 * 3600,
    this.maxKbps = 1000,
    this.minKbps = 24,
    this.mismatchSeconds = 3,
    this.mismatchRatio = 0.02,
  });

  final int minBytes;
  final double minSeconds;
  final double maxSeconds;
  final double maxKbps;
  final double minKbps;
  final double mismatchSeconds;
  final double mismatchRatio;
}

class HealthIssue {
  const HealthIssue(this.kind, this.severity, this.message, [this.paths = const []]);
  final HealthKind kind;
  final HealthSeverity severity;
  final String message;

  /// Files the issue is about; empty for album-wide issues.
  final List<String> paths;
}

class AlbumHealth {
  AlbumHealth(this.key, this.artist, this.album, this.songs, this.issues);
  final String key;
  final String artist;
  final String album;
  final List<Song> songs;
  final List<HealthIssue> issues;

  bool get ok => issues.isEmpty;
  int get errors => issues.where((i) => i.severity == HealthSeverity.error).length;
  HealthSeverity? get worst => issues.isEmpty
      ? null
      : (errors > 0 ? HealthSeverity.error : HealthSeverity.warn);

  List<HealthIssue> issuesFor(String path) =>
      [for (final i in issues) if (i.paths.contains(path)) i];
}

String _norm(String? s) => (s ?? '').toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');

/// Folder an album's files live in; "CD1"/"Disc 2" subfolders fold into the parent.
String albumFolder(String path) {
  final parts = path.split(RegExp(r'[\\/]'));
  if (parts.length < 2) return '';
  var dir = parts.sublist(0, parts.length - 1);
  if (dir.length > 1 && RegExp(r'^(cd|disc|disk)\s*\d+', caseSensitive: false).hasMatch(dir.last)) {
    dir = dir.sublist(0, dir.length - 1);
  }
  return dir.join('/').toLowerCase();
}

/// Groups songs into albums (same normalised title in the same folder).
Map<String, List<Song>> groupAlbums(Iterable<Song> songs) {
  final out = <String, List<Song>>{};
  for (final s in songs) {
    final a = (s.album ?? '').trim();
    if (a.isEmpty) continue;
    final k = '${albumKey(a)}|${albumFolder(s.path)}';
    out.putIfAbsent(k, () => []).add(s);
  }
  return out;
}

String albumArtist(List<Song> songs) {
  final c = <String, int>{};
  for (final s in songs) {
    final a = (s.artist ?? '').trim();
    if (a.isNotEmpty) c[a] = (c[a] ?? 0) + 1;
  }
  if (c.isEmpty) return '';
  if (c.length > 1 && songs.length > 3) {
    final top = c.entries.reduce((a, b) => a.value >= b.value ? a : b);
    if (top.value < songs.length * 0.6) return 'Various artists';
    return top.key;
  }
  return c.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
}

String _kb(int bytes) => bytes < 1024 * 1024
    ? '${(bytes / 1024).toStringAsFixed(0)} KB'
    : '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';

String _clock(double s) => '${s ~/ 60}:${(s % 60).floor().toString().padLeft(2, '0')}';

String _ranges(List<int> nums) {
  final out = <String>[];
  var i = 0;
  while (i < nums.length) {
    var j = i;
    while (j + 1 < nums.length && nums[j + 1] == nums[j] + 1) {
      j++;
    }
    out.add(j == i ? '${nums[i]}' : '${nums[i]}-${nums[j]}');
    i = j + 1;
  }
  return out.join(', ');
}

String _name(Song s) => s.title ?? s.path.split(RegExp(r'[\\/]')).last;

/// Checks every album in [songs]. [probes] holds mp3 header info by path and
/// [onlineTracks] the track count a catalogue lists for an album (keyed by
/// [AlbumHealth.key]); both are optional extra evidence.
List<AlbumHealth> checkAlbums(
  Iterable<Song> songs, {
  Map<String, Mp3Probe?> probes = const {},
  Map<String, int?> onlineTracks = const {},
  HealthLimits limits = const HealthLimits(),
}) {
  final out = <AlbumHealth>[];
  for (final e in groupAlbums(songs).entries) {
    final list = e.value;
    final issues = <HealthIssue>[
      ..._missing(list),
      ..._duplicates(list),
      for (final s in list) ..._fileIssues(s, probes[s.path], limits),
      ..._lengthOutliers(list),
    ];
    final online = onlineTracks[e.key];
    if (online != null && !issues.any((i) => i.kind == HealthKind.missing)) {
      final have = {for (final s in list) '${s.discNo ?? 1}-${s.trackNo ?? _norm(s.title)}'}.length;
      if (have < online) {
        issues.add(HealthIssue(HealthKind.missing, HealthSeverity.warn,
            'Has $have tracks; the online catalogue lists $online'));
      }
    }
    if (issues.isEmpty) continue;
    out.add(AlbumHealth(e.key, albumArtist(list), list.first.album!.trim(), list, issues));
  }
  out.sort((a, b) {
    final c = b.errors.compareTo(a.errors);
    if (c != 0) return c;
    final d = b.issues.length.compareTo(a.issues.length);
    return d != 0 ? d : a.album.toLowerCase().compareTo(b.album.toLowerCase());
  });
  return out;
}

class AlbumTrackCoverage {
  const AlbumTrackCoverage(this.have, this.total, this.issues);
  final int have;
  final int? total;
  final List<HealthIssue> issues;
  bool get incomplete => issues.isNotEmpty;
}

List<HealthIssue> _missing(List<Song> list) => albumTrackCoverage(list).issues;

/// Missing-track evidence and counts, without the expensive file checks.
AlbumTrackCoverage albumTrackCoverage(List<Song> list) {
  const w = HealthSeverity.warn;
  final identities = <String>{};
  for (final s in list) {
    final title = (s.title ?? '').trim().toLowerCase();
    identities.add('${s.discNo ?? 1}|${s.trackNo != null && s.trackNo! > 0 ? s.trackNo : title.isEmpty ? s.path : title}');
  }
  final haveCount = identities.length;
  final numbered = [for (final s in list) if ((s.trackNo ?? 0) > 0) s];
  final discTotal = list.map((s) => s.discTotal ?? 0).fold(0, math.max);
  final observedDiscs = {for (final s in list) s.discNo ?? 1};
  if (numbered.length < list.length || numbered.isEmpty) {
    // Without positions we cannot safely align files or sum per-disc totals.
    final taggedTotal = list.map((s) => s.trackTotal ?? 0).fold(0, math.max);
    final total = observedDiscs.length <= 1 && discTotal <= 1 && taggedTotal >= haveCount && taggedTotal > 0
        ? taggedTotal : null;
    final issues = <HealthIssue>[
      if (total != null && total > haveCount)
        HealthIssue(HealthKind.missing, w, 'Has $haveCount of $total tracks (per tags)'),
      if (discTotal > observedDiscs.length)
        HealthIssue(HealthKind.missing, w, 'Has ${observedDiscs.length} of $discTotal discs'),
    ];
    return AlbumTrackCoverage(haveCount, total, issues);
  }

  final byDisc = <int, Set<int>>{};
  for (final s in numbered) {
    byDisc.putIfAbsent(s.discNo ?? 1, () => {}).add(s.trackNo!);
  }
  final discs = byDisc.keys.toList()..sort();
  // numbering that carries on across discs (1-12, 13-24) is one sequence
  var continuous = discs.length > 1;
  for (var i = 1; i < discs.length && continuous; i++) {
    final prevMax = byDisc[discs[i - 1]]!.reduce(math.max);
    final curMin = byDisc[discs[i]]!.reduce(math.min);
    if (curMin <= prevMax) continuous = false;
  }
  final groups = continuous
      ? {1: {for (final d in byDisc.values) ...d}}
      : byDisc;

  final issues = <HealthIssue>[];
  final multi = groups.length > 1;
  var knownTotal = 0;
  var totalKnown = true;
  for (final g in groups.entries) {
    final have = g.value;
    final top = have.reduce(math.max);
    final totals = [
      for (final s in numbered)
        if ((continuous ? 1 : (s.discNo ?? 1)) == g.key && (s.trackTotal ?? 0) > 0) s.trackTotal!
    ];
    final taggedTotal = totals.isEmpty ? 0 : totals.reduce(math.max);
    if (taggedTotal < top || taggedTotal == 0) totalKnown = false;
    knownTotal += taggedTotal;
    final expect = math.max(top, taggedTotal);
    final gaps = [for (var n = 1; n <= expect; n++) if (!have.contains(n)) n];
    if (gaps.isNotEmpty) {
      issues.add(HealthIssue(HealthKind.missing, w,
          'Missing track${gaps.length == 1 ? '' : 's'} ${_ranges(gaps)}'
          '${multi ? ' on disc ${g.key}' : ''} (${have.length} of $expect)'));
    }
  }
  if (discTotal > discs.length) {
    totalKnown = false;
    issues.add(HealthIssue(HealthKind.missing, w,
        'Has ${discs.length} of $discTotal discs'));
  }
  return AlbumTrackCoverage(haveCount, totalKnown ? knownTotal : null, issues);
}

List<HealthIssue> _duplicates(List<Song> list) {
  const w = HealthSeverity.warn;
  final issues = <HealthIssue>[];
  final byTitle = <String, List<Song>>{};
  for (final s in list) {
    final t = _norm(s.title);
    if (t.isNotEmpty) byTitle.putIfAbsent(t, () => []).add(s);
  }
  final reported = <String>{};
  for (final g in byTitle.values) {
    if (g.length < 2) continue;
    issues.add(HealthIssue(HealthKind.duplicate, w,
        '"${_name(g.first)}" appears ${g.length} times', [for (final s in g) s.path]));
    reported.addAll(g.map((s) => s.path));
  }
  final byNo = <String, List<Song>>{};
  for (final s in list) {
    if (s.trackNo != null) byNo.putIfAbsent('${s.discNo ?? 1}-${s.trackNo}', () => []).add(s);
  }
  for (final g in byNo.values) {
    if (g.length < 2 || g.every((s) => reported.contains(s.path))) continue;
    final disc = g.first.discNo;
    issues.add(HealthIssue(
        HealthKind.duplicate,
        w,
        'Track ${g.first.trackNo}${disc != null && disc > 1 ? ' (disc $disc)' : ''} is shared by '
        '${g.map((s) => '"${_name(s)}"').join(' and ')}',
        [for (final s in g) s.path]));
  }
  return issues;
}

List<HealthIssue> _fileIssues(Song s, Mp3Probe? probe, HealthLimits l) {
  const e = HealthSeverity.error, w = HealthSeverity.warn;
  HealthIssue issue(HealthSeverity sev, String m) =>
      HealthIssue(HealthKind.file, sev, '${_name(s)}: $m', [s.path]);

  if (s.size <= 0) return [issue(e, 'file is empty')];
  final out = <HealthIssue>[];
  if (s.size < l.minBytes) out.add(issue(e, 'only ${_kb(s.size)}, probably truncated'));
  if (probe != null && !probe.valid) {
    out.add(issue(e, 'no valid MP3 audio frames found'));
    return out;
  }
  final d = s.duration;
  if (d != null) {
    if (d <= 0) {
      out.add(issue(e, 'zero length'));
      return out;
    }
    if (d < l.minSeconds) out.add(issue(w, 'only ${_clock(d)} long'));
    if (d > l.maxSeconds) out.add(issue(w, 'unusually long (${_clock(d)})'));
    final kbps = s.size * 8 / d / 1000;
    if (kbps > l.maxKbps) {
      out.add(issue(w, 'file is ${_kb(s.size)} for ${_clock(d)} (${kbps.round()} kbps), too big for its length'));
    } else if (kbps < l.minKbps && s.size >= l.minBytes) {
      out.add(issue(w, 'file is ${_kb(s.size)} for ${_clock(d)} (${kbps.round()} kbps), too small for its length'));
    }
    final h = probe?.headerSeconds;
    if (h != null && h > 0 && (h - d).abs() > math.max(l.mismatchSeconds, d * l.mismatchRatio)) {
      out.add(issue(e,
          'plays ${_clock(d)} but its header says ${_clock(h)}, likely truncated or damaged'));
    }
  }
  return out;
}

List<HealthIssue> _lengthOutliers(List<Song> list) {
  final ds = [for (final s in list) if (s.duration != null && s.duration! > 0) s.duration!]
    ..sort();
  if (ds.length < 4) return const [];
  final median = ds[ds.length ~/ 2];
  final out = <HealthIssue>[];
  for (final s in list) {
    final d = s.duration;
    if (d == null || d <= 0) continue;
    // skip ones already flagged as very short/long by the absolute limits
    if (d >= 5 && d <= 3 * 3600 && median >= 60 && (d < median * 0.1 || d > median * 5)) {
      out.add(HealthIssue(
          HealthKind.file,
          HealthSeverity.warn,
          '${_name(s)}: ${_clock(d)} is far from the album\'s typical ${_clock(median)}',
          [s.path]));
    }
  }
  return out;
}
