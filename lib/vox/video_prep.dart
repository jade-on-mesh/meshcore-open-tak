// MeshCore Open TAK - cleans a picked clip up before it is encoded, so the
// bytes go to the scene rather than to hand shake and camera grain. Every
// pixel still comes from the clip: nothing here invents detail.
//
//   1. Steady: the frame-to-frame movement is measured (whole-frame shifts,
//      coarse to fine), its jitter is smoothed out of the path while slow pans
//      stay, and each frame is cropped (at most [voxSteadyMaxCrop] a side) to
//      follow the smooth path, then scaled back to size. On a shaky test clip
//      this halved the bytes at the same quality.
//   2. Clean: each pixel is averaged with the same pixel in the two frames
//      either side, weighted by how alike they are, so grain averages out
//      while anything that moves keeps its own frame.
//
// Pure Dart (runs in an isolate); tested in test/vox/video_prep_test.dart.

import 'dart:math';
import 'dart:typed_data';

import 'av1_ffi.dart';
import 'image_codec.dart';
import 'video_codec.dart';

/// Most of each side Steady may crop away.
const double voxSteadyMaxCrop = 0.06;

/// Shake smaller than this many pixels is left alone.
const double voxSteadyMinShift = 2;

/// What [voxPrepareClip] did (for the log and the sheet).
class VoxPrepReport {
  /// Pixels cropped from each side to steady the clip (0: it was steady).
  final int steadyCrop;

  /// The grain's estimated strength (luma levels, 0..255).
  final double grain;
  const VoxPrepReport(this.steadyCrop, this.grain);
}

/// [frames] steadied and cleaned up.
(VoxVideoFrames, VoxPrepReport) voxPrepareClip(VoxVideoFrames frames) {
  if (frames.count < 2) return (frames, const VoxPrepReport(0, 0));
  final (steady, crop) = voxSteady(frames);
  final (clean, grain) = voxClean(steady);
  return (clean, VoxPrepReport(crop, grain));
}

Float32List _luma(Uint8List rgb, int n, [int offset = 0]) {
  final y = Float32List(n);
  for (var i = 0; i < n; i++) {
    final p = offset + i * 3;
    y[i] = 0.299 * rgb[p] + 0.587 * rgb[p + 1] + 0.114 * rgb[p + 2];
  }
  return y;
}

(Float32List, int, int) _half(Float32List y, int w, int h) {
  final hw = w ~/ 2, hh = h ~/ 2;
  final out = Float32List(hw * hh);
  for (var yy = 0; yy < hh; yy++) {
    for (var xx = 0; xx < hw; xx++) {
      final i = yy * 2 * w + xx * 2;
      out[yy * hw + xx] = 0.25 * (y[i] + y[i + 1] + y[i + w] + y[i + w + 1]);
    }
  }
  return (out, hw, hh);
}

/// The shift (dx, dy) that best lines [b] up with [a] (content at (x, y) in
/// [a] is at (x + dx, y + dy) in [b]), searched within [r] of (cx, cy), by the
/// mean absolute difference over the middle of the frame (every other pixel).
(int, int) voxBestShift(
  Float32List a,
  Float32List b,
  int w,
  int h, {
  int cx = 0,
  int cy = 0,
  required int r,
}) {
  final m = r + max(cx.abs(), cy.abs()) + 1;
  var best = double.infinity;
  var bx = cx, by = cy;
  for (var dy = cy - r; dy <= cy + r; dy++) {
    for (var dx = cx - r; dx <= cx + r; dx++) {
      final y0 = max(0, -dy) + m ~/ 2, y1 = min(h, h - dy) - m ~/ 2;
      final x0 = max(0, -dx) + m ~/ 2, x1 = min(w, w - dx) - m ~/ 2;
      if (y1 - y0 < 8 || x1 - x0 < 8) continue;
      var sum = 0.0;
      var n = 0;
      for (var y = y0; y < y1; y += 2) {
        final ra = y * w, rb = (y + dy) * w + dx;
        for (var x = x0; x < x1; x += 2) {
          sum += (a[ra + x] - b[rb + x]).abs();
          n++;
        }
      }
      final s = sum / n;
      if (s < best) {
        best = s;
        bx = dx;
        by = dy;
      }
    }
  }
  return (bx, by);
}

