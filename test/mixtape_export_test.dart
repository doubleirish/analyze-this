import 'dart:io';

import 'package:analyze_this/services/app_state.dart';
import 'package:analyze_this/services/db.dart';
import 'package:analyze_this/services/mixtape_export.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_core/shared_core.dart';

void main() {
  late MusicDb db;
  late Directory dir;
  late AppState state;
  late MixtapeExport exporter;

  Song song(
    String name, {
    String album = 'Album',
    double? duration = 200,
    double? start,
    double? end,
    String key = 'artist|song',
    int size = 8000000,
  }) {
    final path = p.join(dir.path, name);
    File(path).writeAsBytesSync(List.filled(32, name.length));
    return Song(
      path: path,
      title: 'Song',
      artist: 'Artist',
      album: album,
      dupKey: key,
      size: size,
      duration: duration,
      trimStart: start,
      trimEnd: end,
    );
  }

  setUp(() async {
    dir = Directory('.dart_tool').createTempSync('mixtape_export_test_');
    db = await MusicDb.open(':memory:');
    state = AppState(db);
    exporter = MixtapeExport(state);
  });
  tearDown(() async {
    await db.close();
    dir.deleteSync(recursive: true);
  });

  test(
    'phone export substitutes files, not mix entries or their semantics',
    () async {
      final originalFile = song('original.wma');
      final original = Song(
        path: originalFile.path,
        dupKey: originalFile.dupKey,
        title: 'My title',
        artist: 'Artist',
        album: 'Album',
        duration: 200,
        trimStart: 10,
        trimEnd: 180,
        avgBpm: 75,
        loudness: -18,
        rating: 5,
        fav: true,
        explicitManual: true,
        userTags: ['class'],
      );
      final replacementFile = song('replacement.mp3', duration: 201);
      final replacement = Song(
        path: replacementFile.path,
        dupKey: original.dupKey,
        title: 'File title',
        artist: 'Artist',
        album: 'Album',
        duration: 201,
        avgBpm: 120,
        medianBpm: 121,
        loudness: -10,
        explicit: true,
      );
      final retained = song('retained.m4a', key: 'artist|other');
      await db.upsertSong(original);
      await db.upsertSong(replacement, segments: [const TempoSeg(0, 201, 120)]);
      await db.upsertSong(retained);
      File('${original.path}.jpg').writeAsBytesSync([1, 2]);
      File('${replacement.path}.jpg').writeAsBytesSync([3, 4]);
      await EnrichService.lyricsFile(replacement.path)
          .writeAsString('Selected lyrics');
      state.mixer.mix = [original, retained, original];
      state.mixer.mixPart = [0, null, 0];
      state.mixer.songNotes = {
        original.path: 'Original coaching note',
        replacement.path: 'Wrong note',
      };
      await state.mixer.saveMix();
      final id = state.mixer.mixDbId!;
      final paths = List<String>.of(state.mixer.paths);
      final notes = await db.mixNotes(id);
      final plan = state.mixer.planAt(0)!.toJson();

      final selection = await exporter.selections();
      expect(selection.map((e) => e.file.path), [
        replacement.path,
        retained.path,
        replacement.path,
      ]);
      expect(selection.where((e) => e.substituted), hasLength(2));
      expect(selection[1].healthyNative, isTrue);
      final sources = await exporter.sources();
      expect(sources.map((s) => s.path), [
        replacement.path,
        retained.path,
        replacement.path,
      ]);
      final source = sources.first;
      expect([source.start, source.end, source.duration], [10, 180, 201]);
      expect(source.note, 'Original coaching note');
      expect(
        [source.title, source.rating, source.fav, source.explicit],
        ['My title', 5, true, true],
      );
      expect(source.tags, ['class']);
      expect(source.art, [3, 4]);
      expect(source.lyrics, 'Selected lyrics');
      expect(source.loudness, -10);
      expect(source.bpm!['avg'], 120);
      expect(source.bpm!['segments'], [
        {'start': 0.0, 'end': 201.0, 'bpm': 120.0},
      ]);
      expect(source.step, state.mixer.partAt(0)!.name);
      for (final entry in plan.entries) {
        expect(source.plan, containsPair(entry.key, entry.value));
      }
      expect(state.mixer.mix, [original, retained, original]);
      expect(state.mixer.dirty, isFalse);
      expect(await db.mixPaths(id), paths);
      expect(await db.mixNotes(id), notes);
      expect(File(original.path).existsSync(), isTrue);

      final package = await PackageWriter(ffmpegPath: 'must-not-be-invoked')
          .write(
            id: 'selection',
            name: 'Selection',
            transport: Transport.folder,
            sources: sources,
            out: Directory(p.join(dir.path, 'package')),
            transcodeId: TranscodePreset.autoId,
          );
      expect(package.tracks.map((t) => t.transcode), everyElement(isNull));
      expect(package.tracks.map((t) => t.origPath), paths);
      await MixtapeExport.recordSent(db, package);
      expect(
        (await db.sentTrackPaths([package.tracks.first.sha256]))[package.tracks.first.sha256],
        original.path,
      );
      expect(package.tracks.first.note, 'Original coaching note');
      expect(
        File(p.join(dir.path, 'package', package.tracks.first.file))
            .readAsBytesSync(),
        File(replacement.path).readAsBytesSync(),
      );
    },
  );

  test('changing native copies preserves library identity without reusing stale bytes', () async {
    final original = song('original.wma');
    final first = song('first.mp3', size: 9000000);
    final second = song('second.mp3');
    final stamp = DateTime(2026, 1, 1);
    for (final s in [original, first, second]) {
      File(s.path).setLastModifiedSync(stamp);
      await db.upsertSong(s);
    }
    state.mixer.mix = [original];
    final writer = PackageWriter(ffmpegPath: null);
    final out = Directory(p.join(dir.path, 'swapping'));
    Future<MixtapeManifest> write() async => writer.write(
      id: 'swapping',
      name: 'Swapping',
      transport: Transport.folder,
      sources: await exporter.sources(),
      out: out,
      transcodeId: TranscodePreset.autoId,
    );

    final before = await write();
    expect(before.tracks.single.origPath, original.path);
    expect(File(p.join(out.path, before.tracks.single.file)).readAsBytesSync(),
        File(first.path).readAsBytesSync());
    final packaged = File(p.join(out.path, before.tracks.single.file));
    final packagedStamp = DateTime(2020, 1, 1);
    packaged.setLastModifiedSync(packagedStamp);
    final unchanged = await write();
    expect(unchanged.tracks.single.sha256, before.tracks.single.sha256);
    expect(packaged.lastModifiedSync(), packagedStamp);
    File(first.path).deleteSync();
    final sources = await exporter.sources();
    expect(sources.single.path, second.path);
    expect(sources.single.libraryPath, original.path);
    final after = await write();
    expect(after.tracks.single.origPath, original.path);
    expect(after.tracks.single.sha256, isNot(before.tracks.single.sha256));
    expect(File(p.join(out.path, after.tracks.single.file)).readAsBytesSync(),
        File(second.path).readAsBytesSync());
    await MixtapeExport.recordSent(db, after);
    expect(await db.sentTrackPaths([after.tracks.single.sha256]),
        {after.tracks.single.sha256: original.path});
    expect(state.mixer.mix.single, same(original));

    File(second.path).deleteSync();
    final fallback = await write();
    expect(fallback.tracks.single.origPath, original.path);
    expect(File(p.join(out.path, fallback.tracks.single.file)).readAsBytesSync(),
        File(original.path).readAsBytesSync());
  });

  test('a manually clean original cannot substitute an explicitly marked copy', () async {
    final originalFile = song('clean.wma');
    final original = Song(
      path: originalFile.path,
      dupKey: originalFile.dupKey,
      title: 'Song',
      artist: 'Artist',
      album: 'Album',
      duration: 200,
      explicit: true,
      explicitManual: false,
    );
    final candidate = song('explicit.mp3');
    await db.upsertSong(original);
    await db.upsertSong(candidate);
    await db.setExplicitMark([candidate.path], true);
    state.mixer.mix = [original];
    final selected = (await exporter.selections()).single;
    expect(selected.substituted, isFalse);
    expect(selected.file, same(original));
    final source = (await exporter.sources()).single;
    expect(source.path, original.path);
    expect(source.libraryPath, original.path);
    expect(source.explicit, isFalse);
    expect(TranscodePreset.resolve(TranscodePreset.autoId, source.path), isNotNull);
  });

  for (final reason in [
    'missing',
    'album',
    'duration',
    'unknown original duration',
    'unknown copy duration',
    'trim beyond end',
    'reversed trim',
    'negative trim',
    'damaged',
  ]) {
    test(
      '$reason copy cannot replace the original; Auto fallback remains',
      () async {
        final original = song(
          'original.wma',
          duration: reason == 'unknown original duration' ? null : 200,
          start: reason == 'negative trim'
              ? -1
              : reason == 'reversed trim'
              ? 190
              : 10,
          end: reason == 'trim beyond end' ? 200 : 180,
        );
        final candidate = song(
          'candidate.mp3',
          album: reason == 'album' ? 'Other album' : 'Album',
          duration: reason == 'unknown copy duration'
              ? null
              : reason == 'duration'
              ? 203
              : reason == 'trim beyond end'
              ? 199
              : 200,
        );
        await db.upsertSong(original);
        await db.upsertSong(candidate);
        if (reason == 'missing') File(candidate.path).deleteSync();
        if (reason == 'damaged') await db.addTag(candidate.path, corruptTag);
        state.mixer.mix = [original];
        final selection = (await exporter.selections()).single;
        expect(selection.substituted, isFalse);
        final source = (await exporter.sources()).single;
        expect(source.path, original.path);
        expect(
          TranscodePreset.resolve(TranscodePreset.autoId, source.path),
          isNotNull,
        );
      },
    );
  }

  test('a missing original uses an existing safe copy; unknown-duration same file stays', () async {
    final original = song('missing.wma');
    final replacement = song('replacement.m4a');
    final retained = song('unknown.mp3', duration: null, key: '');
    await db.upsertSong(original);
    await db.upsertSong(replacement);
    File(original.path).deleteSync();
    state.mixer.mix = [original, retained];
    final selection = await exporter.selections();
    expect(selection.first.file.path, replacement.path);
    expect(selection.last.file, same(retained));
    expect(selection.last.healthyNative, isTrue);
  });

  test('a healthy native original is retained when a copy is no better', () async {
    final original = song('original.mp3');
    final other = song('other.mp3');
    await db.upsertSong(original);
    await db.upsertSong(other);
    state.mixer.mix = [original];
    final selected = (await exporter.selections()).single;
    expect(selected.file, same(original));
    expect(selected.substituted, isFalse);
    expect(selected.healthyNative, isTrue);
  });

  test(
    'Auto without a usable copy keeps its existing no-ffmpeg warning',
    () async {
      final original = song('original.wma');
      state.mixer.mix = [original];
      final writer = PackageWriter(ffmpegPath: null);
      final package = await writer.write(
        id: 'fallback',
        name: 'Fallback',
        transport: Transport.folder,
        sources: await exporter.sources(),
        out: Directory(p.join(dir.path, 'fallback')),
        transcodeId: TranscodePreset.autoId,
      );
      expect(package.tracks.single.origPath, original.path);
      expect(writer.warnings.single, contains('may not play on Android'));
    },
  );
}
