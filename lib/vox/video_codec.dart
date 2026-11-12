// MeshCore Open TAK - video messages: fit a short clip and its sound into
// the same byte budgets as photos.
//
// Pipeline (all on the sending phone):
//   1. The picked clip arrives as frames at most [voxVideoSourceSide] px at
//      [voxVideoSourceFps], plus 48 kHz mono sound (video_source.dart).
//   2. The sound is coded as a voice message is (Mimi or Codec2) and comes
//      off the top of the budget.
//   3. A frame size and rate are picked so each pixel gets enough bits, the
//      frames are scaled to it, and the quantizer that fills the rest of the
//      budget is found by bisection, then re-encoded at a slower setting.
//   4. The result is decoded: that is the preview, so the sender sees what
//      the receiver will.
//
// Payload (version 3; versions 1 and 2 are photos, image_codec.dart):
//
//   [3][thumb length][thumb OBUs]           as a photo: the first two packets
//   [width:2][height:2][fps:1][frames:2]    big-endian
//   [duration ms:2][sound mode:1][sound length:2]
//   [sound][video stream]
//
// The thumbnail is the first frame as an AV1 still, so a bubble shows it as
// soon as the first two packets are in. The sound mode is the voice
// envelope's mode id (VoxVoiceMode.wireId), 255 for none. The video stream is
// vox_av1.c's packed clip.
//
// Pure Dart except for the encoder/decoder, which are injected so the search
// can be tested without the native library.

import 'dart:math';
import 'dart:typed_data';

import 'av1_ffi.dart';
import 'image_codec.dart';
import 'voice_wire.dart';

/// Payload format version of a video (photos are 1 and 2).
const int voxVideoPayloadVersion = 3;

/// Longest side the picked clip is read at (the largest frame we send).
const int voxVideoSourceSide = 256;

/// Frame rate the picked clip is read at (the fastest we send).
const int voxVideoSourceFps = 12;

/// Longest clip, whatever the budget.
const int voxVideoMaxSeconds = 15;

/// Sound mode byte for "no sound".
const int voxVideoNoSound = 255;

/// Bytes of the fixed header after the thumbnail.
const int voxVideoHeaderBytes = 12;

/// Encoder speeds: the search, and the final pass (libaom's good-quality
/// mode goes no faster than 6).
const int voxVideoTrialSpeed = 6;
const int voxVideoFinalSpeed = 4;

/// Fewest bits per pixel per frame worth sending: below this AV1 smears
/// detail away, and a smaller or slower picture looks better.
const double voxVideoMinBitsPerPixel = 0.12;

/// How much airtime to spend, in voice messages, as photos do. Max is
/// exactly Super Sharp: the most one transfer carries.
enum VoxVideoDetail {
  quick(4, 'Quick', 6),
  clear(8, 'Clear', 10),
  maximum(14, 'Max', voxVideoMaxSeconds);

  const VoxVideoDetail(this.multiple, this.label, this.maxSeconds);
  final int multiple;
  final String label;

  /// Longest clip at this level: the start of a longer one is sent.
  final int maxSeconds;
  int get budget => voxImageBaseBudget * multiple;

  /// Box-blur radius and passes for what lies outside faces and text, when
  /// there are some: as for photos, gentler as the budget grows.
  (int radius, int passes) get backgroundSoften => switch (this) {
    quick => (2, 2),
    clear => (1, 2),
    maximum => (1, 1),
  };
}

/// Frame sizes (long side) and rates to choose from, least pixels per second
/// first.
const List<(int side, int fps)> voxVideoShapes = [
  (96, 6),
  (112, 8),
  (128, 8),
  (128, 10),
  (144, 10),
  (160, 10),
  (160, 12),
  (192, 12),
  (224, 12),
  (256, 12),
];

/// Frames of [width] x [height] at [fps], back to back in [rgb].
class VoxVideoFrames {
  final int width;
  final int height;
  final int fps;
  final Uint8List rgb;
  const VoxVideoFrames(this.width, this.height, this.fps, this.rgb);

