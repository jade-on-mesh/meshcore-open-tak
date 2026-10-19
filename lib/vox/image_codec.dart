// MeshCore Open TAK - image messages: fit a photo into a byte budget.
//
// Pipeline (all on the sending phone):
//   1. Scale the photo to at most [voxImageWorkSide] px; that is the
//      reference everything is scored against.
//   2. Optional focus: detectors mark text and faces; everything else is
//      softened slightly so AV1 spends its bytes on the marked regions. Every
//      pixel the receiver sees still comes from the photo.
//   3. Search sizes and quantizers for the encode that scores best within
//      the budget, then re-encode the winner at a slower, better setting.
//   4. Decode the result: that exact picture is the preview, so the sender
//      sees what the receiver will see.
//
// Pure Dart except for the encoder/decoder, which is injected so the search
// can be tested without the native library.

import 'dart:math';
import 'dart:typed_data';

import 'av1_ffi.dart';

/// Bytes of one full-length voice message (20 s of Mimi: 250 frames x 11 B).
const int voxImageBaseBudget = 2750;

/// Longest side of the reference picture.
const int voxImageWorkSide = 768;

/// Encoder speed meaning "fast all-intra trial" (see vox_av1.c).
const int voxAv1TrialSpeed = 10;

/// First payload byte: format version.
const int voxImagePayloadVersion = 1;

/// How much airtime to spend, in voice messages.
enum VoxImageDetail {
  standard(1, 'Standard'),
  more(2, 'More detail'),

  /// Four times the bytes: about twice the resolution. Meant for a fast
  /// MediaMesh preset, where 71 packets take ~11 s of air at 250 kHz.
  sharp(4, 'Sharp');

  const VoxImageDetail(this.multiple, this.label);
  final int multiple;
  final String label;
  int get budget => voxImageBaseBudget * multiple;

  /// Box-blur radius and passes for the background when text or faces are
  /// sharpened. The blur caps the background's detail whatever the budget,
  /// so it eases off as the budget grows: at Sharp the background keeps all
  /// its detail and the text is already crisp.
  (int radius, int passes)? get backgroundSoften => switch (this) {
    standard => (2, 3),
    more => (1, 1),
    sharp => null,
  };
}

/// A rectangle in reference-picture pixels.
class VoxRect {
  final double left, top, width, height;
  const VoxRect(this.left, this.top, this.width, this.height);
  double get right => left + width;
  double get bottom => top + height;
  VoxRect inflate(double d) =>
      VoxRect(left - d, top - d, width + 2 * d, height + 2 * d);
}

/// What the detectors found, in reference-picture pixels.
class VoxFocusRegions {
  final List<VoxRect> text;
  final List<VoxRect> faces;
  const VoxFocusRegions({this.text = const [], this.faces = const []});
  static const none = VoxFocusRegions();
  bool get isEmpty => text.isEmpty && faces.isEmpty;
  List<VoxRect> get all => [...text, ...faces];
}

class VoxEncodedImage {
  /// What goes on air: version byte + AV1 OBUs.
  final Uint8List payload;

  /// The picture the receiver will decode (coded size).
  final VoxRgbImage preview;

  /// Source aspect ratio (width / height).
  final double aspect;
  final VoxImageDetail detail;
  final bool focused;

  /// Luma PSNR inside detected text, if any (higher is sharper).
  final double? textPsnr;

  const VoxEncodedImage({
    required this.payload,
    required this.preview,
    required this.aspect,
    required this.detail,
    required this.focused,
    this.textPsnr,
  });

  /// Small text is likely unreadable at this detail level.
  bool get smallTextAtRisk => textPsnr != null && textPsnr! < 23;
}

typedef VoxAv1Encode = Uint8List? Function(VoxRgbImage img, int q, int speed);
typedef VoxAv1Decode = VoxRgbImage? Function(Uint8List obus);

// ----------------------------------------------------------- pixel helpers

/// Area-averaging downscale (or bilinear upscale) to [w] x [h].
VoxRgbImage voxResize(VoxRgbImage src, int w, int h) {
  if (w == src.width && h == src.height) return src;
  final out = Uint8List(w * h * 3);
  final sx = src.width / w, sy = src.height / h;
  if (sx >= 1 && sy >= 1) {
    for (var y = 0; y < h; y++) {
      final y0 = (y * sy).floor(), y1 = max(y0 + 1, ((y + 1) * sy).floor());
      for (var x = 0; x < w; x++) {
        final x0 = (x * sx).floor(), x1 = max(x0 + 1, ((x + 1) * sx).floor());
        var r = 0, g = 0, b = 0, n = 0;
        for (var yy = y0; yy < y1 && yy < src.height; yy++) {
          var i = (yy * src.width + x0) * 3;
          for (var xx = x0; xx < x1 && xx < src.width; xx++, i += 3) {
            r += src.rgb[i];
            g += src.rgb[i + 1];
            b += src.rgb[i + 2];
            n++;
          }
        }
        final o = (y * w + x) * 3;
        out[o] = r ~/ n;
        out[o + 1] = g ~/ n;
        out[o + 2] = b ~/ n;
      }
    }
    return VoxRgbImage(w, h, out);
  }
  for (var y = 0; y < h; y++) {
    final fy = ((y + 0.5) * sy - 0.5).clamp(0, src.height - 1.0);
    final y0 = fy.floor(), y1 = min(y0 + 1, src.height - 1);
    final wy = fy - y0;
    for (var x = 0; x < w; x++) {
      final fx = ((x + 0.5) * sx - 0.5).clamp(0, src.width - 1.0);
      final x0 = fx.floor(), x1 = min(x0 + 1, src.width - 1);
      final wx = fx - x0;
      final o = (y * w + x) * 3;
      for (var c = 0; c < 3; c++) {
        final a = src.rgb[(y0 * src.width + x0) * 3 + c];
        final b = src.rgb[(y0 * src.width + x1) * 3 + c];
        final d = src.rgb[(y1 * src.width + x0) * 3 + c];
        final e = src.rgb[(y1 * src.width + x1) * 3 + c];
        out[o + c] =
            ((a * (1 - wx) + b * wx) * (1 - wy) + (d * (1 - wx) + e * wx) * wy)
                .round();
      }
    }
  }
  return VoxRgbImage(w, h, out);
}

