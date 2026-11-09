import 'package:qr/qr.dart';

/// Renders [data] as a QR code in text, two modules per character row using
/// half blocks, so it stays small and square in a terminal. The code is drawn
/// as dark-on-light blocks inside a light quiet zone, which phone cameras read
/// on both dark and light terminals.
String asciiQr(String data, {int quiet = 2, int errorLevel = QrErrorCorrectLevel.L}) {
  final qr = QrCode.fromData(data: data, errorCorrectLevel: errorLevel);
  final img = QrImage(qr);
  final n = img.moduleCount;
  bool dark(int r, int c) => r >= 0 && c >= 0 && r < n && c < n && img.isDark(r, c);
  final lines = <String>[];
  // Light = full block / dark = space, so the light quiet zone shows on dark terminals.
  for (var r = -quiet; r < n + quiet; r += 2) {
    final b = StringBuffer();
    for (var c = -quiet; c < n + quiet; c++) {
      final top = dark(r, c), bottom = dark(r + 1, c);
      b.write(switch ((top, bottom)) {
        (false, false) => '█',
        (true, false) => '▄',
        (false, true) => '▀',
        (true, true) => ' ',
      });
    }
    lines.add(b.toString());
  }
  return lines.join('\n');
}
