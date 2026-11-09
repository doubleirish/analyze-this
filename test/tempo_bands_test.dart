import 'package:analyze_this/screens/tempo_profile.dart';
import 'package:analyze_this/services/db.dart';
import 'package:analyze_this/services/planner.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('foldToBand', () {
    test('keeps a BPM already in the band', () {
      expect(foldToBand(85, 80, 90), 85);
      expect(bpmInBand(85, 80, 90), isTrue);
    });

    test('halves a fast song into a slow band', () {
      expect(foldToBand(130, 60, 70), 65);
      expect(bpmInBand(130, 60, 70), isTrue);
    });

    test('doubles a slow song into a fast band', () {
      expect(foldToBand(48, 90, 105), 96);
      expect(bpmInBand(48, 90, 105), isTrue);
    });

    test('never in band picks the nearest fold', () {
      // 120: as is 15 above, half 30 below -> as is.
      expect(foldToBand(120, 90, 105), 120);
      expect(bpmInBand(120, 90, 105), isFalse);
      // 150: as is 45 above, half 15 below -> half.
      expect(foldToBand(150, 90, 105), 75);
      expect(bpmInBand(150, 90, 105), isFalse);
      // 40: as is 20 below, double 20 above -> as is wins ties.
      expect(foldToBand(40, 60, 60), 40);
    });

    test('band edges count as in band', () {
      expect(bpmInBand(80, 80, 90), isTrue);
      expect(bpmInBand(90, 80, 90), isTrue);
      expect(bpmInBand(180, 80, 90), isTrue);
      expect(foldToBand(180, 80, 90), 90);
      expect(bpmInBand(40, 80, 90), isTrue);
      expect(foldToBand(40, 80, 90), 80);
      expect(bpmInBand(79.9, 80, 90), isFalse);
    });
  });

  group('energy graph helpers', () {
    test('edges are proportional to play length, unknown = average', () {
      final e = profileEdges([
        Song(path: 'a', duration: 100),
        Song(path: 'b', duration: 300),
        Song(path: 'c'),
      ], 600);
      expect(e, [0, 100, 400, 600]);
      expect(profileIndexAt(e, 50), 0);
      expect(profileIndexAt(e, 100), 1);
      expect(profileIndexAt(e, 9999), 2);
    });

    test('drops stay inside the dragged song\'s activity', () {
      final keys = <int?>[1, 1, 2, 2, 2, 3];
      expect(dropWithinPart(keys, 2, 0), isNull); // clamped back to itself
      expect(dropWithinPart(keys, 2, 5), 4);
      expect(dropWithinPart(keys, 4, 3), 3);
      expect(dropWithinPart(keys, 0, 1), 1);
      expect(dropWithinPart(keys, 9, 1), isNull);
    });
  });
}
