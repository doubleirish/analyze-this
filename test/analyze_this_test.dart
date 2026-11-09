import 'dart:io';
import 'dart:math';

import 'package:analyze_this/services/planner.dart';
import 'package:analyze_this/services/app_state.dart';
import 'package:analyze_this/services/preview.dart';
import 'package:shared_core/shared_core.dart';
import 'package:analyze_this/services/db.dart';
import 'package:analyze_this/services/musicbrainz.dart';
import 'package:analyze_this/services/scanner.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;
  late MusicDb db;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('analyze_this_');
    db = await MusicDb.open(':memory:');
  });

  tearDown(() async {
    await db.close();
    await tmp.delete(recursive: true);
  });

  test('scanner reads tags, existing .bpm and .lrc sidecars', () async {
    final mp3 = File('${tmp.path}${Platform.pathSeparator}Europe - The Final Countdown.mp3');
    await mp3.writeAsBytes(List.filled(100, 1));
    await BpmStore.save(
        mp3.path,
        TempoResults(durationSec: 200, byAlgo: {
          baselineId: TempoMap(durationSec: 200, segments: const [
            TempoSegment(0, 100, 120),
            TempoSegment(100, 200, 140),
          ])
        }));
    await File('${mp3.path}.lrc')
        .writeAsString('[00:01.00]It\'s the final countdown\n[00:05.00]We\'re leaving together');

    final errors = await Scanner(db).scanAll([tmp.path],
        options: const ScanOptions(
            analyzeBpm: false, fetchLyrics: false, lookupMusicBrainz: false));
    expect(errors, isEmpty);

    final r = await db.search(const SongQuery(lyrics: 'final countdown'));
    expect(r, hasLength(1));
    expect(r.first.artist, 'Europe');
    expect(r.first.title, 'The Final Countdown');
    expect(r.first.avgBpm, closeTo(130, 0.01));
    expect(r.first.bpmStddev, closeTo(10, 0.01));
    expect(r.first.lyrics, isNot(contains('[00:')));
    expect(await db.segmentsOf(mp3.path), hasLength(2));
  });

  test('search filters by bpm, decade, genre and tag; mixes round-trip', () async {
    Song s(String n, double bpm, int year, String genre) => Song(
        path: 'C:\\m\\$n.mp3',
        title: n,
        artist: 'A',
        medianBpm: bpm,
        year: year,
        genre: genre);
    await db.upsertSong(s('slow', 90, 1985, 'Brit-pop'));
    await db.upsertSong(s('fast', 150, 1995, 'Metal'));
    await db.addTag('C:\\m\\fast.mp3', 'Easter-Egg');

    expect((await db.search(const SongQuery(minBpm: 140))).single.title, 'fast');
    expect((await db.search(const SongQuery(decade: 1980))).single.title, 'slow');
    expect((await db.search(const SongQuery(genre: 'brit'))).single.title, 'slow');
    final tagged = await db.search(const SongQuery(tag: 'easter-egg'));
    expect(tagged.single.userTags, ['easter-egg']);
    expect(await db.search(const SongQuery(text: '100%')), isEmpty);

    final id = await db.saveMix('class', ['C:\\m\\fast.mp3', 'C:\\m\\slow.mp3']);
    expect(await db.mixPaths(id), ['C:\\m\\fast.mp3', 'C:\\m\\slow.mp3']);
  });

  test('m3u8 has extinf lines and absolute paths in order', () {
    final out = buildM3u8(const [
      MixEntry('C:\\m\\a.mp3', 'A', artist: 'X', durationSec: 200.4),
      MixEntry('C:\\m\\b.mp3', 'B'),
    ]);
    expect(out.split('\n'), [
      '#EXTM3U',
      '#EXTINF:200,X - A',
      'C:\\m\\a.mp3',
      '#EXTINF:-1,B',
      'C:\\m\\b.mp3',
      '',
    ]);
  });

  test('cadence, steadiness, duration, multi-word lyrics, rating, hide used', () async {
    Song s(String n, double bpm, double sd, double dur,
            {String? lyrics, int rating = 0, bool explicit = false}) =>
        Song(
            path: 'C:\\m\\$n.mp3',
            title: n,
            artist: 'A',
            medianBpm: bpm,
            bpmStddev: sd,
            duration: dur,
            lyrics: lyrics,
            rating: rating,
            explicit: explicit);
    await db.upsertSong(s('half', 70, 1, 200, lyrics: 'run away\nfire'));
    await db.upsertSong(s('exact', 140, 8, 400, lyrics: 'go go go', rating: 4));
    await db.upsertSong(s('other', 100, 2, 200, lyrics: 'clean words', explicit: true));
    await db.upsertSong(s('Final Song', 90, 2, 200));

    Future<List<String>> names(SongQuery q) async =>
        [for (final r in await db.search(q)) r.title!]..sort();

    expect(await names(const SongQuery(targetRpm: 140, rpmTolerance: 3)), ['exact', 'half']);
    expect(await names(const SongQuery(targetRpm: 140, rpmTolerance: 3, halfDouble: false)), ['exact']);
    expect(await names(const SongQuery(maxStddev: 2)), ['Final Song', 'half', 'other']);
    expect(await names(const SongQuery(minSeconds: 300)), ['exact']);
    expect(await names(const SongQuery(lyricsAny: ['fire', 'go'])), ['exact', 'half']);
    expect(await names(const SongQuery(lyricsAny: ['final'], anyIncludesTitle: true)), ['Final Song']);
    expect(await names(const SongQuery(lyricsAll: ['run', 'fire'])), ['half']);
    expect(await names(const SongQuery(lyricsAny: ['go', 'words'], lyricsNot: ['clean'])), ['exact']);
    expect(await names(const SongQuery(hideExplicit: true, lyricsOnly: true)), ['exact', 'half']);
    expect(await names(const SongQuery(minRating: 3)), ['exact']);
    expect(await names(SongQuery(exclude: {'C:\\m\\half.mp3'}, lyricsOnly: true)), ['exact', 'other']);

    await db.saveMix('used', ['C:\\m\\half.mp3']);
    expect(await names(const SongQuery(hideUsed: true, lyricsOnly: true)), ['exact', 'other']);
    await db.setRating('C:\\m\\half.mp3', 5);
    expect((await db.song('C:\\m\\half.mp3'))!.rating, 5);
  });

  test('explicit list, duplicates, snippets and settings', () async {
    expect(containsExplicit('what the Shit', defaultExplicitWords), isTrue);
    expect(containsExplicit('classic hits', defaultExplicitWords), isFalse);
    expect(dupKeyFor('The Who', "Don't Stop"), dupKeyFor('the who', 'Dont stop!'));
    expect(lyricSnippet('one\nthe final countdown\nthree', ['final']), 'the final countdown');

    await db.upsertSong(Song(path: 'C:\\a\\x.mp3', title: 'X', artist: 'Y', dupKey: dupKeyFor('Y', 'X'), lyrics: 'oh heck'));
    await db.upsertSong(Song(path: 'C:\\b\\x.mp3', title: 'X', artist: 'Y', dupKey: dupKeyFor('Y', 'X')));
    await db.upsertSong(Song(path: 'C:\\c\\z.mp3', title: 'Z', artist: 'Y', dupKey: dupKeyFor('Y', 'Z')));
    expect(await db.duplicates(), hasLength(1));

    await db.saveExplicitWords(['heck']);
    expect(await db.explicitWords(), ['heck']);
    expect((await db.song('C:\\a\\x.mp3'))!.explicit, isTrue);
  });

  test('planner: tempo jumps, weighted pick, templates, class sheet', () {
    expect(bpmJump(140, 70), 0);
    expect(bpmJump(100, 130), 30);
    final mix = [
      Song(path: 'a', medianBpm: 100),
      Song(path: 'b', medianBpm: 200),
      Song(path: 'c', medianBpm: 130),
    ];
    expect(bigJumps(mix), [1]);
    expect(pickWeighted([], Random(1)), isNull);
    final five = Song(path: 'five', rating: 5), zero = Song(path: 'zero');
    final r = Random(3);
    final picks = [for (var i = 0; i < 300; i++) pickWeighted([five, zero], r)!.path];
    expect(picks.where((p) => p == 'five').length, greaterThan(200));
    expect(builtinPrograms.map((t) => t.minutes), [
      closeTo(40, 0.01),
      closeTo(30, 0.01),
      closeTo(45, 0.01),
      closeTo(60, 0.01),
    ]);
    expect(classicProgram.parts, hasLength(8));
    final back = Program.fromJson(classicProgram.toJson());
    expect(back.parts.map((p) => p.name), classicProgram.parts.map((p) => p.name));
    expect(back.parts[2].minRpm, 60);
    final html = buildClassSheet('Mix <1>', [Song(path: 'p', title: 'T&C', duration: 125)],
        program: classicProgram, parts: [0]);
    expect(html, contains('The Warm-Up'));
    expect(html, contains('Mix &lt;1&gt;'));
    expect(html, contains('T&amp;C'));
    expect(html, contains('2:05'));
  });

  test('program auto-fill maps part RPM to song BPM incl. half time', () async {
    Song s(String n, double bpm) => Song(
        path: 'C:\\m\\$n.mp3', title: n, artist: 'A', medianBpm: bpm, duration: 240);
    for (final x in [
      s('warm', 85), s('climbHalf', 130), s('sprint', 100), s('other', 300),
    ]) {
      await db.upsertSong(x);
    }
    final st = AppState(db, random: Random(1)).mixer;
    const prog = Program('t', [
      ProgramPart('Warm', 4, 80, 90),
      ProgramPart('Climb', 4, 60, 70),
      ProgramPart('Silent', 3, 60, 70, music: false),
      ProgramPart('Hard', 4, 90, 105),
    ]);
    final missed = await st.fillProgram(prog);
    expect(missed, 0);
    expect(st.mix.map((m) => m.title), ['warm', 'climbHalf', 'sprint']);
    expect(st.mixPart, [0, 1, 3]);
    st.addToPart(s('cool', 65), 1);
    expect(st.mixPart, [0, 1, 1, 3]);
    final id = await db.saveMix('p', [for (final m in st.mix) m.path], parts: st.mixPart);
    expect(await db.mixParts(id), [0, 1, 1, 3]);
    await st.saveProgram(const Program('mine', [ProgramPart('X', 5, 70, 80)]));
    expect(st.programs.last.name, 'mine');
    final st2 = AppState(db).mixer;
    await st2.loadPrograms();
    expect(st2.userPrograms.single.parts.single.name, 'X');
  });

  test('mix key follows the mix through renames; saved copies get their own', () async {
    Song s(String n) => Song(path: 'C:\\m\\$n.mp3', title: n, artist: 'A', duration: 200);
    await db.upsertSong(s('a'));
    final st = AppState(db).mixer;
    st.mix = [s('a')];
    final key = st.mixKey;
    st.mixName = 'Gym';
    await st.saveMix();
    expect(st.mixKey, key);
    st.mixName = 'Gym 2025';
    await st.saveMix();
    expect(st.mixKey, key, reason: 'renamed mix keeps its phone identity');

    final old = st.savedMixes.firstWhere((m) => m.name == 'Gym');
    await st.loadMix(old);
    expect(st.mixKey, isNot(key), reason: 'the old saved copy is now a separate mixtape');
    final renamed = st.savedMixes.firstWhere((m) => m.name == 'Gym 2025');
    await st.loadMix(renamed);
    expect(st.mixKey, key);

    st.clearMix();
    expect(st.mixKey, isNot(key));
  });

  test('swap finds a candidate even when duration/steadiness is too tight for an exact match', () async {
    // Only songs whose duration is far outside cur's +/-60s window, and
    // whose steadiness fails the part's maxStddev: a tight match finds
    // nothing, but swap should still relax the search and succeed.
    await db.upsertSong(Song(
        path: 'C:\\m\\cur.mp3', title: 'cur', artist: 'A', medianBpm: 85, duration: 200, bpmStddev: 1));
    await db.upsertSong(Song(
        path: 'C:\\m\\far.mp3', title: 'far', artist: 'A', medianBpm: 85, duration: 500, bpmStddev: 20));
    final st = AppState(db, random: Random(1)).mixer;
    const prog = Program('t', [ProgramPart('Warm', 4, 80, 90, maxStddev: 8)]);
    st.mix = [
      Song(path: 'C:\\m\\cur.mp3', title: 'cur', artist: 'A', medianBpm: 85, duration: 200)
    ];
    st.mixPart = [0];
    st.program = prog;
    expect(await st.swap(0), isTrue);
    expect(st.mix.single.title, 'far');
  });

  test('swap on a manually-added song with no bpm/program part still finds a similar song', () async {
    await db.upsertSong(Song(path: 'C:\\m\\a.mp3', title: 'A', artist: 'X', duration: 200));
    await db.upsertSong(Song(path: 'C:\\m\\b.mp3', title: 'B', artist: 'X', duration: 210));
    final st = AppState(db, random: Random(1)).mixer;
    st.addToMix((await db.search(const SongQuery(text: 'A'))).first);
    expect(st.mixPart, [null]);
    expect(await st.swap(0), isTrue);
    expect(st.mix.single.title, 'B');
  });

  test('swap returns false once every other song is already in the mix', () async {
    await db.upsertSong(Song(path: 'C:\\m\\a.mp3', title: 'A', artist: 'X', duration: 200));
    final st = AppState(db, random: Random(1)).mixer;
    st.addToMix((await db.search(const SongQuery(text: 'A'))).first);
    expect(await st.swap(0), isFalse);
  });

  test('AppState keeps the mix in step with library edits', () async {
    Song s(String n) => Song(path: 'C:\\m\\$n.mp3', title: n, artist: 'A', duration: 200);
    await db.upsertSong(s('a'));
    await db.upsertSong(s('b'));
    final st = AppState(db);
    st.mixer.addToMix(s('a'));
    st.mixer.addToMix(s('b'));
    expect(st.mixPaths, [s('a').path, s('b').path]);
    await st.setRating(st.mixer.mix.first, 4);
    expect(st.mixer.mix.first.rating, 4);
    await st.removeFromLibrary(st.mixer.mix.first);
    expect(st.mixPaths, [s('b').path]);
    expect(st.mixer.mixPart, [null]);
  });

  test('a saved mix keeps its own program, so reloading it swaps against the right parts', () async {
    for (var k = 0; k < 10; k++) {
      await db.upsertSong(Song(
          path: 'C:\\m\\s$k.mp3', title: 'S$k', artist: 'A', medianBpm: 60.0 + k * 4, duration: 200));
    }
    final st = AppState(db, random: Random(1)).mixer;
    const customProg = Program('30 min intervals', [
      ProgramPart('Warm-up', 5, 80, 90),
      ProgramPart('Climb', 5, 60, 70),
      ProgramPart('Sprint', 3, 90, 105),
      ProgramPart('Recovery', 3, 70, 85),
      ProgramPart('Climb', 5, 60, 70),
      ProgramPart('Sprint', 3, 90, 105),
      ProgramPart('Recovery', 3, 70, 85),
      ProgramPart('Cool-down', 5, 60, 70),
    ]);
    st.program = customProg;
    await st.fillProgram(customProg);
    final savedPart = [...st.mixPart];
    await st.saveMix();

    // Simulate an app restart: a fresh AppState defaults to classicProgram
    // (7 parts), not the 8-part program the mix was built from.
    final st2 = AppState(db, random: Random(2)).mixer;
    expect(st2.program.name, classicProgramName);
    final info = (await db.mixes()).firstWhere((m) => m.name == st.mixName);
    await st2.loadMix(info);
    expect(st2.program.name, '30 min intervals');
    expect(st2.mixPart, savedPart);
    for (var i = 0; i < st2.mix.length; i++) {
      expect(await st2.swap(i), isTrue, reason: 'index $i (part ${st2.mixPart[i]})');
    }
  });

  test('preview starts at fastest segment, else 30% in', () {
    final s = Song(path: 'p', duration: 100);
    expect(PreviewService.startFor(s, const [TempoSeg(0, 10, 100), TempoSeg(10, 20, 130)]),
        const Duration(seconds: 10));
    expect(PreviewService.startFor(s, const []), const Duration(seconds: 30));
  });

  test('musicbrainz parse picks top tag and year, ignores weak matches', () {
    final info = MusicBrainz.parse({
      'recordings': [
        {
          'score': 100,
          'first-release-date': '1986-05-26',
          'tags': [
            {'name': 'rock', 'count': 1},
            {'name': 'hair metal', 'count': 5},
          ]
        }
      ]
    });
    expect(info!.genre, 'hair metal');
    expect(info.year, 1986);
    expect(
        MusicBrainz.parse({
          'recordings': [
            {'score': 40, 'first-release-date': '1986'}
          ]
        }),
        isNull);
  });
}