  int get frameBytes => width * height * 3;
  int get count => frameBytes == 0 ? 0 : rgb.length ~/ frameBytes;
  Duration get duration =>
      Duration(milliseconds: fps == 0 ? 0 : count * 1000 ~/ fps);

  VoxRgbImage frame(int i) => VoxRgbImage(
    width,
    height,
    Uint8List.sublistView(rgb, i * frameBytes, (i + 1) * frameBytes),
  );
}

/// A clip ready to send.
class VoxEncodedVideo {
  final Uint8List payload;

  /// What the receiver will see, decoded from [payload].
  final VoxVideoFrames preview;
  final VoxVideoDetail detail;
  final int durationMs;

  /// The sound as sent ([soundMode] null: none).
  final VoxVoiceMode? soundMode;
  final Uint8List sound;

  /// The quantizer the frames were coded at (for the log).
  final int q;

  const VoxEncodedVideo({
    required this.payload,
    required this.preview,
    required this.detail,
    required this.durationMs,
    required this.soundMode,
    required this.sound,
    required this.q,
  });

  /// The envelope's length field.
  int get seconds => max(1, (durationMs / 1000).ceil());
  double get aspect => preview.width / preview.height;
}

/// A decoded clip, ready to play.
class VoxPlayableVideo {
  final VoxVideoFrames frames;
  final int durationMs;

  /// The sound as a WAV file; null when there is none or it can't play here
  /// ([soundNote] says why).
  final Uint8List? wav;
  final String? soundNote;

  /// The clip was sent with sound.
  final bool hasSound;

  const VoxPlayableVideo({
    required this.frames,
    required this.durationMs,
    this.wav,
    this.soundNote,
    this.hasSound = false,
  });
}

/// What a received payload holds.
class VoxVideoInfo {
  final int width;
  final int height;
  final int fps;
  final int frames;
  final int durationMs;
  final VoxVoiceMode? soundMode;
  final Uint8List sound;
  final Uint8List stream;
  const VoxVideoInfo({
    required this.width,
    required this.height,
    required this.fps,
    required this.frames,
    required this.durationMs,
    required this.soundMode,
    required this.sound,
    required this.stream,
  });

  double get aspect => width / height;
}

typedef VoxAv1ClipEncode =
    Uint8List? Function(VoxVideoFrames frames, int q, int speed);
typedef VoxAv1ClipDecode =
    Uint8List? Function(Uint8List stream, int w, int h, int maxFrames);

/// The shape to code [seconds] of video in [bytes]: the most pixels per
/// second that still get [voxVideoMinBitsPerPixel], at most [maxSide] (the
/// source's long side) and [maxFps]. The smallest when none does.
(int side, int fps) voxPickVideoShape(
  int bytes,
  double seconds, {
  required double aspect,
  int maxSide = voxVideoSourceSide,
  int maxFps = voxVideoSourceFps,
}) {
  var pick = voxVideoShapes.first;
  for (final s in voxVideoShapes) {
    if (s.$1 > maxSide || s.$2 > maxFps) continue;
    final (w, h) = voxVideoSize(aspect, s.$1);
    final pixels = w * h * s.$2 * max(seconds, 0.5);
    if (bytes * 8 / pixels >= voxVideoMinBitsPerPixel) pick = s;
  }
  return pick;
}

/// Frame size for [aspect] with long side [side], both even (4:2:0).
(int, int) voxVideoSize(double aspect, int side) {
  int even(double v) => max(2, (v / 2).round() * 2);
  return aspect >= 1
      ? (even(side.toDouble()), even(side / aspect))
      : (even(side * aspect), even(side.toDouble()));
}

