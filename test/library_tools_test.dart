import 'dart:io';

import 'package:analyze_this/services/db.dart';
import 'package:analyze_this/services/library_tools.dart';
import 'package:analyze_this/services/share.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;
  late MusicDb db;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('lib_tools_');
    db = await MusicDb.open(':memory:');
  });

  tearDown(() async {
    await db.close();
    await tmp.delete(recursive: true);
  });

  Future<Song> addSong(String name, {String? artist, String? album, String? title, int rating = 0}) async {
    final f = File('${tmp.path}${Platform.pathSeparator}$name');
    await f.writeAsBytes([1, 2, 3]);
    final s = Song(path: f.path, size: 3, artist: artist, album: album, title: title, rating: rating);
    await db.upsertSong(s);
    return s;
  }

  test('genres group ignoring case; artists appear under each of their genres', () async {
    Future<void> add(String n, String artist, String album, String? genre) =>
        db.upsertSong(Song(path: n, artist: artist, album: album, genre: genre));
    await add('1', 'A', 'X', 'Rock');
    await add('2', 'A', 'X', 'rock');
    await add('3', 'A', 'Y', 'Jazz');
    await add('4', 'B', 'Z', 'Rock');
    await add('5', 'C', 'W', null);
    await add('6', 'C', 'W', '  ');

    final g = await db.genreSummaries();
    expect(g.map((e) => (e.name.toLowerCase(), e.songs, e.artists, e.albums)),
        [('rock', 3, 2, 2), ('jazz', 1, 1, 1)]);
    expect((await db.genreSummaries(filter: 'ja')).single.name, 'Jazz');
    expect(g.first.samples, hasLength(2));

    expect((await db.artists(genre: 'ROCK')).map((a) => a.name).toSet(), {'A', 'B'});
    expect((await db.artists(genre: 'jazz')).single.name, 'A');
    expect((await db.albums(genre: 'rock')).map((a) => a.album).toSet(), {'X', 'Z'});
  });

  test('tidy names', () {
    expect(tidyName('Beatles, The', moveThe: true), 'The Beatles');
    expect(tidyName('  some   artist ft. other'), 'Some Artist feat. Other');
    expect(tidyName('AC/DC'), 'AC/DC');
    expect(tidyGenre('hip hop'), 'Hip-Hop');
  });

  test('tag cleanup merges case variants into the most common spelling', () {
    final songs = [
      Song(path: 'a', artist: 'Daft Punk'),
      Song(path: 'b', artist: 'Daft Punk'),
      Song(path: 'c', artist: 'daft punk'),
      Song(path: 'd', artist: 'DAFT PUNK'),
    ];
    final fixes = planTagCleanup(songs);
    expect(fixes.every((f) => f.to == 'Daft Punk' && f.field == 'artist'), isTrue);
    expect(fixes.expand((f) => f.paths).toSet(), {'c', 'd'});
  });

  test('organize plan skips clashes and unchanged paths', () {
    final a = Song(path: r'C:\m\x.mp3', artist: 'A', album: 'B', title: 'T');
    final b = Song(path: r'C:\m\y.mp3', artist: 'A', album: 'B', title: 'T');
    final ok = Song(path: r'C:\root\A\B\Z.mp3', artist: 'A', album: 'B', title: 'Z');
    final plan = planOrganize([a, b, ok], r'C:\root', exists: (_) => false);
    expect(plan.moves, hasLength(1));
    expect(plan.moves.first.to, endsWith('A${Platform.pathSeparator}B${Platform.pathSeparator}T.mp3'));
    expect(plan.skipped, [b.path]);
  });

  test('organizer moves files and sidecars, updates db, and undoes', () async {
    final s = await addSong('x.mp3', artist: 'Art', album: 'Alb', title: 'Tit');
    await File('${s.path}.bpm').writeAsString('{}');
    await db.setRating(s.path, 4);
    final plan = planOrganize(await db.allSongs(), '${tmp.path}${Platform.pathSeparator}lib');
    final org = Organizer(db);
    final done = await org.apply(plan.moves);
    expect(done, hasLength(1));
    final to = done.first.to;
    expect(File(to).existsSync(), isTrue);
    expect(File('$to.bpm').existsSync(), isTrue);
    expect(File(s.path).existsSync(), isFalse);
    expect((await db.song(to))?.rating, 4);
    expect(await org.undo(), 1);
    expect(File(s.path).existsSync(), isTrue);
    expect((await db.song(s.path))?.rating, 4);
  });

  test('missing files are found', () async {
    final s = await addSong('gone.mp3');
    await File(s.path).delete();
    await addSong('here.mp3');
    expect((await findMissing(await db.allSongs())).map((e) => e.path), [s.path]);
  });

  test('play history counts completed or long listens, not skips', () async {
    final s = await addSong('p.mp3', artist: 'A', title: 'P');
    await db.recordPlay(s.path, 200, true);
    await db.recordPlay(s.path, 45, false);
    await db.recordPlay(s.path, 5, false);
    final st = await db.playStat(s.path);
    expect((st.plays, st.skips), (2, 1));
    expect((await db.mostPlayed()).single.plays, 2);
    expect((await db.mostSkipped()).single.skips, 1);
  });

  test('forgotten favorites exclude recently played', () async {
    final a = await addSong('a.mp3', rating: 5);
    final b = await addSong('b.mp3', rating: 5);
    await db.recordPlay(b.path, 100, true);
    expect((await db.forgottenFavorites()).map((e) => e.path), [a.path]);
  });

  test('bundle round trip merges and play import dedupes', () async {
    final s = await addSong('b.mp3', rating: 3);
    await db.addTag(s.path, 'chill');
    await db.setFav(s.path, true);
    await db.saveMix('m', [s.path]);
    await db.recordPlay(s.path, 99, true, at: 1000);
    final file = File('${tmp.path}${Platform.pathSeparator}bundle.json');
    await exportBundleTo(db, file);

    final db2 = await MusicDb.open('${tmp.path}${Platform.pathSeparator}second.db');
    await db2.upsertSong(Song(path: s.path, size: 3));
    final r = await importBundleFrom(db2, file);
    expect((r.songs, r.mixes, r.plays), (1, 1, 1));
    final got = await db2.song(s.path);
    expect((got!.rating, got.fav), (3, true));
    expect(got.userTags, ['chill']);
    final again = await importBundleFrom(db2, file);
    expect((again.mixes, again.plays), (0, 0));
    await db2.close();
  });

  test('shared plays log imports beats-me rows only once', () async {
    final s = await addSong('s.mp3');
    final dir = Directory('${tmp.path}${Platform.pathSeparator}share')..createSync();
    await playsLog(dir).writeAsString(
        '{"path":${_q(s.path)},"at":5,"listened":120,"done":true,"app":"beats-me"}\n'
        '{"path":${_q(s.path)},"at":6,"listened":1,"done":false,"app":"analyze-this"}\n');
    expect(await importSharedPlays(db, dir: dir), 1);
    expect(await importSharedPlays(db, dir: dir), 0);
  });
}

String _q(String s) => '"${s.replaceAll(r'\', r'\\')}"';
