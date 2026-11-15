import 'dart:convert';

import 'package:analyze_this/services/db.dart';
import 'package:analyze_this/services/musicbrainz.dart';
import 'package:analyze_this/services/relabel.dart';
import 'package:analyze_this/services/relabel_controller.dart';
import 'package:flutter_test/flutter_test.dart';

const _releaseJson = '''
{"id":"r1","title":"Perfect Tango","artist-credit":[{"name":"Astor","joinphrase":" & ","artist":{"name":"Astor"}},{"name":"Band","joinphrase":""}],
 "date":"1999-01-01",
 "media":[{"position":1,"tracks":[
  {"position":1,"title":"Milonga del Angel","length":240000,"recording":{"title":"Milonga del Angel"}},
  {"position":2,"title":"Libertango","length":200000,"recording":{"title":"Libertango"}},
  {"position":3,"title":"Adios Nonino","length":300000,"recording":{"title":"Adios Nonino"}}]}]}
''';

Song song(String path, String title, double secs, int no, {String artist = 'Unknown', String album = 'Misc'}) =>
    Song(path: path, title: title, artist: artist, album: album, duration: secs, trackNo: no);

void main() {
  final release = MusicBrainz.parseRelease(jsonDecode(_releaseJson) as Map<String, dynamic>)!;

  test('parseRelease joins artist credits and flattens tracks', () {
    expect(release.artist, 'Astor & Band');
    expect(release.tracks.map((t) => t.title), ['Milonga del Angel', 'Libertango', 'Adios Nonino']);
    expect(release.tracks[1].lengthMs, 200000);
    expect(release.tracks[1].artist, 'Astor & Band');
  });

  test('wrong titles still pair by length and track number, and give album, artist and title fixes', () {
    final songs = [
      song('a', 'Track 01', 240, 1),
      song('b', 'Libertango', 201, 2),
      song('c', 'Track 03', 299, 3),
    ];
    final s = planRelabel('k', songs, release)!;
    expect(s.matched, 3);
    expect(s.high, isFalse, reason: 'two of three titles disagree, so the user should review it');
    expect(s.confidence, greaterThanOrEqualTo(relabelMinConfidence));
    final changes = {for (final c in s.changes) '${c.path}.${c.field}': c.to};
    expect(changes['a.title'], 'Milonga del Angel');
    expect(changes['c.title'], 'Adios Nonino');
    expect(changes.containsKey('b.title'), isFalse);
    expect(changes['b.album'], 'Perfect Tango');
    expect(changes['b.artist'], 'Astor & Band');
  });

  test('right titles under a wrong album and artist are a high-confidence fix', () {
    final songs = [
      song('a', 'Milonga del Angel', 240, 1),
      song('b', 'Libertango', 200, 2),
      song('c', 'Adios Nonino', 300, 3),
    ];
    final s = planRelabel('k', songs, release)!;
    expect(s.high, isTrue);
    expect(s.changes.map((c) => c.field).toSet(), {'album', 'artist'});
  });

  test('an album that already matches yields no changes; an unrelated one yields no suggestion', () {
    final right = [
      song('a', 'Milonga del Angel', 240, 1, artist: 'Astor & Band', album: 'Perfect Tango'),
      song('b', 'Libertango', 200, 2, artist: 'Astor & Band', album: 'Perfect Tango'),
      song('c', 'Adios Nonino', 300, 3, artist: 'Astor & Band', album: 'Perfect Tango'),
    ];
    expect(planRelabel('k', right, release)!.changes, isEmpty);

    final other = [song('x', 'Something Else', 123, 9), song('y', 'Another', 400, 8)];
    expect(planRelabel('k', other, release), isNull);
  });

  group('controller', () {
    late MusicDb db;
    final writes = <String>[];

    setUp(() async {
      db = await MusicDb.open(':memory:');
      writes.clear();
    });
    tearDown(() => db.close());

    RelabelController controller() => RelabelController(db, MusicBrainz(),
        writer: (path, {title, artist, album}) async {
          writes.add('$path|$title|$artist|$album');
          return path.endsWith('.mp3');
        });

    test('apply stores overrides that a rescan keeps, and undo restores the old values', () async {
      await db.upsertSong(Song(path: 'a.mp3', title: 'Track 01', artist: 'Unknown', album: 'Misc'));
      await db.upsertSong(Song(path: 'b.flac', title: 'Track 02', artist: 'Unknown', album: 'Misc'));
      final c = controller();

      final r = await c.apply([
        const TrackChange('a.mp3', 'title', 'Track 01', 'Milonga del Angel'),
        const TrackChange('a.mp3', 'album', 'Misc', 'Perfect Tango'),
        const TrackChange('b.flac', 'title', 'Track 02', 'Libertango'),
      ]);
      expect((r.songs, r.filesWritten, r.dbOnly), (2, 1, 1));

      final a = (await db.song('a.mp3'))!;
      expect((a.title, a.album, a.artist), ('Milonga del Angel', 'Perfect Tango', 'Unknown'));
      expect((await db.override('b.flac'))?['title'], 'Libertango');
      expect(await c.undoableCount(), 2);

      final u = await c.undoLast();
      expect(u.songs, 2);
      final back = (await db.song('a.mp3'))!;
      expect((back.title, back.album), ('Track 01', 'Misc'));
      expect((await db.song('b.flac'))!.title, 'Track 02');
      expect(await c.undoableCount(), 0);
      // only the MP3 whose tags were changed is rewritten when undoing
      expect(writes.where((w) => w.startsWith('b.flac')), hasLength(1));
    });

    test('with writeFiles off no file is touched', () async {
      await db.upsertSong(Song(path: 'a.mp3', title: 'T', artist: 'A', album: 'B'));
      final r = await controller().apply([const TrackChange('a.mp3', 'title', 'T', 'U')], writeFiles: false);
      expect(writes, isEmpty);
      expect(r.dbOnly, 1);
      expect((await db.song('a.mp3'))!.title, 'U');
    });
  });
}
