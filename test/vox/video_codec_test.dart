import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/vox/av1_ffi.dart';
import 'package:meshcore_open/vox/image_codec.dart';
import 'package:meshcore_open/vox/video_codec.dart';
import 'package:meshcore_open/vox/voice_wire.dart';

/// [seconds] of a moving gradient at [fps].
VoxVideoFrames _clip(int w, int h, int fps, int seconds) {
  final n = fps * seconds;
  final rgb = Uint8List(n * w * h * 3);
  for (var f = 0; f < n; f++) {
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final i = ((f * h + y) * w + x) * 3;
        rgb[i] = (x * 255 ~/ w + f) & 0xFF;
        rgb[i + 1] = (y * 255 ~/ h) & 0xFF;
        rgb[i + 2] = f * 7 & 0xFF;
      }
    }
  }
  return VoxVideoFrames(w, h, fps, rgb);
}

/// Stand-in for libaom: a clip "compresses" by pixels and quantizer and
/// decodes to its own frames; stills as in image_codec_test.dart.
class _FakeAv1 {
  final _clips = <int, VoxVideoFrames>{};
  final _stills = <int, VoxRgbImage>{};
  int calls = 0;
  final speeds = <int>[];

  Uint8List? encodeClip(VoxVideoFrames f, int q, int speed) {
    final id = ++calls;
    speeds.add(speed);
    final n = (f.rgb.length * 0.05 / (1 + q / 3)).round() + 16;
    _clips[id] = f;
    return Uint8List(n)..buffer.asByteData().setUint32(0, id);
  }

  Uint8List? decodeClip(Uint8List stream, int w, int h, int maxFrames) {
    final f = _clips[ByteData.sublistView(stream).getUint32(0)];
    if (f == null || f.width != w || f.height != h) return null;
    return Uint8List.sublistView(f.rgb, 0, maxFrames * w * h * 3);
  }

  Uint8List? encodeStill(VoxRgbImage img, int q, int speed) {
    final id = 1000000 + ++calls;
    final n = (img.width * img.height * 3 * 0.12 / (1 + q / 6)).round() + 12;
    _stills[id] = img;
    return Uint8List(n)..buffer.asByteData().setUint32(0, id);
  }

  VoxRgbImage? decodeStill(Uint8List obus) =>
      _stills[ByteData.sublistView(obus).getUint32(0)];
}

