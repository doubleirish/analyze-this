import 'dart:typed_data';

import 'package:shared_core/shared_core.dart';
import 'package:flutter_test/flutter_test.dart';

WaveformData _wave(List<int> peaks, double duration) => WaveformData(
    duration: duration,
    fileSize: 1,
    peaks: Uint8List.fromList(peaks),
    env: Uint8List(0),
    envFps: 10);

void main() {
  test('leadingSilence finds the first audible bucket', () {
    expect(leadingSilence(_wave([0, 1, 2, 0, 90, 120, 80, 70, 60, 50], 10)), 4);
  });

  test('leadingSilence is 0 for audible starts and fully silent files', () {
    expect(leadingSilence(_wave([90, 80, 70], 3)), 0);
    expect(leadingSilence(_wave([0, 0, 0], 3)), 0);
  });
}
