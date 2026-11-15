part of 'mix_controller.dart';

/// Building a mix from a list of supplied tracks: the songs set the shape of
/// the class and exercises are mapped onto them.
extension TrackMix on MixController {
  /// Starts a new mix from [songs] in order (damaged songs are skipped),
  /// one steady part per song. One undoable edit. Returns songs skipped.
  int startFromTracks(Iterable<Song> songs, {String? name}) {
    final ok = [for (final s in songs) if (!s.damaged) s];
    _edit(() {
      mix = ok;
      mixPart = [for (var i = 0; i < ok.length; i++) i];
      program = Program(name ?? 'Track mix', const [], trackMix: true);
      lockedPaths = {};
      songNotes = {};
      songSegments = {};
      timedNotes = {};
      mixKey = newMixtapeId();
      mixDbId = null;
      if (name != null) {
        mixName = name;
        mixNameAuto = false;
      }
    });
    return songs.length - ok.length;
  }

  /// Maps exercise [role] onto song [i], keeping any trainer note of the part.
  /// Only in a track mix; returns whether it applied.
  bool assignExercise(int i, PartRole role, {String? name}) {
    if (!program.trackMix || i < 0 || i >= mix.length) return false;
    _edit(() {
      _syncParts();
      final pi = mixPart[i]!;
      final old = program.parts[pi];
      final next = exerciseFor(role, mix[i], name: name).copyWith(trainerNote: old.trainerNote);
      program = Program(program.name, [
        for (var k = 0; k < program.parts.length; k++) k == pi ? next : program.parts[k]
      ], trackMix: true);
      // A different exercise has different sub-exercises.
      songSegments = {...songSegments}..remove(mix[i].path);
    });
    return true;
  }

  /// Seconds of the song at [i], for sizing its sub-exercises.
  double songSecondsAt(int i) => mix[i].playSeconds ?? 0;

  /// The current mix as CSV text (see `mix_csv.dart`).
  String toCsv() {
    _syncParts();
    return mixToCsv(
        name: mixName,
        program: program,
        songs: mix,
        mixPart: mixPart,
        notes: songNotes,
        segments: songSegments,
        timed: timedNotes);
  }

  /// Replaces the mix with the songs of [csv], matched against [library].
  /// Songs that are not found are left out and listed in the result. A track
  /// mix gets one part per song. One undoable edit.
  ({int matched, List<String> missing}) applyCsv(MixCsv csv, List<Song> library) {
    final songs = <Song>[];
    final parts = <ProgramPart>[];
    final partOf = <int?>[];
    final notes = <String, String>{};
    final segs = <String, List<SegmentEdit>>{};
    final timed = <String, List<TimedNote>>{};
    final missing = <String>[];
    final seen = <String>{};
    for (final cp in csv.parts) {
      var index = parts.length;
      var used = false;
      for (final cs in cp.songs) {
        final s = matchCsvSong(cs, library);
        if (s == null) {
          missing.add('line ${cs.line}: ${cs.label}');
          continue;
        }
        if (!seen.add(s.path)) continue;
        // A track mix gives every song its own part.
        if (csv.trackMix && used) {
          index = parts.length;
          parts.add(cp.part);
        } else if (!used) {
          index = parts.length;
          parts.add(cp.part);
        }
        used = true;
        songs.add(s);
        partOf.add(index);
        if (cs.note.isNotEmpty) notes[s.path] = cs.note;
        if (cs.segments.isNotEmpty) segs[s.path] = cs.segments;
        if (cs.timed.isNotEmpty) timed[s.path] = [...cs.timed]..sort((a, b) => a.at.compareTo(b.at));
      }
      if (!used && !csv.trackMix) parts.add(cp.part);
    }
    _edit(() {
      mix = songs;
      mixPart = partOf;
      program = Program(csv.name, parts, trackMix: csv.trackMix);
      lockedPaths = {};
      songNotes = notes;
      songSegments = segs;
      timedNotes = timed;
      mixKey = newMixtapeId();
      mixDbId = null;
      mixName = csv.name;
      mixNameAuto = false;
    });
    return (matched: songs.length, missing: missing);
  }
}
