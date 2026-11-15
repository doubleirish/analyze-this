import 'dart:math' as math;

import 'package:shared_core/shared_core.dart' show TimedNote;

import 'exercises.dart';
import 'planner.dart';
import 'segment_edit.dart';
import 'song_models.dart';

/// Flat-file (CSV) form of a mix or program, so it can be edited or created
/// outside the app. One row per line; `type` says what a row is:
///
/// * `mix`     – `exercise` = mix name, `variant` = `tracks` for a track mix
/// * `part`    – an exercise: `exercise`, `role`, `minutes`, `min_rpm`,
///               `max_rpm`, `variant`, `note` (trainer note)
/// * `song`    – a track of the preceding part (or of part number `part`):
///               `path` and/or `artist` + `title`, `note` (song note)
/// * `segment` – a sub-exercise of the preceding song: `segment` (label),
///               `seconds`, `min_rpm`, `max_rpm`, `note`
/// * `timed`   – a trainer note pinned to the preceding song: `seconds` into
///               the song and `note`
///
/// A blank `type` is worked out from the other columns, and a `song` row
/// with no part before it starts one (named from `exercise` / `role`), so a
/// plain list of `artist,title` rows is a valid track mix.
const mixCsvColumns = [
  'type', 'part', 'exercise', 'role', 'minutes', 'min_rpm', 'max_rpm', //
  'variant', 'path', 'artist', 'title', 'segment', 'seconds', 'note',
];

class MixCsvSong {
  MixCsvSong({this.path = '', this.artist = '', this.title = '', this.note = '', this.line = 0});
  final String path, artist, title;
  final String note;
  final int line;
  final List<SegmentEdit> segments = [];
  final List<TimedNote> timed = [];

  String get label => title.isNotEmpty
      ? (artist.isEmpty ? title : '$artist - $title')
      : (path.isNotEmpty ? path : '(no song)');
}

class MixCsvPart {
  MixCsvPart(this.part);
  ProgramPart part;
  final List<MixCsvSong> songs = [];
}

class MixCsv {
  String name = 'Imported mix';
  bool trackMix = false;
  final List<MixCsvPart> parts = [];

  /// Problems found while reading, each with its CSV line number.
  final List<String> errors = [];

  Program toProgram() =>
      Program(name, [for (final p in parts) p.part], trackMix: trackMix);
}

String _field(String v) =>
    v.contains(RegExp('[",\r\n]')) || v != v.trim() ? '"${v.replaceAll('"', '""')}"' : v;

String _num(double v) =>
    v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(2).replaceFirst(RegExp(r'0+$'), '');

String _row(Map<String, String> r) =>
    [for (final c in mixCsvColumns) _field(r[c] ?? '')].join(',');

/// Rows for [p] (the `mix` row and one `part` row each); no songs.
List<String> _programRows(Program p) => [
      _row({'type': 'mix', 'exercise': p.name, if (p.trackMix) 'variant': 'tracks'}),
      for (var i = 0; i < p.parts.length; i++)
        _row({
          'type': 'part',
          'part': '${i + 1}',
          'exercise': p.parts[i].name,
          'role': p.parts[i].kind.name,
          'minutes': _num(p.parts[i].minutes),
          'min_rpm': _num(p.parts[i].minRpm),
          'max_rpm': _num(p.parts[i].maxRpm),
          'variant': p.parts[i].variant ?? '',
          'note': p.parts[i].trainerNote,
        }),
    ];

/// A program as CSV (no songs), for editing or creating programs outside the app.
String programToCsv(Program p) => '${mixCsvColumns.join(',')}\r\n${_programRows(p).join('\r\n')}\r\n';