/// [src] scaled to [w] x [h] and resampled to [fps] (nearest frame in time).
VoxVideoFrames voxResampleFrames(VoxVideoFrames src, int w, int h, int fps) {
  final n = max(1, (src.count * fps / src.fps).floor());
  final out = Uint8List(n * w * h * 3);
  for (var i = 0; i < n; i++) {
    final j = min(src.count - 1, (i * src.fps / fps).round());
    final f = src.frame(j);
    final scaled = (f.width == w && f.height == h) ? f : voxResize(f, w, h);
    out.setRange(i * w * h * 3, (i + 1) * w * h * 3, scaled.rgb);
  }
  return VoxVideoFrames(w, h, fps, out);
}

/// [src] cut to its first [seconds].
VoxVideoFrames voxTrimFrames(VoxVideoFrames src, int seconds) {
  final n = min(src.count, seconds * src.fps);
  if (n == src.count) return src;
  return VoxVideoFrames(
    src.width,
    src.height,
    src.fps,
    Uint8List.sublistView(src.rgb, 0, n * src.frameBytes),
  );
}

/// Encodes [source] (with [sound], already coded in [soundMode], or none) to
/// fit [detail]'s budget. [encodeStill] makes the thumbnail.
VoxEncodedVideo voxEncodeVideo({
  required VoxVideoFrames source,
  required VoxVideoDetail detail,
  required VoxAv1ClipEncode encode,
  required VoxAv1ClipDecode decode,
  required VoxAv1Encode encodeStill,
  VoxVoiceMode? soundMode,
  Uint8List? sound,
  VoxFocusRegions focus = VoxFocusRegions.none,
}) {
  if (source.count == 0) throw StateError('The clip has no frames');
  final clip = voxTrimFrames(source, detail.maxSeconds);
  final durationMs = clip.duration.inMilliseconds;
  final soundBytes = soundMode == null ? Uint8List(0) : (sound ?? Uint8List(0));
  final thumb = voxEncodeThumb(clip.frame(0), encodeStill) ?? Uint8List(0);
  final budget =
      detail.budget -
      2 -
      thumb.length -
      voxVideoHeaderBytes -
      soundBytes.length;
  if (budget < 512) {
    throw StateError('No room for the picture at ${detail.label}');
  }

  final aspect = clip.width / clip.height;
  final seconds = durationMs / 1000;
  final maxSide = max(clip.width, clip.height);
  var shape = voxPickVideoShape(
    budget,
    seconds,
    aspect: aspect,
    maxSide: maxSide,
    maxFps: clip.fps,
  );

  // Smallest quantizer (best quality) that fits, by bisection.
  (int, Uint8List)? fitQ(VoxVideoFrames f) {
    var lo = 0, hi = 63;
    (int, Uint8List)? best;
    while (lo <= hi) {
      final q = (lo + hi) >> 1;
      final data = encode(f, q, voxVideoTrialSpeed);
      if (data != null && data.length <= budget) {
        best = (q, data);
        hi = q - 1;
      } else {
        lo = q + 1;
      }
    }
    return best;
  }

  late VoxVideoFrames f;
  late (int, Uint8List) fit;
  while (true) {
    final (w, h) = voxVideoSize(aspect, shape.$1);
    f = voxResampleFrames(clip, w, h, shape.$2);
    if (!focus.isEmpty) f = _softenOutside(f, focus, w / clip.width, detail);
    final found = fitQ(f);
    if (found != null) {
      fit = found;
      break;
    }
    final i = voxVideoShapes.indexOf(shape);
    if (i <= 0) {
      throw StateError('The clip does not fit in ${detail.budget} bytes');
    }
    shape = voxVideoShapes[i - 1];
  }
  // A slower final pass at the quantizer found (or the next ones up, if it
  // came out bigger); the trial encode if none fits.
  var q = fit.$1;
  var data = fit.$2;
  for (var tq = fit.$1; tq <= min(63, fit.$1 + 2); tq++) {
    final d = encode(f, tq, voxVideoFinalSpeed);
    if (d != null && d.length <= budget) {
      q = tq;
      data = d;
      break;
    }
  }
  final decoded = decode(data, f.width, f.height, f.count);
  if (decoded == null) throw StateError('The clip did not decode');
  final preview = VoxVideoFrames(f.width, f.height, f.fps, decoded);

  final head = 2 + thumb.length;
  final payload = Uint8List(
    head + voxVideoHeaderBytes + soundBytes.length + data.length,
  );
  payload[0] = voxVideoPayloadVersion;
  payload[1] = thumb.length;
  payload.setRange(2, head, thumb);
  ByteData.sublistView(payload, head, head + voxVideoHeaderBytes)
    ..setUint16(0, f.width)
    ..setUint16(2, f.height)
    ..setUint8(4, f.fps)
    ..setUint16(5, preview.count)
    ..setUint16(7, min(durationMs, 0xFFFF))
    ..setUint8(9, soundMode?.wireId ?? voxVideoNoSound)
    ..setUint16(10, soundBytes.length);
  var o = head + voxVideoHeaderBytes;
  payload.setRange(o, o + soundBytes.length, soundBytes);
  o += soundBytes.length;
  payload.setRange(o, o + data.length, data);
  return VoxEncodedVideo(
    payload: payload,
    preview: preview,
    detail: detail,
    durationMs: durationMs,
    soundMode: soundMode,
    sound: soundBytes,
    q: q,
  );
}