/// Whole-frame movement from each frame to the next (the first is (0, 0)),
/// in pixels, to the nearest 2.
List<(int, int)> voxClipMotion(VoxVideoFrames f) {
  final n = f.width * f.height;
  final out = <(int, int)>[(0, 0)];
  (Float32List, int, int)? prev2, prev4;
  for (var i = 0; i < f.count; i++) {
    final y = _luma(f.rgb, n, i * f.frameBytes);
    final h2 = _half(y, f.width, f.height);
    final h4 = _half(h2.$1, h2.$2, h2.$3);
    if (prev2 != null && prev4 != null) {
      final (cx, cy) = voxBestShift(prev4.$1, h4.$1, h4.$2, h4.$3, r: 6);
      final (dx, dy) = voxBestShift(
        prev2.$1,
        h2.$1,
        h2.$2,
        h2.$3,
        cx: cx * 2,
        cy: cy * 2,
        r: 1,
      );
      out.add((dx * 2, dy * 2));
    }
    prev2 = h2;
    prev4 = h4;
  }
  return out;
}

/// [path] (one coordinate) smoothed: a Gaussian about half a second wide,
/// which keeps pans and takes out shake.
List<double> voxSmoothPath(List<double> path, int fps) {
  final sigma = max(1.0, fps * 0.5);
  final r = (3 * sigma).ceil();
  final g = [for (var k = -r; k <= r; k++) exp(-k * k / (2 * sigma * sigma))];
  final out = <double>[];
  for (var i = 0; i < path.length; i++) {
    var s = 0.0, wsum = 0.0;
    for (var k = -r; k <= r; k++) {
      final j = (i + k).clamp(0, path.length - 1);
      s += path[j] * g[k + r];
      wsum += g[k + r];
    }
    out.add(s / wsum);
  }
  return out;
}

/// [f] steadied, and how many pixels a side it cropped (0: left as it was).
(VoxVideoFrames, int) voxSteady(VoxVideoFrames f) {
  final motion = voxClipMotion(f);
  final px = <double>[], py = <double>[];
  var x = 0.0, y = 0.0;
  for (final (dx, dy) in motion) {
    x += dx;
    y += dy;
    px.add(x);
    py.add(y);
  }
  final sx = voxSmoothPath(px, f.fps), sy = voxSmoothPath(py, f.fps);
  final cx = [for (var i = 0; i < px.length; i++) sx[i] - px[i]];
  final cy = [for (var i = 0; i < py.length; i++) sy[i] - py[i]];
  final mx = min(
    cx.fold<double>(0, (m, v) => max(m, v.abs())).ceil(),
    (f.width * voxSteadyMaxCrop).floor(),
  );
  final my = min(
    cy.fold<double>(0, (m, v) => max(m, v.abs())).ceil(),
    (f.height * voxSteadyMaxCrop).floor(),
  );
  if (max(mx, my) < voxSteadyMinShift) return (f, 0);
  final w = f.width, h = f.height;
  final cw = w - 2 * mx, ch = h - 2 * my;
  final out = Uint8List(f.rgb.length);
  for (var i = 0; i < f.count; i++) {
    // The content moved by the path; showing the smooth path means reading
    // the source at an offset of -(smooth - path).
    final ox = (mx - cx[i].clamp(-mx, mx)).round().clamp(0, 2 * mx);
    final oy = (my - cy[i].clamp(-my, my)).round().clamp(0, 2 * my);
    final crop = Uint8List(cw * ch * 3);
    final base = i * f.frameBytes;
    for (var r = 0; r < ch; r++) {
      final s = base + ((oy + r) * w + ox) * 3;
      crop.setRange(r * cw * 3, (r + 1) * cw * 3, f.rgb, s);
    }
    final scaled = voxResize(VoxRgbImage(cw, ch, crop), w, h);
    out.setRange(base, base + f.frameBytes, scaled.rgb);
  }
  return (VoxVideoFrames(w, h, f.fps, out), max(mx, my));
}