/// A whole mix as CSV: its program, the songs of each part, song notes and
/// hand-set sub-exercises. [mixPart] gives each song's part index (or null).
String mixToCsv({
  required String name,
  required Program program,
  required List<Song> songs,
  required List<int?> mixPart,
  Map<String, String> notes = const {},
  Map<String, List<SegmentEdit>> segments = const {},
  Map<String, List<TimedNote>> timed = const {},
}) {
  final out = <String>[mixCsvColumns.join(',')];
  final rows = _programRows(Program(name, program.parts, trackMix: program.trackMix));
  String songRows(int i) {
    final s = songs[i];
    final r = [
      _row({
        'type': 'song',
        'part': mixPart[i] == null ? '' : '${mixPart[i]! + 1}',
        'path': s.path,
        'artist': s.artist ?? '',
        'title': s.title ?? '',
        'note': notes[s.path] ?? '',
      }),
      for (final e in segments[s.path] ?? const <SegmentEdit>[])
        _row({
          'type': 'segment',
          'segment': e.label,
          'seconds': _num(e.seconds),
          'min_rpm': _num(e.minRpm),
          'max_rpm': _num(e.maxRpm),
          'note': e.note,
        }),
      for (final n in timed[s.path] ?? const <TimedNote>[])
        _row({'type': 'timed', 'seconds': _num(n.at), 'note': n.text}),
    ];
    return r.join('\r\n');
  }

  out.add(rows.first);
  for (var p = 0; p < program.parts.length; p++) {
    out.add(rows[p + 1]);
    for (var i = 0; i < songs.length; i++) {
      if (mixPart[i] == p) out.add(songRows(i));
    }
  }
  for (var i = 0; i < songs.length; i++) {
    if (mixPart[i] == null || mixPart[i]! >= program.parts.length) out.add(songRows(i));
  }
  return '${out.join('\r\n')}\r\n';
}

/// Splits CSV [text] (RFC 4180: quoted fields, doubled quotes, newlines in
/// quotes) into rows of fields, each with its 1-based starting line.
List<(int, List<String>)> parseCsvRows(String text) {
  final rows = <(int, List<String>)>[];
  var row = <String>[];
  final f = StringBuffer();
  var inQuotes = false, started = false, line = 1, rowLine = 1;
  void endField() {
    row.add(f.toString());
    f.clear();
  }

  void endRow() {
    endField();
    if (row.length > 1 || row.first.trim().isNotEmpty) rows.add((rowLine, row));
    row = [];
    started = false;
  }

  final s = text.replaceFirst('\uFEFF', '');
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (!started) {
      rowLine = line;
      started = true;
    }
    if (inQuotes) {
      if (c == '"') {
        if (i + 1 < s.length && s[i + 1] == '"') {
          f.write('"');
          i++;
        } else {
          inQuotes = false;
        }
      } else {
        if (c == '\n') line++;
        f.write(c);
      }
    } else if (c == '"' && f.isEmpty) {
      inQuotes = true;
    } else if (c == ',') {
      endField();
    } else if (c == '\n' || c == '\r') {
      if (c == '\r' && i + 1 < s.length && s[i + 1] == '\n') i++;
      line++;
      endRow();
    } else {
      f.write(c);
    }
  }
  if (started) endRow();
  return rows;
}

PartRole? _role(String v) {
  final t = v.trim().toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
  if (t.isEmpty) return null;
  for (final r in PartRole.values) {
    if (r.name.toLowerCase() == t || r.label.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '') == t) return r;
  }
  return null;
}

