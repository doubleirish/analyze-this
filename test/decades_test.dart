import 'package:analyze_this/services/db.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late MusicDb db;

  setUp(() async => db = await MusicDb.open(':memory:'));
  tearDown(() async => db.close());

  Future<void> add(String name, int? year) =>
      db.upsertSong(Song(path: 'C:\\m\\$name.mp3', title: name, artist: 'A', year: year));

  test('decades are distinct, sorted and include the 2020s', () async {
    await add('a', 2021);
    await add('b', 1985);
    await add('c', 1989);
    await add('d', 2024);
    await add('e', 1999);
    expect(await db.decades(), [1980, 1990, 2020]);
  });

  test('decades ignore missing and implausible years', () async {
    expect(await db.decades(), isEmpty);
    await add('none', null);
    await add('zero', 0);
    await add('old', 1066);
    await add('future', DateTime.now().year + 5);
    expect(await db.decades(), isEmpty);
    await add('ok', 1977);
    expect(await db.decades(), [1970]);
  });

  test('decades follow year overrides like search does', () async {
    await add('a', 1985);
    await add('b', 1992);
    await db.setOverrides(['C:\\m\\a.mp3'], year: 2003);
    expect(await db.decades(), [1990, 2000]);
    final hits = await db.search(const SongQuery(decade: 2000));
    expect(hits.map((s) => s.title), ['a']);
  });
}
