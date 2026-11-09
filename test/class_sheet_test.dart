import 'package:analyze_this/services/db.dart';
import 'package:analyze_this/services/planner.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const program = Program('Hill <Day>', [
    ProgramPart('Warm-up', 5, 85, 95, role: PartRole.warmup),
    ProgramPart('Big Hill', 4, 60, 70, role: PartRole.hillClimb),
  ]);
  final mix = [
    Song(path: 'a', title: '<script>alert(1)</script>', artist: 'A&B', duration: 120),
    Song(path: 'b', title: 'Climb', duration: 240, medianBpm: 130),
  ];
  final html = buildClassSheet('My Mix', mix,
      program: program, parts: [0, 1], date: DateTime(2026, 3, 7));

  test('header has program, date and total class time', () {
    expect(html, contains('Program: Hill &lt;Day&gt;'));
    expect(html, contains('Date: 2026-03-07'));
    expect(html, contains('Total class time: 6:00'));
  });

  test('overview has a row per part with songs and time', () {
    expect('class="ov-part"'.allMatches(html), hasLength(2));
    expect(html, contains('<td>Big Hill</td><td>Hill climb</td><td>4:00</td>'
        '<td>60–70 RPM</td><td>base 12</td><td>1</td><td>4:00</td>'));
  });

  test('patterned part songs list timed cues', () {
    expect(html, contains('<li>0:00 Flat road · 60–70 RPM'));
    expect(html, contains('Summit'));
    expect(RegExp(r'<li>\d+:\d\d ').allMatches(html).length, greaterThan(3));
    // The warm-up is a single segment, so no cue list for it.
    expect('<ul class="cues">'.allMatches(html), hasLength(1));
  });

  test('print CSS breaks between parts and keeps songs together', () {
    expect(html, contains('@media print'));
    expect(html, contains('section.part+section.part{page-break-before:always'));
    expect(html, contains('tbody.song{page-break-inside:avoid'));
    expect('<section class="part">'.allMatches(html), hasLength(2));
  });

  test('user strings are escaped', () {
    expect(html, isNot(contains('<script>')));
    expect(html, contains('&lt;script&gt;'));
    expect(html, contains('A&amp;B'));
  });
}