/// Faces and text ([focus], in [k]-scaled pixels) kept as they are, the rest
/// softened slightly, so the encoder spends the bytes on them.
VoxVideoFrames _softenOutside(
  VoxVideoFrames f,
  VoxFocusRegions focus,
  double k,
  VoxVideoDetail detail,
) {
  final grow = max(f.width, f.height) * 0.06;
  final mask = voxFocusMask(f.width, f.height, [
    for (final r in focus.scaled(k).all) r.inflate(grow),
  ]);
  final (radius, passes) = detail.backgroundSoften;
  final out = Uint8List(f.rgb.length);
  for (var i = 0; i < f.count; i++) {
    final soft = voxSoftenOutside(
      f.frame(i),
      mask,
      radius: radius,
      passes: passes,
    );
    out.setRange(i * f.frameBytes, (i + 1) * f.frameBytes, soft.rgb);
  }
  return VoxVideoFrames(f.width, f.height, f.fps, out);
}

/// The parts of a received payload; null if it isn't a video this build
/// reads.
VoxVideoInfo? voxVideoInfo(Uint8List payload) {
  if (payload.length < 2 || payload[0] != voxVideoPayloadVersion) return null;
  final head = 2 + payload[1];
  if (payload.length < head + voxVideoHeaderBytes) return null;
  final h = ByteData.sublistView(payload, head, head + voxVideoHeaderBytes);
  final width = h.getUint16(0), height = h.getUint16(2);
  final fps = h.getUint8(4), frames = h.getUint16(5);
  final soundId = h.getUint8(9), soundLen = h.getUint16(10);
  final soundAt = head + voxVideoHeaderBytes;
  final streamAt = soundAt + soundLen;
  if (width < 2 ||
      height < 2 ||
      width > 1024 ||
      height > 1024 ||
      fps < 1 ||
      frames < 1 ||
      payload.length <= streamAt) {
    return null;
  }
  final soundMode = soundId == voxVideoNoSound
      ? null
      : VoxVoiceMode.fromWireId(soundId);
  return VoxVideoInfo(
    width: width,
    height: height,
    fps: fps,
    frames: frames,
    durationMs: h.getUint16(7),
    soundMode: soundMode != null && soundMode.isAudio ? soundMode : null,
    sound: Uint8List.sublistView(payload, soundAt, streamAt),
    stream: Uint8List.sublistView(payload, streamAt),
  );
}

/// Decodes a received payload's frames. Null if it isn't a video this build
/// reads, or doesn't decode.
VoxVideoFrames? voxDecodeVideoPayload(
  Uint8List payload,
  VoxAv1ClipDecode decode,
) {
  final info = voxVideoInfo(payload);
  if (info == null) return null;
  final rgb = decode(info.stream, info.width, info.height, info.frames);
  if (rgb == null) return null;
  return VoxVideoFrames(info.width, info.height, info.fps, rgb);
}
