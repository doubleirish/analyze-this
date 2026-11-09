import 'package:analyze_this/services/db.dart';
import 'package:analyze_this/services/m3u_import.dart';
import 'package:analyze_this/services/mix_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late MusicDb db;

  Future<void> add(String path, {double? duration = 200}) =>
      db.upsertSong(Song(path: path, title: path.split('\\').last, artist: 'A', duration: duration));

  List<String> paths(MixController m) => [for (final s in m.mix) s.path];

  setUp(() async {
    db = await MusicDb.open(':memory:');
    await add(r'C:\Music\Exact.mp3');
    await add(r'C:\Music\Rock\Loud.mp3');
    await add(r'D:\Old\Moved.mp3', duration: 180);
    await add(r'C:\A\Twin.mp3', duration: 200);
    await add(r'C:\B\Twin.mp3', duration: 240);
  });
  tearDown(() async => db.close());

  test('parses #EXTINF length and title, skips comments', () {
    final e = parseM3uEntries('#EXTM3U\n#EXTINF:183,Band - Song\nsong.mp3\n\n# note\nhttp://x/y\n');
    expect(e.map((x) => x.line), ['song.mp3', 'http://x/y']);
    expect(e[0].duration, 183);
    expect(e[0].title, 'Band - Song');
    expect(e[1].duration, isNull);
    expect(e[1].isStream, isTrue);
  });

  test('each match level', () {
    final lib = [
      (path: r'C:\Music\Exact.mp3', duration: 200.0),
      (path: r'C:\Music\Rock\Loud.mp3', duration: 200.0),
      (path: r'D:\Old\Moved.mp3', duration: 180.0),
    ];
    final r = matchM3uEntries(
        parseM3uEntries('C:\\Music\\Exact.mp3\n'
            'c:/music/sub/../ROCK/loud.MP3\n'
            '#EXTINF:181,x\nE:\\New\\moved.mp3\n'
            '#EXTINF:190,x\nE:\\New\\Moved.mp3\n'
            'nothing.mp3\n'),
        lib);
    expect([for (final m in r) m.kind], [
      M3uMatchKind.exact,
      M3uMatchKind.normalized,
      M3uMatchKind.fileName,
      null,
      null,
    ]);
    expect(r[1].path, r'C:\Music\Rock\Loud.mp3');
    expect(r[2].path, r'D:\Old\Moved.mp3');
    expect(r[3].reason, M3uSkipReason.notFound);
    expect(r[4].reason, M3uSkipReason.notFound);
  });

  test('ambiguous file name: skipped without length, picked by length', () {
    final lib = [
      (path: r'C:\A\Twin.mp3', duration: 200.0),
      (path: r'C:\B\Twin.mp3', duration: 240.0),
    ];
    final r = matchM3uEntries(parseM3uEntries('X:\\twin.mp3\n#EXTINF:239,t\nX:\\twin.mp3\n'), lib);
    expect(r[0].reason, M3uSkipReason.ambiguous);
    expect(r[1].path, r'C:\B\Twin.mp3');
  });

  test('relative paths resolve against the playlist folder', () {
    final lib = [(path: r'C:\Music\Rock\Loud.mp3', duration: 200.0)];
    final r = matchM3uEntries(
        parseM3uEntries(r'..\Rock\Loud.mp3', baseDir: r'C:\Music\Lists'), lib);
    expect(r.single.path, r'C:\Music\Rock\Loud.mp3');
  });

  test('decodes UTF-8, falls back to Latin-1', () {
    expect(decodePlaylist([0x43, 0x61, 0x66, 0xC3, 0xA9]), 'Café');
    expect(decodePlaylist([0x43, 0x61, 0x66, 0xE9]), 'Café');
  });

  test('import replaces the mix in playlist order; undo restores it', () async {
    final m = MixController(db);
    m.addToMix((await db.song(r'C:\Music\Exact.mp3'))!);
    final before = paths(m);
    final r = await m.importPlaylist(
        '#EXTM3U\n'
        '#EXTINF:180,x\nmoved.mp3\n'
        'Rock\\Loud.mp3\n'
        'missing.mp3\n'
        'twin.mp3\n'
        'C:\\Music\\Exact.mp3\n'
        'c:\\music\\exact.mp3\n',
        baseDir: r'C:\Music',
        name: 'Imported');
    expect(paths(m), [r'D:\Old\Moved.mp3', r'C:\Music\Rock\Loud.mp3', r'C:\Music\Exact.mp3']);
    expect(m.mixPart, [null, null, null]);
    expect(m.mixName, 'Imported');
    expect(r.matched, 3);
    expect(r.total, 6);
    expect([for (final k in r.skipped) (k.line, k.reason)], [
      ('missing.mp3', M3uSkipReason.notFound),
      ('twin.mp3', M3uSkipReason.ambiguous),
      (r'c:\music\exact.mp3', M3uSkipReason.duplicate),
    ]);
    m.undo();
    expect(paths(m), before);
  });

  test('append moves songs already in the mix to the end', () async {
    final m = MixController(db);
    m.addToMix((await db.song(r'C:\Music\Exact.mp3'))!);
    m.addToMix((await db.song(r'C:\A\Twin.mp3'))!);
    final key = m.mixKey;
    await m.importPlaylist('C:\\Music\\Exact.mp3\nC:\\Music\\Rock\\Loud.mp3\n', replace: false);
    expect(paths(m), [r'C:\A\Twin.mp3', r'C:\Music\Exact.mp3', r'C:\Music\Rock\Loud.mp3']);
    expect(m.mixKey, key);
  });

  test('no match leaves the mix unchanged', () async {
    final m = MixController(db);
    final r = await m.importPlaylist('nope.mp3\n');
    expect(r.matched, 0);
    expect(m.canUndo, isFalse);
  });
}
