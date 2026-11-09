import 'dart:convert';
import 'dart:io';

import 'package:analyze_this/services/db.dart';
import 'package:analyze_this/services/mixtape_export.dart';
import 'package:analyze_this/services/phone_sync.dart';
import 'package:analyze_this/services/share.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_core/shared_core.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _a = 'C:\\m\\a.mp3';
const _b = 'C:\\m\\b.mp3';
const _c = 'C:\\m\\c.mp3';

JournalEntry _play(int seq, {int at = 1000000, String? origPath, String? sha, String? title,
        String? artist, double? duration, String device = 'ph1'}) =>
    JournalEntry(
        seq: seq,
        type: JournalEntry.play,
        at: at,
        device: device,
        path: '/storage/emulated/0/Music/x.mp3',
        origPath: origPath,
        sha256: sha,
        title: title,
        artist: artist,
        duration: duration,
        listened: 120,
        done: true);

JournalEntry _rate(int seq, String origPath, {int? rating, bool? fav}) => JournalEntry(
    seq: seq,
    type: JournalEntry.rate,
    at: 2000000 + seq,
    device: 'ph1',
    origPath: origPath,
    rating: rating,
    fav: fav);

void main() {
  late MusicDb db;

  setUp(() async {
    db = await MusicDb.open(':memory:');
    await db.upsertSong(Song(
        path: _a,
        title: "Don't Stop",
        artist: 'Fleetwood Mac',
        duration: 190,
        dupKey: dupKeyFor('Fleetwood Mac', "Don't Stop")));
    await db.upsertSong(Song(path: _b, title: 'Song B', artist: 'Band', duration: 200));
    await db.upsertSong(Song(path: _c, title: 'Song B', artist: 'Band', duration: 201));
  });
  tearDown(() => db.close());

  group('PathResolver', () {
    test('matches origPath, then sent sha256, then title/artist/duration', () async {
      await db.recordSentTracks([(sha256: 'h1', path: _a), (sha256: 'gone', path: 'C:\\x.mp3')]);
      final r = PathResolver(db);
      expect(await r.resolve(const TrackRef(origPath: _b, sha256: 'h1')), _b);
      expect(await r.resolve(const TrackRef(origPath: 'D:\\moved.mp3', sha256: 'h1')), _a);
      // The sent file is no longer in the library.
      expect(await r.resolve(const TrackRef(sha256: 'gone')), isNull);
      expect(
          await r.resolve(
              const TrackRef(title: 'dont stop!', artist: 'FLEETWOOD MAC', duration: 191.5)),
          _a);
      expect(
          await r.resolve(const TrackRef(title: "Don't Stop", artist: 'Fleetwood Mac', duration: 195)),
          isNull);
    });

    test('ambiguous fuzzy matches are unmatched', () async {
      final r = PathResolver(db);
      expect(await r.resolve(const TrackRef(title: 'Song B', artist: 'Band', duration: 200.5)),
          isNull);
      expect(await r.resolve(const TrackRef(title: 'Song B', artist: 'Band', duration: 198.5)), _b);
    });
  });

  group('PhoneSync.importJournal', () {
    test('imports plays, counts unmatched and skips entries up to the cursor', () async {
      PhoneSyncResult? hooked;
      final sync = PhoneSync(db, onImported: (r) => hooked = r);
      final entries = [
        _play(1, origPath: _a, at: 1000),
        _play(2, title: 'Nope', artist: 'Nobody', duration: 100, at: 2000),
        _play(3, origPath: _b, at: 3000),
      ];
      final r = await sync.importJournal('ph1', entries);
      expect((r.plays, r.ratings, r.unmatched, r.ackSeq), (2, 0, 1, 3));
      expect(hooked?.playedPaths, [_a, _b]);
      expect(await db.setting(PhoneSync.cursorKey('ph1')), '3');

      final again = await sync.importJournal('ph1', [...entries, _play(4, origPath: _a, at: 900000)]);
      expect((again.plays, again.unmatched, again.ackSeq), (1, 0, 4));
      expect((await db.playStat(_a)).plays, 2);
      expect((await db.playStat(_b)).plays, 1);

      final none = await sync.importJournal('ph1', entries);
      expect((none.plays, none.ackSeq), (0, 4));
      // Cursors are per device.
      expect((await sync.importJournal('ph2', entries)).ackSeq, 3);
    });

    test('rating entries are applied in seq order', () async {
      final r = await PhoneSync(db).importJournalText(
          'ph1',
          [
            _rate(3, _a, rating: 2, fav: false),
            _rate(1, _a, rating: 5, fav: true),
            _rate(2, _b, rating: 4),
          ].map((e) => jsonEncode(e.toJson())).join('\n'));
      expect((r.ratings, r.ackSeq), (3, 3));
      final a = await db.song(_a), b = await db.song(_b);
      expect((a!.rating, a.fav), (2, false));
      expect((b!.rating, b.fav), (4, false));
    });

    test('a play already logged by beats-me on Windows is not doubled', () async {
      final dir = await Directory.systemTemp.createTemp('phone_sync_');
      addTearDown(() => dir.delete(recursive: true));
      await playsLog(dir).writeAsString('${jsonEncode({
            'path': 'C:\\phonecopy\\a.mp3',
            'origPath': _a,
            'at': 50000,
            'listened': 100,
            'done': true,
            'app': 'beats-me',
          })}\n');
      expect(await importSharedPlays(db, dir: dir), 1);
      expect((await db.playStat(_a)).plays, 1);

      final r = await PhoneSync(db).importJournal('ph1', [_play(1, origPath: _a, at: 52000)]);
      expect(r.plays, 0);
      expect((await db.playStat(_a)).plays, 1);
      // And the other way round: re-reading the log adds nothing.
      expect(await importSharedPlays(db, dir: dir), 0);
    });

    test('importJournalByDevice keeps a cursor per device', () async {
      final text = [
        _play(1, origPath: _a, at: 1000, device: 'p1'),
        _play(1, origPath: _b, at: 1000, device: 'p2'),
      ].map((e) => jsonEncode(e.toJson())).join('\n');
      final r = await PhoneSync(db).importJournalByDevice(text);
      expect(r.plays, 2);
      expect(await db.setting(PhoneSync.cursorKey('p1')), '1');
      expect(await db.setting(PhoneSync.cursorKey('p2')), '1');
    });
  });

  test('writing a package records sent tracks', () async {
    final dir = await Directory.systemTemp.createTemp('phone_sync_pkg_');
    addTearDown(() => dir.delete(recursive: true));
    final src = File('${dir.path}${Platform.pathSeparator}song.mp3')..writeAsBytesSync([1, 2, 3, 4]);
    await db.upsertSong(Song(path: src.path, title: 'Pkg', artist: 'Art', duration: 1));
    final m = await PackageWriter(ffmpegPath: null).write(
        id: 'mix1',
        name: 'Mix',
        transport: 'folder',
        sources: [MixtapeSource(path: src.path, title: 'Pkg', artist: 'Art')],
        out: Directory('${dir.path}${Platform.pathSeparator}out'));
    await MixtapeExport.recordSent(db, m);
    final sha = m.tracks.single.sha256;
    expect(await db.sentTrackPaths([sha]), {sha: src.path});
    expect(await PathResolver(db).resolve(TrackRef(sha256: sha)), src.path);
  });

  test('upgrading a v12 database adds sent_tracks and keeps the data', () async {
    final tmp = await Directory.systemTemp.createTemp('phone_sync_db_');
    addTearDown(() => tmp.delete(recursive: true));
    final path = '${tmp.path}${Platform.pathSeparator}old.db';
    final old = await MusicDb.open(path);
    await old.upsertSong(Song(path: _a, title: 'x', rating: 3));
    await old.close();

    var raw = await databaseFactoryFfi.openDatabase(path);
    await raw.execute('DROP TABLE sent_tracks');
    await raw.setVersion(12);
    await raw.close();

    final up = await MusicDb.open(path);
    expect((await up.song(_a))!.rating, 3);
    await up.recordSentTracks([(sha256: 'h', path: _a)]);
    expect(await up.sentTrackPaths(['h']), {'h': _a});
    await up.close();
    raw = await databaseFactoryFfi.openDatabase(path);
    expect(await raw.getVersion(), greaterThanOrEqualTo(13));
    await raw.close();
  });
}
