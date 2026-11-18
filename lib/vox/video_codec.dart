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
// Version 4 is one part of a clip sent as several transfers (SuperMax):
//
//   [4][thumb length][thumb OBUs][parts:1][this part:1][packets:1 per part]
//   then as version 3
//
// Each part is a run of the clip coded on its own, so it plays as soon as it
// is in. The first part is the one announced (its envelope's length is the
// whole clip's), with the thumbnail and all the sound; part k's session id
// is voxVideoPartSid(the first's, k), and the packet counts tell a receiver
// how many to ask for.
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

/// A part of a clip sent as several transfers (SuperMax).
const int voxVideoPartsPayloadVersion = 4;

/// The session id of part [k] (from 1) of the clip whose first part is
/// [firstSid]. Distinct from parity ids (vox_fec.dart's XOR).
String voxVideoPartSid(String firstSid, int k) => voxSessionIdFromInt(
  int.parse(firstSid, radix: 16) ^ (0x7A000000 + k * 0x00010101),
);

/// Longest side the picked clip is read at (the largest frame we send).
const int voxVideoSourceSide = 256;

/// Frame rate the picked clip is read at (the fastest we send).
const int voxVideoSourceFps = 12;

/// Longest clip, whatever the budget.
const int voxVideoMaxSeconds = 15;

/// SuperMax's frame size (long side): twice Max's 256 each way, so four
/// times its pixels. The clip is read at this size for it.
const int voxVideoSuperMaxSide = 512;

/// SuperMax's longest clip. It runs at Max's frame rate
/// ([voxVideoSuperMaxFps]) at four times Max's pixels, so each Max-sized
/// part carries about 1.5 s ([voxSuperMaxFrames]); its
/// [voxVideoSuperMaxParts] parts about 4.5 s.
const int voxVideoSuperMaxSeconds = 5;

/// Transfers a SuperMax clip goes in, each Max's size.
const int voxVideoSuperMaxParts = 3;

/// SuperMax's frame rate: Max's fastest, [voxVideoSourceFps].
const int voxVideoSuperMaxFps = voxVideoSourceFps;

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
/// exactly Super Sharp: the most one transfer carries. SuperMax spends that
/// on each of [voxVideoSuperMaxParts] transfers, at four times Max's
/// resolution ([voxVideoSuperMaxSide]) and Max's frame rate.
enum VoxVideoDetail {
  quick(4, 'Quick', 6),
  clear(8, 'Clear', 10),
  maximum(14, 'Max', voxVideoMaxSeconds),
  superMax(14, 'SuperMax', voxVideoSuperMaxSeconds, voxVideoSuperMaxParts);

  const VoxVideoDetail(
    this.multiple,
    this.label,
    this.maxSeconds, [
    this.parts = 1,
  ]);
  final int multiple;
  final String label;

  /// Transfers it goes in, each [budget] bytes.
  final int parts;

  /// Longest clip at this level: the start of a longer one is sent.
  final int maxSeconds;
  int get budget => voxImageBaseBudget * multiple;

  /// The long side the clip is read at for this level.
  int get sourceSide =>
      this == superMax ? voxVideoSuperMaxSide : voxVideoSourceSide;

  /// The frame sizes and rates this level picks from.
  List<(int side, int fps)> get shapes =>
      this == superMax ? voxVideoSuperMaxShapes : voxVideoShapes;

