// MeshCore Open TAK - find text and faces so the image encoder can spend its
// bytes there. Runs on the sending phone only; it decides where bytes go and
// never changes what a region shows.
//
// Models (bundled, see assets/vox/LICENSES.md):
//   * YuNet face detector (MIT), fixed 640x640 BGR input, 0..255.
//   * PaddleOCR PP-OCRv3 text detector (Apache-2.0), BGR input normalised
//     with ImageNet mean/std, sides multiple of 32; output is a probability
//     map that we threshold into boxes.

import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

import 'av1_ffi.dart';
import 'image_codec.dart';

class VoxFocusDetector {
  final OnnxRuntime _rt = OnnxRuntime();
  OrtSession? _face;
  OrtSession? _text;

  static const _faceAsset = 'assets/vox/face_yunet_2023mar.onnx';
  static const _textAsset = 'assets/vox/text_ppocrv3_det.onnx';

  /// Finds text and faces in [img]. Never throws: on any failure it returns
  /// what it has (possibly nothing), and the image is simply sent unfocused.
  Future<VoxFocusRegions> detect(VoxRgbImage img) async {
    var faces = <VoxRect>[];
    var text = <VoxRect>[];
    try {
      faces = await _detectFaces(img);
    } catch (e) {
      debugPrint('VOX face detection failed: $e');
    }
    try {
      text = await _detectText(img);
    } catch (e) {
      debugPrint('VOX text detection failed: $e');
    }
    return VoxFocusRegions(text: text, faces: faces);
  }

  Future<void> close() async {
    for (final s in [_face, _text]) {
      try {
        await s?.close();
      } catch (_) {}
    }
    _face = null;
    _text = null;
  }

  // -------------------------------------------------------------- faces

  Future<List<VoxRect>> _detectFaces(VoxRgbImage img) async {
    const side = 640;
    final s = side / max(img.width, img.height);
    final (w, h) = ((img.width * s).round(), (img.height * s).round());
    final scaled = voxResize(img, w, h);
    final input = Float32List(3 * side * side); // letterboxed, BGR, 0..255
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final p = (y * w + x) * 3, o = y * side + x;
        input[o] = scaled.rgb[p + 2].toDouble();
        input[side * side + o] = scaled.rgb[p + 1].toDouble();
        input[2 * side * side + o] = scaled.rgb[p].toDouble();
      }
    }
    final session = _face ??= await _rt.createSessionFromAsset(_faceAsset);
    final value = await OrtValue.fromList(input, [1, 3, side, side]);
    final outputs = <OrtValue>[];
    try {
      final res = await session.run({'input': value});
      outputs.addAll(res.values);
      Future<List<double>> f(String k) async => [
        for (final v in await res[k]!.asFlattenedList()) (v as num).toDouble(),
      ];
      final found = <(VoxRect, double)>[];
      for (final stride in const [8, 16, 32]) {
        final cls = await f('cls_$stride');
        final obj = await f('obj_$stride');
        final bbox = await f('bbox_$stride');
        final cols = side ~/ stride;
        for (var i = 0; i < cls.length; i++) {
          final score = sqrt(cls[i].clamp(0, 1) * obj[i].clamp(0, 1));
          if (score < 0.6) continue;
          final r = i ~/ cols, c = i % cols;
          final cx = (c + bbox[i * 4]) * stride;
          final cy = (r + bbox[i * 4 + 1]) * stride;
          final bw = exp(bbox[i * 4 + 2]) * stride;
          final bh = exp(bbox[i * 4 + 3]) * stride;
          found.add((
            VoxRect((cx - bw / 2) / s, (cy - bh / 2) / s, bw / s, bh / s),
            score,
          ));
        }
      }
      // Faces get a margin (hair, chin) and duplicates are merged.
      return _nms(found)
          .map(
            (r) => VoxRect(
              r.left - r.width * 0.15,
              r.top - r.height * 0.2,
              r.width * 1.3,
              r.height * 1.35,
            ),
          )
          .toList();
    } finally {
      await value.dispose();
      for (final o in outputs) {
        await o.dispose();
      }
    }
  }

  // --------------------------------------------------------------- text

  Future<List<VoxRect>> _detectText(VoxRgbImage img) async {
    const limit = 736;
    final s = min(1.0, limit / max(img.width, img.height));
    final w = max(32, ((img.width * s) / 32).round() * 32);
    final h = max(32, ((img.height * s) / 32).round() * 32);
    final scaled = voxResize(img, w, h);
    const mean = [0.485, 0.456, 0.406], std = [0.229, 0.224, 0.225];
    final input = Float32List(3 * w * h);
    for (var i = 0; i < w * h; i++) {
      // BGR channel order, as PaddleOCR feeds OpenCV images.
      for (var c = 0; c < 3; c++) {
        final v = scaled.rgb[i * 3 + (2 - c)] / 255.0;
        input[c * w * h + i] = (v - mean[c]) / std[c];
      }
    }
    final session = _text ??= await _rt.createSessionFromAsset(_textAsset);
    final value = await OrtValue.fromList(input, [1, 3, h, w]);
    final outputs = <OrtValue>[];
    try {
      final res = await session.run({'x': value});
      outputs.addAll(res.values);
      final prob = [
        for (final v in await res.values.first.asFlattenedList())
          (v as num).toDouble(),
      ];
      final boxes = voxTextBoxesFromProb(prob, w, h);
      final sx = img.width / w, sy = img.height / h;
      return [
        for (final b in boxes)
          VoxRect(b.left * sx, b.top * sy, b.width * sx, b.height * sy),
      ];
    } finally {
      await value.dispose();
      for (final o in outputs) {
        await o.dispose();
      }
    }
  }
}

