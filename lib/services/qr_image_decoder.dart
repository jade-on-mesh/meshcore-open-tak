import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:zxing2/qrcode.dart';

/// The longest side a frame is shrunk to before decoding: plenty for a QR
/// code held up to a webcam, and quick enough to try a few times a second.
const int _maxSide = 1280;

/// The text of the first QR code in an encoded image ([bytes]: JPEG, PNG,
/// BMP, GIF or WebP), or null when there is none or the image can't be read.
/// Pure Dart (zxing2), for platforms mobile_scanner doesn't cover.
String? decodeQrImage(Uint8List bytes) {
  img.Image? image;
  try {
    image = img.decodeImage(bytes);
  } catch (_) {
    return null;
  }
  if (image == null) return null;
  return decodeQrPixels(image);
}

/// [decodeQrImage] on an already decoded image.
String? decodeQrPixels(img.Image image) {
  var frame = image;
  final longest = frame.width > frame.height ? frame.width : frame.height;
  if (longest > _maxSide) {
    frame = frame.width >= frame.height
        ? img.copyResize(frame, width: _maxSide)
        : img.copyResize(frame, height: _maxSide);
  }
  final rgba = frame.convert(numChannels: 4);
  final pixels = rgba
      .getBytes(order: img.ChannelOrder.abgr)
      .buffer
      .asInt32List();
  final source = RGBLuminanceSource(rgba.width, rgba.height, pixels);
  for (final bitmap in [
    BinaryBitmap(HybridBinarizer(source)),
    // A light code on a dark ground (a phone screen in dark mode).
    BinaryBitmap(HybridBinarizer(source.invert())),
  ]) {
    try {
      final text = QRCodeReader().decode(bitmap).text;
      if (text.isNotEmpty) return text;
    } catch (_) {
      // No code in this frame (NotFound / Checksum / Format exceptions).
    }
  }
  return null;
}

/// [decodeQrImage] off the UI thread.
Future<String?> decodeQrImageInBackground(Uint8List bytes) =>
    compute(decodeQrImage, bytes);