/// [f] with its grain averaged out over neighbouring frames, and the grain's
/// estimated strength.
(VoxVideoFrames, double) voxClean(VoxVideoFrames f) {
  final w = f.width, h = f.height, n = w * h;
  final ys = [for (var i = 0; i < f.count; i++) _luma(f.rgb, n, i * f.frameBytes)];
  // Grain from how much still pixels change frame to frame (the median is
  // dominated by them): sigma ~ median|diff| / 0.6745 / sqrt 2.
  final sample = <double>[];
  for (var i = 1; i < f.count && sample.length < 20000; i++) {
    for (var p = 0; p < n; p += 7) {
      sample.add((ys[i][p] - ys[i - 1][p]).abs());
    }
  }
  sample.sort();
  final grain = sample.isEmpty
      ? 0.0
      : sample[sample.length ~/ 2] / 0.6745 / sqrt2;
  final limit = max(3.0, 2.5 * grain);
  final out = Uint8List(f.rgb.length);
  final acc = Float32List(n * 3);
  final wsum = Float32List(n);
  final diff = Float32List(n);
  final tmp = Float32List(n);
  final mean = Float32List(n);
  for (var i = 0; i < f.count; i++) {
    final base = i * f.frameBytes;
    for (var p = 0; p < n * 3; p++) {
      acc[p] = f.rgb[base + p].toDouble();
    }
    wsum.fillRange(0, n, 1);
    for (final j in [i - 2, i - 1, i + 1, i + 2]) {
      if (j < 0 || j >= f.count) continue;
      final far = (j - i).abs() == 2 ? 0.5 : 1.0;
      for (var p = 0; p < n; p++) {
        diff[p] = (ys[j][p] - ys[i][p]).abs();
      }
      // How alike, from the 3x3 mean difference: grain differs a little
      // everywhere, movement a lot in one place.
      _box3(diff, w, h, tmp, mean);
      final jb = j * f.frameBytes;
      for (var p = 0; p < n; p++) {
        final k = (1 - mean[p] / limit).clamp(0.0, 1.0) * far;
        if (k == 0) continue;
        acc[p * 3] += f.rgb[jb + p * 3] * k;
        acc[p * 3 + 1] += f.rgb[jb + p * 3 + 1] * k;
        acc[p * 3 + 2] += f.rgb[jb + p * 3 + 2] * k;
        wsum[p] += k;
      }
    }
    for (var p = 0; p < n; p++) {
      final s = wsum[p];
      out[base + p * 3] = (acc[p * 3] / s).round().clamp(0, 255);
      out[base + p * 3 + 1] = (acc[p * 3 + 1] / s).round().clamp(0, 255);
      out[base + p * 3 + 2] = (acc[p * 3 + 2] / s).round().clamp(0, 255);
    }
  }
  return (VoxVideoFrames(w, h, f.fps, out), grain);
}

/// 3x3 mean of [src] into [out] (edges repeated), through [tmp].
void _box3(Float32List src, int w, int h, Float32List tmp, Float32List out) {
  for (var y = 0; y < h; y++) {
    final r = y * w;
    for (var x = 0; x < w; x++) {
      tmp[r + x] =
          src[r + max(0, x - 1)] + src[r + x] + src[r + min(w - 1, x + 1)];
    }
  }
  for (var y = 0; y < h; y++) {
    final up = max(0, y - 1) * w, here = y * w, down = min(h - 1, y + 1) * w;
    for (var x = 0; x < w; x++) {
      out[here + x] = (tmp[up + x] + tmp[here + x] + tmp[down + x]) / 9;
    }
  }
}
