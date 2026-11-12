import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/vox/video_codec.dart';
import 'package:meshcore_open/vox/video_prep.dart';
import 'package:meshcore_open/vox/vox_interp.dart';

/// A textured scene seen through a [w] x [h] window that moves by [offsets]
/// (one per frame), with grain of strength [noise].
VoxVideoFrames _scene(
  int w,
  int h,
  List<(int, int)> offsets, {
  double noise = 0,
  int seed = 1,
}) {
  final rng = Random(seed);
  const sw = 400, sh = 300;
  final scene = Uint8List(sw * sh);
  for (var y = 0; y < sh; y++) {
    for (var x = 0; x < sw; x++) {
      scene[y * sw + x] =
          (128 + 60 * sin(x / 7) * cos(y / 9) + 40 * sin((x + y) / 23))
              .round()
              .clamp(0, 255);
    }
  }
  final rgb = Uint8List(offsets.length * w * h * 3);
  for (var f = 0; f < offsets.length; f++) {
    final (ox, oy) = offsets[f];
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final v = scene[(y + oy + 60) * sw + x + ox + 60];
        for (var c = 0; c < 3; c++) {
          final g = noise == 0 ? 0.0 : (rng.nextDouble() * 2 - 1) * noise * 1.7;
          rgb[((f * h + y) * w + x) * 3 + c] = (v + g).round().clamp(0, 255);
        }
      }
    }
  }
  return VoxVideoFrames(w, h, 12, rgb);
}

double _meanAbsDiff(VoxVideoFrames a, VoxVideoFrames b) {
  var s = 0.0;
  for (var i = 0; i < a.rgb.length; i++) {
    s += (a.rgb[i] - b.rgb[i]).abs();
  }
  return s / a.rgb.length;
}

void main() {
  group('steady', () {
    test('measures whole-frame movement', () {
      final f = _scene(128, 96, [(0, 0), (6, 0), (6, 4), (2, 4)]);
      final m = voxClipMotion(f);
      expect(m, hasLength(4));
      // The window moved right 6: content moved left 6.
      expect(m[1], (-6, 0));
      expect(m[2], (0, -4));
      expect(m[3], (4, 0));
    });

    test('a smooth pan is left alone', () {
      final f = _scene(128, 96, [for (var i = 0; i < 24; i++) (i * 2, 0)]);
      final (out, crop) = voxSteady(f);
      expect(crop, 0);
      expect(identical(out, f), isTrue);
    });

    test('shake is taken out', () {
      final rng = Random(3);
      final shaky = [
        for (var i = 0; i < 36; i++) (rng.nextInt(9) - 4 + 20, rng.nextInt(9) - 4 + 20),
      ];
      final f = _scene(128, 96, shaky);
      final (out, crop) = voxSteady(f);
      expect(crop, greaterThan(0));
      expect(crop, lessThanOrEqualTo((128 * voxSteadyMaxCrop).floor()));
      expect(out.count, f.count);
      expect(out.width, f.width);
      // Frame to frame, the steadied clip changes much less.
      double jitter(VoxVideoFrames v) {
        var s = 0.0;
        for (var i = 1; i < v.count; i++) {
          final a = v.frame(i - 1).rgb, b = v.frame(i).rgb;
          for (var p = 0; p < a.length; p += 3) {
            s += (a[p] - b[p]).abs();
          }
        }
        return s;
      }

      expect(jitter(out), lessThan(jitter(f) * 0.6));
    });
  });

  group('clean', () {
    test('averages grain out of a still scene', () {
      final offsets = [for (var i = 0; i < 12; i++) (0, 0)];
      final clean = _scene(96, 72, offsets);
      final noisy = _scene(96, 72, offsets, noise: 8);
      final (out, grain) = voxClean(noisy);
      expect(grain, greaterThan(3));
      expect(_meanAbsDiff(out, clean), lessThan(_meanAbsDiff(noisy, clean) * 0.7));
    });

    test('keeps a moving scene its own', () {
      final f = _scene(96, 72, [for (var i = 0; i < 6; i++) (i * 10, 0)]);
      final (out, _) = voxClean(f);
      expect(_meanAbsDiff(out, f), lessThan(4));
    });

    test('prepare does both and reports', () {
      final f = _scene(96, 72, [for (var i = 0; i < 12; i++) (0, 0)], noise: 6);
      final (out, report) = voxPrepareClip(f);
      expect(out.count, f.count);
      expect(report.steadyCrop, 0);
      expect(report.grain, greaterThan(2));
    });
  });

  group('smooth motion', () {
    test('aims for about 24 fps', () {
      expect(voxInterpMultiple(12, 120), 2);
      expect(voxInterpMultiple(6, 60), 4);
      expect(voxInterpMultiple(24, 60), 1);
    });

    test('stays within the frame cap', () {
      expect(voxInterpMultiple(12, 180, maxFrames: 240), 1);
      expect(voxInterpMultiple(6, 60, maxFrames: 240), 4);
      expect(voxInterpMultiple(6, 90, maxFrames: 240), 2);
    });

    test('pads to 64 with repeated edges, and crops back', () {
      final f = _scene(40, 30, [(0, 0)]);
      final input = voxInterpInput(f, 0, 64, 64);
      expect(input.length, 3 * 64 * 64);
      // Padding repeats the last column.
      expect(input[63], input[39]);
      final out = Uint8List(f.frameBytes);
      voxInterpWrite(input.toList(), 64, 64, 40, 30, out, 0);
      for (var i = 0; i < out.length; i++) {
        expect((out[i] - f.rgb[i]).abs(), lessThanOrEqualTo(1));
      }
    });
  });
}
