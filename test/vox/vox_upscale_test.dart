import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/vox/vox_upscale.dart';

void main() {
  group('tiles', () {
    for (final size in const [(1, 1), (160, 160), (161, 300), (512, 384)]) {
      test('cover ${size.$1}x${size.$2} once, with context', () {
        final (w, h) = size;
        final hits = List.filled(w * h, 0);
        for (final t in voxUpscaleTiles(w, h)) {
          expect(t.rx, greaterThanOrEqualTo(0));
          expect(t.ry, greaterThanOrEqualTo(0));
          expect(t.rx + t.rw, lessThanOrEqualTo(w));
          expect(t.ry + t.rh, lessThanOrEqualTo(h));
          // The region holds the tile plus the padding the image allows.
          expect(
            t.rx,
            t.x - voxUpscaleTilePad < 0 ? 0 : t.x - voxUpscaleTilePad,
          );
          expect(t.rx <= t.x && t.x + t.w <= t.rx + t.rw, isTrue);
          expect(t.ry <= t.y && t.y + t.h <= t.ry + t.rh, isTrue);
          for (var y = t.y; y < t.y + t.h; y++) {
            for (var x = t.x; x < t.x + t.w; x++) {
              hits[y * w + x]++;
            }
          }
        }
        expect(hits.every((n) => n == 1), isTrue);
      });
    }
  });

  test('input and write round-trip through a stand-in 4x model', () {
    // A stand-in for the network: nearest-neighbour 4x of its input. Run tile
    // by tile, the stitched output must be the nearest 4x of the whole image.
    const w = 200, h = 170, s = 4;
    final rgba = Uint8List(w * h * 4);
    for (var i = 0; i < w * h; i++) {
      rgba[i * 4] = (i * 7) & 0xFF;
      rgba[i * 4 + 1] = (i * 13) & 0xFF;
      rgba[i * 4 + 2] = (i * 29) & 0xFF;
      rgba[i * 4 + 3] = 255;
    }
    final out = Uint8List(w * s * h * s * 4);
    for (final t in voxUpscaleTiles(w, h)) {
      final x = voxUpscaleInput(rgba, w, t);
      final plane = t.rw * t.rh, ow = t.rw * s, oh = t.rh * s;
      final y = Float32List(3 * ow * oh);
      for (var c = 0; c < 3; c++) {
        for (var yy = 0; yy < oh; yy++) {
          for (var xx = 0; xx < ow; xx++) {
            y[c * ow * oh + yy * ow + xx] =
                x[c * plane + (yy ~/ s) * t.rw + xx ~/ s];
          }
        }
      }
      voxUpscaleWrite(y, t, out, w);
    }
    for (var yy = 0; yy < h * s; yy++) {
      for (var xx = 0; xx < w * s; xx++) {
        final src = ((yy ~/ s) * w + xx ~/ s) * 4;
        final dst = (yy * w * s + xx) * 4;
        expect(out.sublist(dst, dst + 4), rgba.sublist(src, src + 4));
      }
    }
  });

  test('only small photos are enhanced', () {
    expect(VoxUpscaler.canEnhance(512, 384), isTrue);
    expect(VoxUpscaler.canEnhance(513, 100), isFalse);
    expect(VoxUpscaler.canEnhance(0, 10), isFalse);
  });
}