  /// Box-blur radius and passes for what lies outside faces and text, when
  /// there are some: as for photos, gentler as the budget grows.
  (int radius, int passes) get backgroundSoften => switch (this) {
    quick => (2, 2),
    clear => (1, 2),
    maximum || superMax => (1, 1),
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

/// SuperMax's shape: [voxVideoSuperMaxSide] at [voxVideoSuperMaxFps]. The
/// length gives way, not the frame rate.
const List<(int side, int fps)> voxVideoSuperMaxShapes = [
  (voxVideoSuperMaxSide, voxVideoSuperMaxFps),
];

/// SuperMax frames (at [voxVideoSuperMaxFps]) of [w] x [h] that [bytes] code
/// at [voxVideoMinBitsPerPixel] or better; at least one.
int voxSuperMaxFrames(int bytes, int w, int h) =>
    max(1, (bytes * 8 / (voxVideoMinBitsPerPixel * w * h)).floor());

/// [src] cut to its first [frames] frames.
VoxVideoFrames voxTrimFrameCount(VoxVideoFrames src, int frames) {
  final n = min(src.count, max(1, frames));
  if (n == src.count) return src;
  return VoxVideoFrames(
    src.width,
    src.height,
    src.fps,
    Uint8List.sublistView(src.rgb, 0, n * src.frameBytes),
  );
}

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
  /// The first (announced) part's payload; the whole clip unless SuperMax.
  final Uint8List payload;

  /// The other parts' payloads, in order (SuperMax), sent as transfers of
  /// their own at [voxVideoPartSid].
  final List<Uint8List> moreParts;

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
    this.moreParts = const [],
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

  /// Parts decoded into [frames] (SuperMax goes in several), and whether
  /// more are still to come in.
  final int parts;
  final bool more;

  const VoxPlayableVideo({
    required this.frames,
    required this.durationMs,
    this.wav,
    this.soundNote,
    this.hasSound = false,
    this.parts = 1,
    this.more = false,
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

  /// Parts the clip was sent in (1: one transfer), which this one is (from
  /// 0), and each part's packet count (empty for one part).
  final int partCount;
  final int partIndex;
  final List<int> partTotals;
  const VoxVideoInfo({
    required this.width,
    required this.height,
    required this.fps,
    required this.frames,
    required this.durationMs,
    required this.soundMode,
    required this.sound,
    required this.stream,
    this.partCount = 1,
    this.partIndex = 0,
    this.partTotals = const [],
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
  List<(int side, int fps)> shapes = voxVideoShapes,
}) {
  var pick = shapes.first;
  for (final s in shapes) {
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

/// One coded run of frames: the frames as sent, the stream, its quantizer,
/// and how many of the given source frames it covers.
class _VoxSegment {
  final VoxVideoFrames frames;
  final Uint8List data;
  final int q;
  final int sourceFrames;
  final int durationMs;
  const _VoxSegment(
    this.frames,
    this.data,
    this.q,
    this.sourceFrames,
    this.durationMs,
  );
}

/// Codes [clip] in at most [budget] bytes. Ordinary levels pick the frame
/// size and rate (dropping to smaller ones until it fits); SuperMax keeps
/// its size and frame rate and codes a shorter run instead.
_VoxSegment _encodeSegment({
  required VoxVideoFrames clip,
  required int budget,
  required VoxVideoDetail detail,
  required VoxAv1ClipEncode encode,
  required VoxFocusRegions focus,
  required double aspect,
}) {
  final superMax = detail == VoxVideoDetail.superMax;
  final seconds = clip.duration.inMilliseconds / 1000;
  final maxSide = max(clip.width, clip.height);
  var shape = voxPickVideoShape(
    budget,
    seconds,
    aspect: aspect,
    // SuperMax keeps its size even from a smaller clip.
    maxSide: max(maxSide, detail.shapes.first.$1),
    maxFps: clip.fps,
    shapes: detail.shapes,
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

  var run = clip;
  late VoxVideoFrames f;
  late (int, Uint8List) fit;
  while (true) {
    final (w, h) = voxVideoSize(aspect, shape.$1);
    f = voxResampleFrames(run, w, h, shape.$2);
    if (!focus.isEmpty) f = _softenOutside(f, focus, w / run.width, detail);
    final found = fitQ(f);
    if (found != null) {
      fit = found;
      break;
    }
    if (superMax && run.count > 1) {
      // SuperMax keeps its size and frame rate: a shorter run instead.
      run = voxTrimFrameCount(run, (run.count * 0.8).floor());
      continue;
    }
    final i = detail.shapes.indexOf(shape);
    if (i <= 0) {
      throw StateError('The clip does not fit in ${detail.budget} bytes');
    }
    shape = detail.shapes[i - 1];
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
  return _VoxSegment(f, data, q, run.count, run.duration.inMilliseconds);
}

/// The part block's length in a [parts]-part payload (version 4): the part
/// count, this part's index, and every part's packet count.
int voxVideoPartBlockBytes(int parts) => parts > 1 ? 2 + parts : 0;

/// Packets a payload of [bytes] takes.
int voxVideoPacketsFor(int bytes) {
  final per = VoxVoiceMode.av1Video.bytesPerPacket;
  return (bytes + per - 1) ~/ per;
}

/// A payload: version 3, or 4 with the part block ([partCount] > 1;
/// [partTotals] filled in afterwards, see [voxVideoSetPartTotals]).
Uint8List _videoPayload({
  required Uint8List thumb,
  required int partCount,
  required int partIndex,
  required VoxVideoFrames f,
  required int frames,
  required int durationMs,
  required VoxVoiceMode? soundMode,
  required Uint8List sound,
  required Uint8List data,
}) {
  final block = voxVideoPartBlockBytes(partCount);
  final head = 2 + thumb.length + block;
  final payload = Uint8List(
    head + voxVideoHeaderBytes + sound.length + data.length,
  );
  payload[0] = partCount > 1 ? voxVideoPartsPayloadVersion : 3;
  payload[1] = thumb.length;
  payload.setRange(2, 2 + thumb.length, thumb);
  if (partCount > 1) {
    payload[2 + thumb.length] = partCount;
    payload[3 + thumb.length] = partIndex;
  }
  ByteData.sublistView(payload, head, head + voxVideoHeaderBytes)
    ..setUint16(0, f.width)
    ..setUint16(2, f.height)
    ..setUint8(4, f.fps)
    ..setUint16(5, frames)
    ..setUint16(7, min(durationMs, 0xFFFF))
    ..setUint8(9, soundMode?.wireId ?? voxVideoNoSound)
    ..setUint16(10, sound.length);
  var o = head + voxVideoHeaderBytes;
  payload.setRange(o, o + sound.length, sound);
  o += sound.length;
  payload.setRange(o, o + data.length, data);
  return payload;
}

/// Writes every part's packet count into each of [payloads] (a version 4
/// clip's parts, in order).
void voxVideoSetPartTotals(List<Uint8List> payloads) {
  final totals = [for (final p in payloads) voxVideoPacketsFor(p.length)];
  for (final p in payloads) {
    final at = 4 + p[1];
    for (var i = 0; i < totals.length; i++) {
      p[at + i] = min(totals[i], voxMaxPackets);
    }
  }
}

/// Encodes [source] (with [sound], already coded in [soundMode], or none) to
/// fit [detail]'s budget. [encodeStill] makes the thumbnail.
///
/// SuperMax sends up to [VoxVideoDetail.parts] parts, each a Max-sized
/// transfer of its own: the clip in runs at 512 px and Max's frame rate, as
/// much in each as Max's bytes code well. The thumbnail and all the sound go
/// in the first part, so it plays (with sound) while the rest come in.
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
  final soundBytes = soundMode == null ? Uint8List(0) : (sound ?? Uint8List(0));
  final thumb = voxEncodeThumb(clip.frame(0), encodeStill) ?? Uint8List(0);
  final aspect = clip.width / clip.height;
  final superMax = detail == VoxVideoDetail.superMax;
  final block = voxVideoPartBlockBytes(detail.parts);
  // The source frames per SuperMax frame (the source may be slower).
  final perFrame = clip.fps / min(clip.fps, voxVideoSuperMaxFps);

  final segments = <_VoxSegment>[];
  var cursor = 0;
  for (var k = 0; k < detail.parts && cursor < clip.count; k++) {
    final first = k == 0;
    final budget =
        detail.budget -
        2 -
        (first ? thumb.length + soundBytes.length : 0) -
        block -
        voxVideoHeaderBytes;
    if (budget < 512) {
      throw StateError('No room for the picture at ${detail.label}');
    }
    var run = voxSliceFrames(clip, cursor, clip.count - cursor);
    if (superMax) {
      // Max's frame rate at four times its pixels: as long as the bytes code
      // well; the next part carries on from there.
      final (w, h) = voxVideoSize(aspect, voxVideoSuperMaxSide);
      final fits = voxSuperMaxFrames(budget, w, h);
      run = voxTrimFrameCount(run, max(1, (fits * perFrame).floor()));
    }
    final seg = _encodeSegment(
      clip: run,
      budget: budget,
      detail: detail,
      encode: encode,
      focus: focus,
      aspect: aspect,
    );
    segments.add(seg);
    cursor += seg.sourceFrames;
  }

  final n = segments.length;
  final payloads = <Uint8List>[];
  final previews = <VoxVideoFrames>[];
  var durationMs = 0;
  for (var k = 0; k < n; k++) {
    final seg = segments[k];
    final f = seg.frames;
    final decoded = decode(seg.data, f.width, f.height, f.count);
    if (decoded == null) throw StateError('The clip did not decode');
    final preview = VoxVideoFrames(f.width, f.height, f.fps, decoded);
    previews.add(preview);
    durationMs += seg.durationMs;
    payloads.add(
      _videoPayload(
        thumb: k == 0 ? thumb : Uint8List(0),
        partCount: n,
        partIndex: k,
        f: f,
        frames: preview.count,
        durationMs: seg.durationMs,
        soundMode: k == 0 ? soundMode : null,
        sound: k == 0 ? soundBytes : Uint8List(0),
        data: seg.data,
      ),
    );
  }
  if (n > 1) voxVideoSetPartTotals(payloads);
  return VoxEncodedVideo(
    payload: payloads.first,
    moreParts: payloads.sublist(1),
    preview: voxJoinFrames(previews),
    detail: detail,
    durationMs: durationMs,
    soundMode: soundMode,
    sound: soundBytes,
    q: segments.map((s) => s.q).reduce(max),
  );
}

/// [count] frames of [src] from [start].
VoxVideoFrames voxSliceFrames(VoxVideoFrames src, int start, int count) {
  final s = start.clamp(0, src.count);
  final n = count.clamp(0, src.count - s);
  if (s == 0 && n == src.count) return src;
  return VoxVideoFrames(
    src.width,
    src.height,
    src.fps,
    Uint8List.sublistView(
      src.rgb,
      s * src.frameBytes,
      (s + n) * src.frameBytes,
    ),
  );
}

/// [parts] one after another (all the same size and rate).
VoxVideoFrames voxJoinFrames(List<VoxVideoFrames> parts) {
  if (parts.length == 1) return parts.first;
  final b = BytesBuilder(copy: false);
  for (final p in parts) {
    b.add(p.rgb);
  }
  final f = parts.first;
  return VoxVideoFrames(f.width, f.height, f.fps, b.toBytes());
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
  if (payload.length < 2) return null;
  final v = payload[0];
  if (v != voxVideoPayloadVersion && v != voxVideoPartsPayloadVersion) {
    return null;
  }
  var head = 2 + payload[1];
  var partCount = 1, partIndex = 0;
  var partTotals = const <int>[];
  if (v == voxVideoPartsPayloadVersion) {
    if (payload.length < head + 2) return null;
    partCount = payload[head];
    partIndex = payload[head + 1];
    if (partCount < 2 ||
        partIndex >= partCount ||
        payload.length < head + 2 + partCount) {
      return null;
    }
    partTotals = List<int>.unmodifiable(
      payload.sublist(head + 2, head + 2 + partCount),
    );
    head += 2 + partCount;
  }
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
    partCount: partCount,
    partIndex: partIndex,
    partTotals: partTotals,
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