/// Connected regions of a text-probability map, as padded boxes.
@visibleForTesting
List<VoxRect> voxTextBoxesFromProb(
  List<double> prob,
  int w,
  int h, {
  double thresh = 0.3,
  double boxThresh = 0.5,
}) {
  final seen = Uint8List(w * h);
  final boxes = <VoxRect>[];
  final stack = <int>[];
  for (var start = 0; start < w * h; start++) {
    if (seen[start] != 0 || prob[start] < thresh) continue;
    var x0 = w, y0 = h, x1 = -1, y1 = -1, n = 0;
    var sum = 0.0;
    stack.add(start);
    seen[start] = 1;
    while (stack.isNotEmpty) {
      final i = stack.removeLast();
      final x = i % w, y = i ~/ w;
      x0 = min(x0, x);
      x1 = max(x1, x);
      y0 = min(y0, y);
      y1 = max(y1, y);
      sum += prob[i];
      n++;
      for (final j in [i - 1, i + 1, i - w, i + w]) {
        if (j < 0 || j >= w * h) continue;
        if ((j == i - 1 && x == 0) || (j == i + 1 && x == w - 1)) continue;
        if (seen[j] != 0 || prob[j] < thresh) continue;
        seen[j] = 1;
        stack.add(j);
      }
    }
    final bw = x1 - x0 + 1, bh = y1 - y0 + 1;
    if (n < 6 || min(bw, bh) < 3 || sum / n < boxThresh) continue;
    // The detector's map hugs the glyph cores; grow it like PaddleOCR's
    // "unclip" (ratio 1.5) so whole letters are covered.
    final grow = 1.5 * bw * bh / (2 * (bw + bh));
    boxes.add(VoxRect(x0 - grow, y0 - grow, bw + 2 * grow, bh + 2 * grow));
  }
  return boxes;
}

List<VoxRect> _nms(List<(VoxRect, double)> found) {
  found.sort((a, b) => b.$2.compareTo(a.$2));
  final keep = <VoxRect>[];
  for (final (r, _) in found) {
    var dup = false;
    for (final k in keep) {
      final ix = max(0.0, min(r.right, k.right) - max(r.left, k.left));
      final iy = max(0.0, min(r.bottom, k.bottom) - max(r.top, k.top));
      final inter = ix * iy;
      final union = r.width * r.height + k.width * k.height - inter;
      if (union > 0 && inter / union > 0.3) {
        dup = true;
        break;
      }
    }
    if (!dup) keep.add(r);
  }
  return keep;
}