/// Fits [w] x [h] inside a square of [side], keeping the aspect ratio.
(int, int) voxFitSize(int w, int h, int side) {
  final s = min(1.0, side / max(w, h));
  return (max(8, (w * s).round()), max(8, (h * s).round()));
}

/// Separable box blur, [passes] times (3 passes ~ Gaussian).
Float32List _boxBlurPlane(Float32List p, int w, int h, int r, int passes) {
  var a = p, b = Float32List(p.length);
  for (var pass = 0; pass < passes; pass++) {
    for (var y = 0; y < h; y++) {
      var sum = 0.0;
      final row = y * w;
      for (var x = -r; x <= r; x++) {
        sum += a[row + x.clamp(0, w - 1)];
      }
      for (var x = 0; x < w; x++) {
        b[row + x] = sum / (2 * r + 1);
        sum +=
            a[row + (x + r + 1).clamp(0, w - 1)] -
            a[row + (x - r).clamp(0, w - 1)];
      }
    }
    for (var x = 0; x < w; x++) {
      var sum = 0.0;
      for (var y = -r; y <= r; y++) {
        sum += b[y.clamp(0, h - 1) * w + x];
      }
      for (var y = 0; y < h; y++) {
        a[y * w + x] = sum / (2 * r + 1);
        sum +=
            b[(y + r + 1).clamp(0, h - 1) * w + x] -
            b[(y - r).clamp(0, h - 1) * w + x];
      }
    }
  }
  return a;
}

/// 0..1 mask: 1 inside [rects], fading to 0 over about [feather] px
/// outside them. The inside always stays exactly 1, however small the rect.
Float32List voxFocusMask(int w, int h, List<VoxRect> rects, {int feather = 6}) {
  Float32List paint(double grow) {
    final m = Float32List(w * h);
    for (final r0 in rects) {
      final r = r0.inflate(grow);
      final x0 = r.left.floor().clamp(0, w), x1 = r.right.ceil().clamp(0, w);
      final y0 = r.top.floor().clamp(0, h), y1 = r.bottom.ceil().clamp(0, h);
      for (var y = y0; y < y1; y++) {
        m.fillRange(y * w + x0, y * w + x1, 1);
      }
    }
    return m;
  }

  final hard = paint(0);
  if (feather <= 0) return hard;
  final soft = _boxBlurPlane(paint(feather / 2), w, h, max(1, feather ~/ 2), 3);
  for (var i = 0; i < hard.length; i++) {
    if (hard[i] > soft[i]) soft[i] = hard[i];
  }
  return soft;
}

/// Softens everything outside [mask] (blur radius ~[radius] px).
VoxRgbImage voxSoftenOutside(
  VoxRgbImage img,
  Float32List mask, {
  int radius = 2,
  int passes = 3,
}) {
  final w = img.width, h = img.height, n = w * h;
  final out = Uint8List(n * 3);
  for (var c = 0; c < 3; c++) {
    final p = Float32List(n);
    for (var i = 0; i < n; i++) {
      p[i] = img.rgb[i * 3 + c].toDouble();
    }
    final blurred = _boxBlurPlane(
      Float32List.fromList(p),
      w,
      h,
      radius,
      passes,
    );
    for (var i = 0; i < n; i++) {
      final k = mask[i];
      out[i * 3 + c] = (p[i] * k + blurred[i] * (1 - k)).round().clamp(0, 255);
    }
  }
  return VoxRgbImage(w, h, out);
}

double _luma(Uint8List rgb, int i) =>
    0.299 * rgb[i] + 0.587 * rgb[i + 1] + 0.114 * rgb[i + 2];