/// Reads mix / program CSV [text]. Never throws: problems go to
/// [MixCsv.errors] and the rows that can be used are kept.
MixCsv parseMixCsv(String text) {
  final out = MixCsv();
  final rows = parseCsvRows(text);
  if (rows.isEmpty) {
    out.errors.add('The file is empty');
    return out;
  }
  final head = [for (final h in rows.first.$2) h.trim().toLowerCase().replaceAll(' ', '_')];
  if (!head.contains('type') &&
      !head.contains('title') &&
      !head.contains('path') &&
      !head.contains('exercise')) {
    out.errors.add('Line ${rows.first.$1}: no header row (expected columns like ${mixCsvColumns.take(6).join(', ')})');
    return out;
  }
  final col = {for (var i = 0; i < head.length; i++) head[i]: i};

  MixCsvPart? part;
  MixCsvSong? song;
  final byNumber = <int, MixCsvPart>{};
  var sawName = false, explicitParts = false;

  for (final (line, cells) in rows.skip(1)) {
    String v(String c) {
      final i = col[c];
      return i == null || i >= cells.length ? '' : cells[i].trim();
    }

    double? number(String c, {double? min}) {
      final t = v(c);
      if (t.isEmpty) return null;
      final d = double.tryParse(t);
      if (d == null || d.isNaN || d.isInfinite || (min != null && d < min)) {
        out.errors.add('Line $line: "$t" is not a valid ${c.replaceAll('_', ' ')}');
        return null;
      }
      return d;
    }

    var type = v('type').toLowerCase();
    if (type.isEmpty) {
      type = v('segment').isNotEmpty
          ? 'segment'
          : (v('path').isNotEmpty || v('title').isNotEmpty)
              ? 'song'
              : v('exercise').isNotEmpty || v('role').isNotEmpty
                  ? 'part'
                  : '';
    }

    switch (type) {
      case 'mix':
        if (v('exercise').isNotEmpty) out.name = v('exercise');
        out.trackMix = v('variant').toLowerCase().startsWith('track');
        sawName = true;
      case 'part':
        final role = _role(v('role')) ?? PartRole.infer(v('exercise'));
        if (v('role').isNotEmpty && _role(v('role')) == null) {
          out.errors.add('Line $line: unknown role "${v('role')}", using ${role.label}');
        }
        final lo = number('min_rpm', min: 20), hi = number('max_rpm', min: 20);
        final base = exerciseFor(role, null, name: v('exercise').isEmpty ? null : v('exercise'));
        final mins = number('minutes', min: 0.1);
        part = MixCsvPart(base.copyWith(
          minutes: mins,
          minRpm: lo != null && hi != null ? math.min(lo, hi) : lo,
          maxRpm: lo != null && hi != null ? math.max(lo, hi) : hi,
          variant: v('variant').isEmpty ? null : v('variant'),
          trainerNote: v('note'),
        ));
        out.parts.add(part);
        explicitParts = true;
        final n = int.tryParse(v('part'));
        if (n != null) byNumber[n] = part;
        song = null;
      case 'song':
        if (v('path').isEmpty && v('title').isEmpty) {
          out.errors.add('Line $line: a song row needs a path or a title');
          continue;
        }
        final n = int.tryParse(v('part'));
        var target = n != null ? byNumber[n] : (explicitParts ? part : null);
        if (target == null) {
          if (n != null) {
            out.errors.add('Line $line: part $n is not defined above this song');
          }
          final role = _role(v('role')) ?? PartRole.steady;
          final name = v('exercise').isEmpty ? null : v('exercise');
          target = MixCsvPart(exerciseFor(role, null, name: name));
          out.parts.add(target);
          if (n != null) byNumber[n] = target;
          if (!sawName) out.trackMix = true;
        }
        part = target;
        song = MixCsvSong(
            path: v('path'), artist: v('artist'), title: v('title'), note: v('note'), line: line);
        target.songs.add(song);
      case 'segment':
        if (song == null) {
          out.errors.add('Line $line: a segment row must follow a song row');
          continue;
        }
        final secs = number('seconds', min: 0.1);
        if (secs == null) {
          out.errors.add('Line $line: a segment needs seconds');
          continue;
        }
        final base = part!.part;
        song.segments.add(SegmentEdit(
          label: v('segment').isEmpty ? v('exercise') : v('segment'),
          seconds: secs,
          minRpm: number('min_rpm', min: 20) ?? base.minRpm,
          maxRpm: number('max_rpm', min: 20) ?? base.maxRpm,
          note: v('note'),
        ));
      case 'timed':
        if (song == null) {
          out.errors.add('Line $line: a timed note row must follow a song row');
          continue;
        }
        final at = number('seconds', min: 0);
        if (at == null || v('note').isEmpty) {
          out.errors.add('Line $line: a timed note needs seconds and a note');
          continue;
        }
        song.timed.add(TimedNote(at, v('note')));
      case '':
        continue;
      default:
        out.errors.add('Line $line: unknown row type "$type"');
    }
  }
  if (out.parts.isEmpty) out.errors.add('No parts or songs found');
  return out;
}

String _key(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

/// The library song for [s]: by path (exact, then ignoring case and
/// separators), else by artist + title, else by a unique title.
Song? matchCsvSong(MixCsvSong s, List<Song> library) {
  if (s.path.isNotEmpty) {
    final want = s.path.replaceAll('\\', '/').toLowerCase();
    for (final l in library) {
      if (l.path == s.path || l.path.replaceAll('\\', '/').toLowerCase() == want) return l;
    }
  }
  final t = _key(s.title);
  if (t.isEmpty) return null;
  final byTitle = [for (final l in library) if (_key(l.title ?? '') == t) l];
  final a = _key(s.artist);
  if (a.isNotEmpty) {
    final both = [for (final l in byTitle) if (_key(l.artist ?? '') == a) l];
    if (both.isNotEmpty) return both.first;
    return null;
  }
  return byTitle.length == 1 ? byTitle.first : null;
}
