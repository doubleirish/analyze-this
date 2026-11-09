import 'package:analyze_this/services/ascii_qr.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr/qr.dart';

void main() {
  test('renders a square code with a light quiet zone', () {
    final text = asciiQr('beatsme://pull?h=192.168.1.20&p=47822&t=123456&n=PC');
    final lines = text.split('\n');
    final width = lines.first.length;
    expect(lines.every((l) => l.length == width), isTrue);
    final qr = QrImage(QrCode.fromData(
        data: 'beatsme://pull?h=192.168.1.20&p=47822&t=123456&n=PC',
        errorCorrectLevel: QrErrorCorrectLevel.L));
    expect(width, qr.moduleCount + 4);
    expect(lines.length, (qr.moduleCount + 4 + 1) ~/ 2);
    expect(lines.first.replaceAll('█', ''), isEmpty);
    expect(lines.first[0], '█');
  });

  test('different data gives a different code', () {
    expect(asciiQr('a'), isNot(asciiQr('b')));
    expect(asciiQr('a'), asciiQr('a'));
  });
}