/// Luma PSNR of [b] against [a] (same size), optionally weighted by [mask].
double voxPsnr(VoxRgbImage a, VoxRgbImage b, [Float32List? mask]) {
  var se = 0.0, wsum = 0.0;
  for (var i = 0, p = 0; i < a.width * a.height; i++, p += 3) {
    final wgt = mask == null ? 1.0 : mask[i];
    if (wgt <= 0) continue;
    final d = _luma(a.rgb, p) - _luma(b.rgb, p);
    se += wgt * d * d;
    wsum += wgt;
  }
  if (wsum == 0) return 0;
  final mse = se / wsum;
  return mse <= 1e-9 ? 99 : 10 * log(255 * 255 / mse) / ln10;
}

// --------------------------------------------------------------- the search

/// Candidate long sides for the coded picture.
const List<int> voxImageSides = [
  128,
  160,
  192,
  224,
  256,
  288,
  320,
  352,
  384,
  448,
  512,
  576,
  640,
  768,
];

class _Fit {
  final int side, q, w, h;
  final double score;
  _Fit(this.side, this.q, this.w, this.h, this.score);
}

/// Encodes [ref] (the reference picture, at most [voxImageWorkSide]) to fit
/// [detail]'s budget. [focus] regions are in [ref] pixels.
VoxEncodedImage voxEncodeImage({
  required VoxRgbImage ref,
  required VoxImageDetail detail,
  required VoxAv1Encode encode,
  required VoxAv1Decode decode,
  VoxFocusRegions focus = VoxFocusRegions.none,
  bool useFocus = true,
}) {
  final budget = detail.budget - 1; // minus the version byte
  final w = ref.width, h = ref.height;
  final focused = useFocus && !focus.isEmpty;
  final mask = focused
      ? voxFocusMask(w, h, [for (final r in focus.all) r.inflate(3)])
      : null;
  final textMask = focus.text.isEmpty
      ? null
      : voxFocusMask(w, h, focus.text, feather: 0);
  final soften = detail.backgroundSoften;
  final source = focused && soften != null
      ? voxSoftenOutside(ref, mask!, radius: soften.$1, passes: soften.$2)
      : ref;

  double scoreOf(VoxRgbImage decoded) {
    final up = voxResize(decoded, w, h);
    final whole = voxPsnr(ref, up);
    return mask == null ? whole : voxPsnr(ref, up, mask) + 0.25 * whole;
  }

  // Smallest quantizer (best quality) that fits, by bisection. Speed 10 is
  // the native side's fast all-intra trial mode.
  (int, Uint8List)? fitQ(VoxRgbImage img, {int speed = voxAv1TrialSpeed}) {
    var lo = 0, hi = 63;
    (int, Uint8List)? best;
    while (lo <= hi) {
      final q = (lo + hi) >> 1;
      final data = encode(img, q, speed);
      if (data != null && data.length <= budget) {
        best = (q, data);
        hi = q - 1;
      } else {
        lo = q + 1;
      }
    }
    return best;
  }

  _Fit? best;
  var worse = 0;
  final longSide = max(w, h);
  for (final side in voxImageSides) {
    if (side > longSide && best != null) break;
    final (cw, ch) = voxFitSize(w, h, side);
    final scaled = voxResize(source, cw, ch);
    final fit = fitQ(scaled);
    if (fit == null) continue;
    final dec = decode(fit.$2);
    if (dec == null) continue;
    final s = scoreOf(dec);
    if (best == null || s > best.score) {
      best = _Fit(side, fit.$1, cw, ch, s);
      worse = 0;
    } else if (++worse >= 2) {
      break; // past the peak
    }
    if (side >= longSide) break;
  }
  if (best == null) {
    throw StateError('Image does not fit in ${detail.budget} bytes');
  }

  // Trials picked the size; now the efficient encoder finds the quantizer,
  // then a slower final pass (nudging q up if that grew past the budget).
  final scaled = voxResize(source, best.w, best.h);
  final good = fitQ(scaled, speed: 6);
  Uint8List? data;
  if (good != null) {
    for (var q = good.$1; q <= 63; q++) {
      final d = encode(scaled, q, 4);
      if (d != null && d.length <= budget) {
        data = d;
        break;
      }
    }
    data ??= good.$2;
  }
  data ??= fitQ(scaled)?.$2;
  if (data == null) {
    throw StateError('Image does not fit in ${detail.budget} bytes');
  }
  final preview = decode(data)!;
  double? textPsnr;
  if (textMask != null) {
    textPsnr = voxPsnr(ref, voxResize(preview, w, h), textMask);
  }
  final payload = Uint8List(data.length + 1)
    ..[0] = voxImagePayloadVersion
    ..setRange(1, data.length + 1, data);
  return VoxEncodedImage(
    payload: payload,
    preview: preview,
    aspect: w / h,
    detail: detail,
    focused: focused,
    textPsnr: textPsnr,
  );
}

/// Decodes a received payload. Null if it isn't a picture this build reads.
VoxRgbImage? voxDecodeImagePayload(Uint8List payload, VoxAv1Decode decode) {
  if (payload.length < 2 || payload[0] != voxImagePayloadVersion) return null;
  return decode(Uint8List.sublistView(payload, 1));
}

/// Aspect ratio as carried in the VI1 envelope (width * 100 / height).
int voxAspectCode(double aspect) => (aspect * 100).round().clamp(20, 600);