void main() {
  group('VV1 video envelope', () {
    test('round-trips with its label, length and caption', () {
      const env = VoxVoiceEnvelope(
        sessionId: 'deadbeef',
        mode: VoxVoiceMode.av1Video,
        totalPackets: 247,
        durationSeconds: 10,
        caption: 'the ridge',
      );
      final text = env.encode();
      expect(text, startsWith('VV1:'));
      expect(text, contains(' VIDEO the ridge'));
      final back = VoxVoiceEnvelope.tryParse(text)!;
      expect(back.isVideo, isTrue);
      expect(back.isImage, isFalse);
      expect(back.isMedia, isTrue);
      expect(back.isTalk, isFalse);
      expect(back.totalPackets, 247);
      expect(back.durationSeconds, 10);
      expect(back.caption, 'the ridge');
      expect(env.envelopeText.length, lessThanOrEqualTo(voxEnvelopeMaxLength));
      expect(VoxVoiceEnvelope.previewText(text), '🎬 Video: the ridge');
    });

    test('a video mode under another prefix is not an envelope', () {
      expect(VoxVoiceEnvelope.tryParse('VI1:1ps9wxb:15:6v:a'), isNull);
      expect(VoxVoiceEnvelope.tryParse('VE3:1ps9wxb:15:6v:a'), isNull);
    });

    test('is not audio', () {
      expect(VoxVoiceMode.av1Video.isAudio, isFalse);
      expect(VoxVoiceMode.av1Video.isCodec2, isFalse);
      expect(VoxVoiceMode.av1Video.bytesPerPacket, voxMaxCodecBytesPerPacket);
    });
  });

  group('budgets', () {
    test('Max is exactly Super Sharp, and fits one transfer', () {
      expect(VoxVideoDetail.maximum.budget, VoxImageDetail.superSharp.budget);
      for (final d in VoxVideoDetail.values) {
        expect(
          (d.budget / voxMaxCodecBytesPerPacket).ceil(),
          lessThanOrEqualTo(voxMaxPackets),
        );
      }
    });
  });

  group('shape', () {
    test('more bytes buy more pixels per second', () {
      final small = voxPickVideoShape(6000, 6, aspect: 4 / 3);
      final big = voxPickVideoShape(36000, 10, aspect: 4 / 3);
      int rate((int, int) s) {
        final (w, h) = voxVideoSize(4 / 3, s.$1);
        return w * h * s.$2;
      }

      expect(rate(big), greaterThan(rate(small)));
      expect(big, (160, 12));
    });

    test('never above the source', () {
      final s = voxPickVideoShape(200000, 2, aspect: 1, maxSide: 128);
      expect(s.$1, lessThanOrEqualTo(128));
    });

    test('sizes are even, either way up', () {
      final (w, h) = voxVideoSize(16 / 9, 160);
      expect(w, 160);
      expect(h.isEven, isTrue);
      final (pw, ph) = voxVideoSize(9 / 16, 160);
      expect(ph, 160);
      expect(pw.isEven, isTrue);
    });
  });

  group('encode', () {
    test('fits the budget and round-trips the header and sound', () {
      final av1 = _FakeAv1();
      final sound = Uint8List.fromList(List.generate(1100, (i) => i & 0xFF));
      final enc = voxEncodeVideo(
        source: _clip(256, 192, 12, 10),
        detail: VoxVideoDetail.maximum,
        encode: av1.encodeClip,
        decode: av1.decodeClip,
        encodeStill: av1.encodeStill,
        soundMode: VoxVoiceMode.mimi,
        sound: sound,
      );
      expect(
        enc.payload.length,
        lessThanOrEqualTo(VoxVideoDetail.maximum.budget),
      );
      expect(enc.payload[0], voxVideoPayloadVersion);
      expect(enc.durationMs, 10000);
      expect(enc.seconds, 10);
      expect(av1.speeds, contains(voxVideoFinalSpeed));

      final info = voxVideoInfo(enc.payload)!;
      expect(info.width, enc.preview.width);
      expect(info.height, enc.preview.height);
      expect(info.fps, enc.preview.fps);
      expect(info.frames, enc.preview.count);
      expect(info.durationMs, 10000);
      expect(info.soundMode, VoxVoiceMode.mimi);
      expect(info.sound, sound);

      final frames = voxDecodeVideoPayload(enc.payload, av1.decodeClip)!;
      expect(frames.count, enc.preview.count);
    });

    test('the thumbnail is where a photo has it', () {
      final av1 = _FakeAv1();
      final enc = voxEncodeVideo(
        source: _clip(160, 120, 12, 4),
        detail: VoxVideoDetail.quick,
        encode: av1.encodeClip,
        decode: av1.decodeClip,
        encodeStill: av1.encodeStill,
      );
      final prefix = Uint8List.sublistView(
        enc.payload,
        0,
        voxThumbPackets * voxMaxCodecBytesPerPacket,
      );
      expect(voxImageThumbObus(prefix), isNotNull);
      expect(voxDecodeImageThumb(prefix, av1.decodeStill), isNotNull);
      // Not a photo, though.
      expect(voxImagePhotoObus(enc.payload), isNull);
    });

    test('a long clip is cut to the level\'s length', () {
      final av1 = _FakeAv1();
      final enc = voxEncodeVideo(
        source: _clip(96, 72, 6, 12),
        detail: VoxVideoDetail.quick,
        encode: av1.encodeClip,
        decode: av1.decodeClip,
        encodeStill: av1.encodeStill,
      );
      expect(enc.durationMs, VoxVideoDetail.quick.maxSeconds * 1000);
    });

    test('without sound, says so', () {
      final av1 = _FakeAv1();
      final enc = voxEncodeVideo(
        source: _clip(96, 72, 6, 2),
        detail: VoxVideoDetail.quick,
        encode: av1.encodeClip,
        decode: av1.decodeClip,
        encodeStill: av1.encodeStill,
      );
      final info = voxVideoInfo(enc.payload)!;
      expect(info.soundMode, isNull);
      expect(info.sound, isEmpty);
    });
  });

  group('payload', () {
    test('photos are not videos', () {
      expect(voxVideoInfo(Uint8List.fromList([2, 0, 1, 2, 3])), isNull);
      expect(voxVideoInfo(Uint8List(0)), isNull);
    });

    test('a truncated header is rejected', () {
      expect(voxVideoInfo(Uint8List.fromList([3, 0, 0, 160])), isNull);
    });
  });

  group('resample', () {
    test('halves the rate and scales', () {
      final src = _clip(64, 48, 12, 2);
      final out = voxResampleFrames(src, 32, 24, 6);
      expect(out.count, 12);
      expect(out.width, 32);
      expect(out.rgb.length, 12 * 32 * 24 * 3);
    });
  });
}
