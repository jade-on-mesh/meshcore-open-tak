import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:meshcore_open/services/qr_image_decoder.dart';
import 'package:qr/qr.dart';

/// [data] as a QR code: [scale] px a module, a 4-module quiet zone, dark on
/// light (or light on dark when [inverted]).
img.Image _qr(String data, {int scale = 6, bool inverted = false}) {
  final code = QrImage(
    QrCode.fromData(data: data, errorCorrectLevel: QrErrorCorrectLevel.M),
  );
  final n = code.moduleCount;
  final side = (n + 8) * scale;
  final dark = inverted ? img.ColorRgb8(255, 255, 255) : img.ColorRgb8(0, 0, 0);
  final light = inverted
      ? img.ColorRgb8(20, 20, 20)
      : img.ColorRgb8(255, 255, 255);
  final image = img.Image(width: side, height: side);
  img.fill(image, color: light);
  for (var y = 0; y < n; y++) {
    for (var x = 0; x < n; x++) {
      if (!code.isDark(y, x)) continue;
      img.fillRect(
        image,
        x1: (x + 4) * scale,
        y1: (y + 4) * scale,
        x2: (x + 5) * scale - 1,
        y2: (y + 5) * scale - 1,
        color: dark,
      );
    }
  }
  return image;
}

void main() {
  const channel =
      'meshcore://channel/add?name=%23icewatch&secret=0123456789abcdef0123456789abcdef';

  test('reads a QR code from a PNG', () {
    final png = img.encodePng(_qr(channel));
    expect(decodeQrImage(png), channel);
  });

  test('reads a QR code from a JPEG on a bigger, off-centre picture', () {
    final frame = img.Image(width: 1600, height: 1200);
    img.fill(frame, color: img.ColorRgb8(200, 200, 190));
    img.compositeImage(
      frame,
      _qr('hello mesh', scale: 8),
      dstX: 300,
      dstY: 250,
    );
    expect(decodeQrImage(img.encodeJpg(frame, quality: 85)), 'hello mesh');
  });

  test('reads a light code on a dark ground', () {
    final png = img.encodePng(_qr('dark mode', inverted: true));
    expect(decodeQrImage(png), 'dark mode');
  });

  test('null for no code, or not an image', () {
    final blank = img.Image(width: 200, height: 200);
    img.fill(blank, color: img.ColorRgb8(255, 255, 255));
    expect(decodeQrImage(img.encodePng(blank)), isNull);
    expect(decodeQrImage(Uint8List.fromList([1, 2, 3])), isNull);
  });
}
