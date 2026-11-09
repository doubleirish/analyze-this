import 'dart:typed_data';

import 'package:analyze_this/services/album_health.dart';
import 'package:shared_core/shared_core.dart';
import 'package:analyze_this/services/db.dart';
import 'package:analyze_this/services/discography.dart';
import 'package:flutter_test/flutter_test.dart';

Song song(int n, {String? title, int? total, int? disc, int? discTotal, double? dur, int? size, String dir = '/m/A/Album'}) =>
    Song(
      path: '$dir/$n.mp3',
      title: title ?? 'Song $n',
      artist: 'A',
      album: 'Album',
      trackNo: n,
      trackTotal: total,
      discNo: disc,
      discTotal: discTotal,
      duration: dur ?? 200,
      size: size ?? 200 * 16000,
    );

List<String> msgs(List<AlbumHealth> r) => [for (final a in r) for (final i in a.issues) i.message];

void main() {
  test('complete album has no issues', () {
    expect(checkAlbums([for (var i = 1; i <= 5; i++) song(i, total: 5)]), isEmpty);
  });

  test('gaps and missing tail are reported', () {
    final r = checkAlbums([song(1, total: 6), song(2), song(4), song(5)]);
    expect(msgs(r).single, contains('Missing tracks 3, 6'));
  });

  test('multi-disc numbering is checked per disc, or as one run when continuous', () {
    final perDisc = [
      for (final d in [1, 2])
        for (final n in [1, 2, 3]) song(n, disc: d, discTotal: 2, title: 'd$d-$n', dir: '/m/A/Album/CD$d')
    ];
    expect(checkAlbums(perDisc), isEmpty);
    final continuous = [
      for (var n = 1; n <= 6; n++) song(n, disc: n <= 3 ? 1 : 2, title: 't$n')
    ];
    expect(checkAlbums(continuous), isEmpty);
    expect(msgs(checkAlbums([...perDisc]..removeWhere((s) => s.discNo == 2 && s.trackNo == 2))).single,
        contains('Missing track 2 on disc 2'));
  });

  test('missing disc and track-total shortfall without numbers', () {
    final r = checkAlbums([song(1, disc: 1, discTotal: 2), song(2, disc: 1)]);
    expect(msgs(r).single, contains('1 of 2 discs'));
    final unnumbered = [
      for (var i = 1; i <= 3; i++)
        Song(path: '/x/$i.mp3', title: 't$i', album: 'Z', trackTotal: 5, duration: 200, size: 3200000)
    ];
    expect(msgs(checkAlbums(unnumbered)).single, contains('3 of 5'));
  });

  test('duplicate titles and shared track numbers', () {
    final r = checkAlbums([song(1), song(2, title: 'Song 1'), song(3), song(3, title: 'Other')]);
    final m = msgs(r);
    expect(m.any((x) => x.contains('"Song 1" appears 2 times')), isTrue);
    expect(m.any((x) => x.contains('Track 3 is shared')), isTrue);
  });

  test('file checks: empty, tiny, bitrate, header mismatch', () {
    final probe = {'/m/A/Album/3.mp3': const Mp3Probe(valid: true, headerSeconds: 300)};
    final r = checkAlbums([
      song(1, size: 0),
      song(2, size: 4000, dur: 3),
      song(3),
      song(4, size: 200 * 400000),
      song(5, dur: 100, size: 12 * 1024),
    ], probes: probe);
    final m = msgs(r).join('\n');
    expect(m, contains('file is empty'));
    expect(m, contains('probably truncated'));
    expect(m, contains('header says 5:00'));
    expect(m, contains('too big for its length'));
    expect(m, contains('too small for its length'));
    expect(r.single.worst, HealthSeverity.error);
  });

  test('invalid mp3 header is an error; online count shortfall is a warning', () {
    final r = checkAlbums([for (var i = 1; i <= 3; i++) song(i)],
        probes: {'/m/A/Album/2.mp3': const Mp3Probe(valid: false)});
    expect(msgs(r).single, contains('no valid MP3 audio frames'));
    final key = groupAlbums([song(1)]).keys.single;
    final o = checkAlbums([for (var i = 1; i <= 3; i++) song(i)], onlineTracks: {key: 12});
    expect(msgs(o).single, contains('lists 12'));
    expect(o.single.worst, HealthSeverity.warn);
  });

  test('probeMp3 reads CBR and Xing headers', () {
    // MPEG1 Layer III 128 kbps 44.1 kHz stereo: frame = 417 bytes
    Uint8List frames(int n, {bool xing = false, int xingFrames = 0}) {
      final b = Uint8List(417 * n);
      for (var i = 0; i < n; i++) {
        b.setRange(i * 417, i * 417 + 4, [0xFF, 0xFB, 0x90, 0x00]);
      }
      if (xing) {
        b.setRange(4 + 32, 4 + 32 + 4, 'Xing'.codeUnits);
        b[4 + 32 + 7] = 1;
        b.buffer.asByteData().setUint32(4 + 32 + 8, xingFrames);
      }
      return b;
    }

    final cbr = probeMp3(frames(10), 128 * 125 * 10);
    expect(cbr.valid, isTrue);
    expect(cbr.kbps, 128);
    expect(cbr.headerSeconds, closeTo(10, 0.01));
    final vbr = probeMp3(frames(10, xing: true, xingFrames: 1000), 417 * 10);
    expect(vbr.headerSeconds, closeTo(1000 * 1152 / 44100, 0.01));
    expect(probeMp3(Uint8List(2000), 2000).valid, isFalse);
  });

  test('track and disc tags parse', () {
    expect(parseNofM('3/12'), (3, 12));
    expect(parseNofM('7'), (7, null));
    expect(parseNofM('0/0'), (null, null));
    expect(parseNofM('x'), (null, null));
  });

  test('Deezer track count takes the smallest matching edition', () {
    Map<String, Object?> e(String t, int n, [String a = 'A']) =>
        {'title': t, 'nb_tracks': n, 'artist': {'name': a}};
    final j = {
      'data': [e('Album (Deluxe)', 20), e('Album', 12), e('Album', 9, 'Other'), e('Different', 3)]
    };
    expect(Discography.parseTrackCount(j, 'A', 'Album'), 12);
    expect(Discography.parseTrackCount(j, 'A', 'Nope'), isNull);
  });
}
