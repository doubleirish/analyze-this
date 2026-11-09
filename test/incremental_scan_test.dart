import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:analyze_this/services/db.dart';
import 'package:analyze_this/services/genre_names.dart';
import 'package:analyze_this/services/musicbrainz.dart';
import 'package:analyze_this/services/scanner.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_core/shared_core.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _LyricsService extends EnrichService {
  int calls = 0;
  bool fail = false;
  LyricsHit? hit;
  Future<void>? gate;

  @override
  Future<LyricsHit?> fetchLyricsHit(TrackTags t, {double? durationSec, bool quick = false}) async {
    calls++;
    await gate;
    if (fail) throw const HttpException('offline');
    return hit;
  }
}

class _QueuedMusicBrainz extends MusicBrainz {
  _QueuedMusicBrainz(this.gate);
  final Future<void> gate;
  int calls = 0;

  @override
  Future<MbInfo?> lookup(String artist, String title, {bool refresh = false}) async {
    calls++;
    await gate;
    return const MbInfo(genre: 'rock', year: 1999);
  }
}

void main() {
  final sep = Platform.pathSeparator;

  group('RateMeter / EtaSmoother', () {
    test('a burst after a long pause does not look like a fast rate', () {
      var now = 0;
      final m = RateMeter(nowMs: () => now);
      for (var i = 0; i < 10; i++) {
        now += 1000;
        m.tick();
      }
      expect(m.perSec, 0, reason: 'still warming up');
      now = 120 * 1000; // two quiet minutes
      for (var i = 0; i < 10; i++) {
        m.tick();
      }
      // 20 items in 120 s, not 10 items in an instant
      expect(m.perSec, closeTo(20 / 120, 0.001));
    });

    test('displayed ETA counts down and moves only a step per update', () {
      var now = 0;
      final s = EtaSmoother(nowMs: () => now);
      expect(s.next(null), isNull);
      expect(s.next(const Duration(hours: 100)), const Duration(hours: 100));
      now += 1000;
      // within the update interval: just counts down
      expect(s.next(const Duration(minutes: 3)), const Duration(hours: 100) - const Duration(seconds: 1));
      now += 5000;
      final d = s.next(const Duration(minutes: 3))!;
      expect(d.inMinutes, greaterThan(80 * 60), reason: 'no jump from 100 h to 3 min');
      expect(s.next(Duration.zero), Duration.zero);
    });

    test('overall ETA is a lower bound while one operation is estimating', () {
      const p = ScanProgress(1, 10, '', analyze: OpStat(1, 10, 1), lyrics: OpStat(0, 10, 0), genre: OpStat.none);
      expect(p.eta, const Duration(seconds: 9));
      expect(p.etaIsLowerBound, isTrue);
    });
  });

  group('skipping finished artist folders', () {
    late Directory tmp;
    late MusicDb db;
    var calls = 0;
    var fail = false;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('incremental_scan_');
      db = await MusicDb.open(':memory:');
      calls = 0;
      fail = false;
    });

    tearDown(() async {
      await db.close();
      await tmp.delete(recursive: true);
    });

    Future<String> mp3(String artist, String title) async {
      final d = await Directory('${tmp.path}$sep$artist').create(recursive: true);
      final f = File('${d.path}$sep$artist - $title.mp3');
      await f.writeAsBytes(List.filled(100, 1));
      return f.path;
    }

    Scanner scanner() {
      final net = PoliteHttp(
        client: MockClient((r) async {
          calls++;
          if (fail) return http.Response('', 500);
          return http.Response(
            jsonEncode({
              'recordings': [
                {
                  'score': 100,
                  'tags': [
                    {'name': 'rock', 'count': 3},
                  ],
                },
              ],
            }),
            200,
          );
        }),
        maxRetries: 0,
        sleep: (_) async {},
      );
      return Scanner(
        db,
        net: net,
        musicBrainz: MusicBrainz(net: net),
      );
    }

    const opts = ScanOptions(analyzeBpm: false, fetchLyrics: false, lookupMusicBrainz: true);

    Future<ScanProgress> scan(Scanner s, [ScanOptions o = opts]) async {
      ScanProgress? last;
      final errors = await s.scanAll([tmp.path], options: o, onProgress: (p) => last = p);
      expect(errors, isEmpty);
      return last!;
    }

    for (final blockLyrics in [false, true]) {
      test(
        '${blockLyrics ? 'genre/year' : 'lyrics'} queue progresses independently and joins folder completion',
        () async {
          final paths = [for (var i = 0; i < 4; i++) await mp3('Band', 'Track $i')];
          // Cover both unchanged rows and songs arriving from the local workers.
          if (blockLyrics) {
            for (final path in paths) {
              final st = await File(path).stat();
              await db.upsertSong(
                Song(
                  path: path,
                  artist: 'Band',
                  title: baseName(path),
                  size: st.size,
                  mtime: st.modified.millisecondsSinceEpoch,
                  medianBpm: 120,
                  tagsV: 1,
                ),
              );
            }
          }
          final gate = Completer<void>();
          final lyrics = _LyricsService()
            ..gate = blockLyrics ? gate.future : null
            ..hit = LyricsHit('Some words', 'test', 'Test', false);
          final brainz = _QueuedMusicBrainz(blockLyrics ? Future.value() : gate.future);
          final s = Scanner(db, enricher: lyrics, musicBrainz: brainz, lyricsWorkers: 1, genreWorkers: 1);
          final advanced = Completer<void>();
          ScanProgress? last;
          final options = opts.copyWith(fetchLyrics: true, lookupYear: true, checkAudio: false);
          final running = s.scanAll(
            [tmp.path],
            options: options,
            onProgress: (p) {
              last = p;
              if (p.onlineDone == paths.length && !advanced.isCompleted) advanced.complete();
            },
          );
          try {
            await advanced.future.timeout(const Duration(seconds: 5));
            expect(blockLyrics ? lyrics.calls : brainz.calls, 1, reason: 'blocked pool respects its worker limit');
            expect(blockLyrics ? brainz.calls : lyrics.calls, paths.length);
            expect(last!.onlineTotal, paths.length * 2);
            expect(await db.scanDirs(), isEmpty, reason: 'folder must wait for both stages');
            for (final path in paths) {
              final row = (await db.song(path))!;
              expect(row.lyricsChecked, !blockLyrics);
              expect(row.mbChecked, blockLyrics);
              expect(row.yearChecked, blockLyrics);
              if (!blockLyrics) expect(row.lyrics, 'Some words');
              if (blockLyrics) expect(row.year, 1999);
            }
          } finally {
            gate.complete();
            expect(await running.timeout(const Duration(seconds: 5)), isEmpty);
          }
          expect(last!.onlineDone, last!.onlineTotal);
          expect((await db.scanDirs()).values.single.$2 & ScanOps.of(options), ScanOps.of(options));
          for (final path in paths) {
            final row = (await db.song(path))!;
            expect(row.lyrics, 'Some words');
            expect(row.genre, 'rock');
            expect(row.year, 1999);
            expect(row.lyricsChecked && row.mbChecked && row.yearChecked, isTrue);
          }
        },
      );
    }

    test('a failed stage keeps only its folder bits unfinished and preserves the other stage', () async {
      final path = await mp3('Band', 'Track');
      final lyrics = _LyricsService()..fail = true;
      final brainz = _QueuedMusicBrainz(Future.value());
      final s = Scanner(db, enricher: lyrics, musicBrainz: brainz);
      final options = opts.copyWith(fetchLyrics: true, lookupYear: true, checkAudio: false);
      expect(await s.scanAll([tmp.path], options: options), isNotEmpty);
      final row = (await db.song(path))!;
      expect(row.lyricsChecked, isFalse);
      expect(row.mbChecked && row.yearChecked, isTrue);
      final bits = (await db.scanDirs()).values.single.$2;
      expect(bits & ScanOps.lyrics, 0);
      expect(bits & (ScanOps.genre | ScanOps.year), ScanOps.genre | ScanOps.year);
      lyrics.fail = false;
      expect(await s.scanAll([tmp.path], options: options.copyWith(refreshOnline: true)), isEmpty);
      expect(brainz.calls, 1, reason: 'successful metadata does not need another lookup');
      expect((await db.song(path))!.year, 1999);
    });

    test('cancellation stops queued work and does not finish a partially processed folder', () async {
      for (var i = 0; i < 4; i++) {
        await mp3('Band', 'Track $i');
      }
      final gate = Completer<void>();
      final brainz = _QueuedMusicBrainz(gate.future);
      final lyrics = _LyricsService();
      final s = Scanner(db, enricher: lyrics, musicBrainz: brainz, lyricsWorkers: 1, genreWorkers: 1);
      final advanced = Completer<void>();
      final running = s.scanAll(
        [tmp.path],
        options: opts.copyWith(fetchLyrics: true, checkAudio: false),
        onProgress: (p) {
          if (p.onlineDone == 4 && !advanced.isCompleted) advanced.complete();
        },
      );
      try {
        await advanced.future.timeout(const Duration(seconds: 5));
        s.cancelled = true;
      } finally {
        gate.complete();
        expect(await running.timeout(const Duration(seconds: 5)), isEmpty);
      }
      expect(brainz.calls, 1);
      expect(await db.scanDirs(), isEmpty);
      expect((await db.search(const SongQuery())).every((s) => s.lyricsChecked), isTrue);
    });

    test('finished folders are skipped; changed or forced ones are scanned', () async {
      await mp3('Abba', 'Waterloo');
      await mp3('Blur', 'Parklife');
      final s = scanner();

      var p = await scan(s);
      expect(p.skippedDirs, 0);
      expect(p.analyze.total, 2);
      expect(calls, greaterThan(0));

      calls = 0;
      p = await scan(s);
      expect(p.skippedDirs, 2);
      expect(p.analyze.total, 0);
      expect(calls, 0);

      // a new file only re-opens its own artist folder
      await mp3('Blur', 'Song 2');
      p = await scan(s);
      expect(p.skippedDirs, 1);
      expect(p.analyze.total, 2);
      expect((await db.search(const SongQuery(genre: 'rock'))), hasLength(3));

      // a newly requested kind of work re-opens the folders
      p = await scan(s, opts.copyWith(lookupYear: true));
      expect(p.skippedDirs, 0);

      p = await scan(s, opts.copyWith(forceFull: true));
      expect(p.skippedDirs, 0);
      expect(p.analyze.total, 3);
      p = await scan(s);
      expect(p.skippedDirs, 2);
    });

    test('failed lookups cool down across scans; explicit refresh retries', () async {
      await mp3('Abba', 'Waterloo');
      final s = scanner();
      fail = true;
      expect(await s.scanAll([tmp.path], options: opts), isNotEmpty);
      fail = false;
      calls = 0;
      expect(await scanner().scanAll([tmp.path], options: opts), isNotEmpty);
      expect(calls, 0);
      await scan(s, opts.copyWith(refreshOnline: true));
      expect(calls, greaterThan(0));
      expect((await db.search(const SongQuery(genre: 'rock'))), hasLength(1));
    });

    test('expired lookup failure is retried', () async {
      await mp3('Abba', 'Waterloo');
      await db.saveOnlineCache(
        'i|abba|t|waterloo',
        null,
        DateTime.now().subtract(const Duration(days: 31)).millisecondsSinceEpoch,
        error: 'offline',
      );
      await scan(scanner());
      expect(calls, greaterThan(0));
      expect((await db.search(const SongQuery(genre: 'rock'))), hasLength(1));
    });

    test('force-full skips unchanged local analysis without losing BPM or favourites', () async {
      final f = await mp3('Abba', 'Waterloo');
      final st = await File(f).stat();
      await db.upsertSong(
        Song(
          path: f,
          size: st.size,
          mtime: st.modified.millisecondsSinceEpoch,
          title: 'Waterloo',
          artist: 'Abba',
          medianBpm: 120,
          fav: true,
          tagsV: 1,
        ),
      );
      final p = await scan(scanner(), opts.copyWith(forceFull: true, checkAudio: false));
      expect(p.analyze.total, 0);
      expect((await db.song(f))!.medianBpm, 120);
      expect((await db.song(f))!.fav, isTrue);
      expect((await db.song(f))!.genre, 'rock');
    });

    test('local-only scan never contacts online providers', () async {
      await mp3('Abba', 'Waterloo');
      await scan(scanner(), opts.copyWith(forceFull: true, localOnly: true));
      expect(calls, 0);
      expect((await db.search(const SongQuery())).single.mbChecked, isFalse);
      await scan(scanner());
      expect(calls, greaterThan(0));
    });

    test('persisted album results answer new tracks after restarting the scanner', () async {
      final a = await mp3('Abba', 'Waterloo');
      await scanner().quickScan([tmp.path]);
      await db.setOverrides([a], album: 'Hits');
      await scan(scanner(), opts.copyWith(lookupYear: true));
      final b = await mp3('Abba', 'SOS');
      await scanner().quickScan([tmp.path]);
      await db.setOverrides([b], album: 'Hits');
      calls = 0;
      await scan(scanner(), opts.copyWith(lookupYear: true));
      expect(calls, 0);
      expect((await db.song(b))!.genre, 'rock');
      expect((await db.song(b))!.yearChecked, isTrue);
    });

    test('lyrics failures cool down, retry mode bypasses them and keeps local lyrics', () async {
      final f = await mp3('Abba', 'Waterloo');
      final lyrics = _LyricsService()..fail = true;
      final options = opts.copyWith(fetchLyrics: true, lookupMusicBrainz: false);
      expect(await Scanner(db, enricher: lyrics).scanAll([tmp.path], options: options), isNotEmpty);
      expect(lyrics.calls, 1);
      expect((await db.song(f))!.lyricsChecked, isFalse);

      lyrics.fail = false;
      expect(await Scanner(db, enricher: lyrics).scanAll([tmp.path], options: options), isNotEmpty);
      expect(lyrics.calls, 1);
      expect(
        await Scanner(db, enricher: lyrics).scanAll([tmp.path], options: options.copyWith(refreshOnline: true)),
        isEmpty,
      );
      expect(lyrics.calls, 2);
      expect((await db.song(f))!.lyricsChecked, isTrue);

      // A sidecar added after a previous miss wins without an online request.
      await File('$f.lrc').writeAsString('[00:01.00]local lyrics');
      expect(
        await Scanner(db, enricher: lyrics).scanAll([tmp.path], options: options.copyWith(refreshOnline: true)),
        isEmpty,
      );
      expect(lyrics.calls, 2);
      expect((await db.song(f))!.lyrics, contains('local lyrics'));
    });

    test('lyrics misses persist for new duplicate tracks and explicit retry finds lyrics', () async {
      final f = await mp3('Abba', 'Waterloo');
      final lyrics = _LyricsService();
      final options = opts.copyWith(fetchLyrics: true, lookupMusicBrainz: false);
      expect(await Scanner(db, enricher: lyrics).scanAll([tmp.path], options: options), isEmpty);
      final other = await mp3('More', 'Waterloo');
      await scanner().quickScan([tmp.path]);
      await db.setOverrides([other], artist: 'Abba');
      expect(await Scanner(db, enricher: lyrics).scanAll([tmp.path], options: options), isEmpty);
      expect(lyrics.calls, 1);

      lyrics.hit = LyricsHit('[00:01.00]found lyrics', 'test', 'Test', true);
      expect(
        await Scanner(db, enricher: lyrics).scanAll([tmp.path], options: options.copyWith(refreshOnline: true)),
        isEmpty,
      );
      expect(lyrics.calls, 2, reason: 'duplicates share one in-flight lookup');
      expect((await db.song(f))!.lyrics, contains('found lyrics'));
      expect((await db.song(other))!.lyrics, contains('found lyrics'));
    });

    test('cache migration preserves existing songs and results survive reopening', () async {
      final path = '${tmp.path}${sep}library.db';
      var disk = await MusicDb.open(path);
      await disk.upsertSong(Song(path: 'song', title: 'Title', fav: true));
      await disk.close();
      final legacy = await databaseFactoryFfi.openDatabase(path);
      await legacy.execute('DROP TABLE online_cache');
      await legacy.execute('PRAGMA user_version = 19');
      await legacy.close();
      disk = await MusicDb.open(path);
      expect((await disk.song('song'))!.fav, isTrue);
      await disk.saveOnlineCache('g|artist|a|album', 'Rock', 123);
      await disk.close();
      disk = await MusicDb.open(path);
      try {
        expect(await disk.onlineCache('g|artist|a|album'), ('Rock', 123, null));
        expect((await disk.song('song'))!.fav, isTrue);
      } finally {
        await disk.close();
      }
    });

    test('retry mode keeps existing lyrics, genre and year', () async {
      final f = await mp3('Abba', 'Waterloo');
      final st = await File(f).stat();
      await db.upsertSong(
        Song(
          path: f,
          size: st.size,
          mtime: st.modified.millisecondsSinceEpoch,
          title: 'Waterloo',
          artist: 'Abba',
          medianBpm: 120,
          tagsV: 1,
          lyrics: 'my lyrics',
          genre: 'Pop',
          year: 1974,
        ),
      );
      final lyrics = _LyricsService()..fail = true;
      expect(
        await Scanner(db, enricher: lyrics).scanAll([
          tmp.path,
        ], options: opts.copyWith(fetchLyrics: true, lookupYear: true, refreshOnline: true, checkAudio: false)),
        isEmpty,
      );
      expect(lyrics.calls, 0);
      final row = (await db.song(f))!;
      expect((row.lyrics, row.genre, row.year), ('my lyrics', 'Pop', 1974));
    });

    test('batched local writes replace segments and preserve user-owned trim', () async {
      await db.upsertSong(Song(path: 'a'), segments: [TempoSeg(0, 10, 100)]);
      await db.setTrim('a', 2, 8);
      await db.upsertSongs([
        (Song(path: 'a', medianBpm: 120), [TempoSeg(0, 12, 120)]),
        (Song(path: 'b', medianBpm: 130), [TempoSeg(0, 15, 130)]),
      ]);
      final a = (await db.song('a'))!;
      expect((a.medianBpm, a.trimStart, a.trimEnd), (120, 2, 8));
      expect((await db.segmentsOf('a')).single.bpm, 120);
      expect((await db.segmentsOf('b')).single.bpm, 130);
    });

    test('quick scan re-opens the folder of a re-tagged file', () async {
      final f = await mp3('Abba', 'Waterloo');
      await mp3('Blur', 'Parklife');
      final s = scanner();
      await scan(s);
      await File(f).writeAsBytes(List.filled(120, 1));
      await s.quickScan([tmp.path]);
      final p = await scan(s);
      expect(p.skippedDirs, 1);
      expect(p.analyze.total, 1);
    });

    test('complete rows skip the local pass but still get their lookups', () async {
      final f = await mp3('Abba', 'Waterloo');
      final st = await File(f).stat();
      await db.upsertSong(
        Song(
          path: f,
          size: st.size,
          mtime: st.modified.millisecondsSinceEpoch,
          title: 'Waterloo',
          artist: 'Abba',
          medianBpm: 120,
          tagsV: 1,
        ),
      );
      final s = scanner();
      final p = await scan(s, opts.copyWith(checkAudio: false));
      expect(p.analyze.total, 0);
      expect(p.genre.done, 1);
      expect((await db.song(f))!.genre, 'rock');
      expect((await db.song(f))!.medianBpm, 120);
    });

    test('folders go by genre size, late genres then unknown last', () async {
      final songs = <String, List<String>>{
        'Zed': [await mp3('Zed', 'a'), await mp3('Zed', 'b')],
        'Pop1': [await mp3('Pop1', 'a')],
        'Rock1': [await mp3('Rock1', 'a'), await mp3('Rock1', 'b'), await mp3('Rock1', 'c')],
        'Cow': [for (var i = 0; i < 5; i++) await mp3('Cow', 'n$i')],
        'Nogenre': [await mp3('Nogenre', 'a')],
      };
      final s = scanner();
      await s.quickScan([tmp.path]);
      await db.setOverrides(songs['Rock1']!, genre: 'Rock');
      await db.setOverrides(songs['Zed']!, genre: 'Rock');
      await db.setOverrides(songs['Pop1']!, genre: 'Pop');
      await db.setOverrides(songs['Cow']!, genre: 'Alt-Country');
      final order = <String>[];
      await s.scanAll(
        [tmp.path],
        options: const ScanOptions(analyzeBpm: false, fetchLyrics: false, lookupMusicBrainz: false, checkAudio: false),
        onProgress: (p) {
          final d = p.current.split(' - ').first;
          if (p.current.contains(' - ') && !order.contains(d)) order.add(d);
        },
      );
      // Rock has 5 songs (Rock1 + Zed), Pop 1; Country-like and unknown last
      expect(order, ['Rock1', 'Zed', 'Pop1', 'Cow', 'Nogenre']);
    });

    test('isLateGenre matches whole words only', () {
      for (final g in ['Alt-Country', 'Neo-Soul', 'Southern Gospel', 'Roots Reggae', 'Stand-Up Comedy', 'Folk']) {
        expect(isLateGenre(g), isTrue, reason: g);
      }
      for (final g in ['Rock', 'Dubstep', 'Pop', 'Skate Punk']) {
        expect(isLateGenre(g), isFalse, reason: g);
      }
    });

    test('songs of one album count as a single genre lookup', () async {
      final a = await mp3('Abba', 'Waterloo');
      final b = await mp3('Abba', 'SOS');
      final s = scanner();
      await s.quickScan([tmp.path]);
      await db.setOverrides([a, b], album: 'Hits');
      final p = await scan(s);
      expect(p.genre.total, 1);
      expect(p.genre.done, 1);
    });
    test('a year turned on later is looked up once, even after the genre lookup', () async {
      final f = await mp3('Abba', 'Waterloo');
      final s = scanner();
      await scan(s);
      expect((await db.song(f))!.mbChecked, isTrue);
      expect((await db.song(f))!.yearChecked, isFalse);

      await scan(s, opts.copyWith(lookupYear: true));
      expect((await db.song(f))!.yearChecked, isTrue);

      // looked up already: a forced rescan doesn't ask again
      final seen = (await db.song(f))!;
      final p = await scan(s, opts.copyWith(lookupYear: true, forceFull: true));
      expect(p.genre.total, 0);
      expect((await db.song(f))!.yearChecked, seen.yearChecked);
    });

    test('coverage counts found, looked-up and missing data per group', () async {
      final a = await mp3('Abba', 'Waterloo');
      final b = await mp3('Abba', 'SOS');
      final c = await mp3('Blur', 'Parklife');
      Future<void> put(
        String p,
        String artist,
        String title, {
        double? bpm,
        String? lyrics,
        bool lyricsChecked = false,
        int? year,
        String? genre,
        bool mb = false,
        bool yr = false,
      }) async {
        final st = await File(p).stat();
        await db.upsertSong(
          Song(
            path: p,
            size: st.size,
            mtime: st.modified.millisecondsSinceEpoch,
            title: title,
            artist: artist,
            album: 'Hits',
            medianBpm: bpm,
            lyrics: lyrics,
            lyricsChecked: lyricsChecked,
            year: year,
            genre: genre,
            mbChecked: mb,
            yearChecked: yr,
            tagsV: 1,
          ),
        );
      }

      await put(a, 'Abba', 'Waterloo', bpm: 120, lyrics: 'la', lyricsChecked: true, year: 1974, genre: 'Pop');
      await put(b, 'Abba', 'SOS', lyricsChecked: true, mb: true, yr: true);
      await put(c, 'Blur', 'Parklife');

      final abba = await db.coverageOf(artist: 'abba');
      expect((abba.songs, abba.bpm, abba.lyrics, abba.lyricsChecked), (2, 1, 1, 1));
      expect((abba.year, abba.yearChecked, abba.genre, abba.genreChecked), (1, 1, 1, 1));
      expect(abba.overall, closeTo(0.5, 1e-9));

      final byArtist = {for (final x in await db.artists()) x.name: x.coverage};
      expect(byArtist['Blur']!.songs, 1);
      expect(byArtist['Blur']!.lyrics + byArtist['Blur']!.genre, 0);
      expect((await db.genreSummaries()).single.coverage.genre, 1);
      expect((await db.albums()).where((x) => x.artist == 'Abba').single.coverage.songs, 2);
      expect((await db.coverageOf(noGenre: true)).songs, 2);

      // tempo missing, but a file that cannot be decoded counts as looked up
      await db.recordHealth(b, damaged: true, reason: 'could not decode: x', depth: 'decode', size: 100, mtime: 1);
      expect((await db.coverageOf(artist: 'Abba')).bpmChecked, 1);

      Future<List<String>> missing({bool year = false, bool lyrics = true}) =>
          db.incompletePaths(artist: 'Abba', fetchLyrics: lyrics, lookupMusicBrainz: true, lookupYear: year);
      expect(await missing(), isEmpty);
      expect(await db.incompletePaths(artist: 'Blur'), [c]);
      expect(await db.incompletePaths(artist: 'Blur', fetchLyrics: false, lookupMusicBrainz: false), [c]);
    });
  });
}
