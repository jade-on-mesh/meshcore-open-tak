import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/vox/av1_ffi.dart';
import 'package:meshcore_open/vox/image_codec.dart';
import 'package:meshcore_open/vox/image_focus.dart';
import 'package:meshcore_open/vox/voice_wire.dart';

VoxRgbImage _gradient(int w, int h) {
  final rgb = Uint8List(w * h * 3);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 3;
      rgb[i] = (x * 255 ~/ w);
      rgb[i + 1] = (y * 255 ~/ h);
      rgb[i + 2] = ((x + y) * 3) & 0xFF;
    }
  }
  return VoxRgbImage(w, h, rgb);
}

/// Stand-in for libaom: "compresses" by size and quantizer, and decodes to
/// the scaled picture with noise that grows with q.
class _FakeAv1 {
  final _pictures = <int, VoxRgbImage>{};
  int calls = 0;

  Uint8List? encode(VoxRgbImage img, int q, int speed) {
    final id = ++calls;
    final n = (img.width * img.height * 3 * 0.12 / (1 + q / 6)).round() + 12;
    final data = Uint8List(n)..buffer.asByteData().setUint32(0, id);
    final noisy = Uint8List.fromList(img.rgb);
    for (var i = 0; i < noisy.length; i += 7) {
      noisy[i] = (noisy[i] + q).clamp(0, 255);
    }
    _pictures[id] = VoxRgbImage(img.width, img.height, noisy);
    return data;
  }

  VoxRgbImage? decode(Uint8List obus) => obus.length < 4
      ? null
      : _pictures[ByteData.sublistView(obus).getUint32(0)];
}

void main() {
  group('VI1 image envelope', () {
    test('round-trips and carries the aspect ratio', () {
      final env = VoxVoiceEnvelope(
        sessionId: 'deadbeef',
        mode: VoxVoiceMode.av1Image,
        totalPackets: 18,
        durationSeconds: voxAspectCode(4 / 3),
      );
      final text = env.encode();
      expect(text, startsWith('VI1:'));
      final back = VoxVoiceEnvelope.tryParse(text)!;
      expect(back.isImage, isTrue);
      expect(back.totalPackets, 18);
      expect(back.imageAspect, closeTo(1.33, 0.01));
    });

    test('image and audio prefixes never cross', () {
      expect(VoxVoiceEnvelope.tryParse('VI1:1ps9wxb:1:5:5'), isNull);
      expect(VoxVoiceEnvelope.tryParse('VE3:1ps9wxb:14:5:5'), isNull);
      expect(VoxVoiceEnvelope.tryParse('VM1:1ps9wxb:14:5:5'), isNull);
      expect(VoxVoiceMode.av1Image.isCodec2, isFalse);
      expect(VoxVoiceMode.av1Image.isAudio, isFalse);
    });

    test('a standard image is 18 packets that fit channel data salted', () {
      final pkts = voxPacketize(
        '0000000a',
        Uint8List(VoxImageDetail.standard.budget),
        VoxVoiceMode.av1Image,
      );
      expect(pkts.length, 18);
      expect(
        pkts.every((p) => p.encode(salt: 1).length <= voxMaxChannelDataBytes),
        isTrue,
      );
      final most = voxPacketize(
        '0000000a',
        Uint8List(VoxImageDetail.more.budget),
        VoxVoiceMode.av1Image,
      );
      expect(most.length, lessThanOrEqualTo(voxMaxPackets));
      // Super Sharp is the largest a transfer can carry: 247 of 255 packets.
      final top = voxPacketize(
        '0000000a',
        Uint8List(VoxImageDetail.superSharp.budget),
        VoxVoiceMode.av1Image,
      );
      expect(top.length, 247);
      expect(top.length, lessThanOrEqualTo(voxMaxPackets));
      expect(VoxImageDetail.superSharp.workSide, voxImageMaxWorkSide);
      expect(VoxImageDetail.sharp.workSide, voxImageWorkSide);
    });
  });

  group('pixel helpers', () {
    test('area downscale averages', () {
      final img = VoxRgbImage(
        2,
        2,
        Uint8List.fromList([
          0, 0, 0, 100, 100, 100, //
          200, 200, 200, 100, 100, 100,
        ]),
      );
      final small = voxResize(img, 1, 1);
      expect(small.rgb, [100, 100, 100]);
    });

    test('fit size keeps the aspect ratio', () {
      expect(voxFitSize(4000, 3000, 768), (768, 576));
      expect(voxFitSize(300, 200, 768), (300, 200));
    });

    test('focus mask is 1 inside and 0 far away', () {
      final m = voxFocusMask(40, 40, const [VoxRect(10, 10, 10, 10)]);
      expect(m[15 * 40 + 15], closeTo(1, 0.05));
      expect(m[35 * 40 + 35], 0);
    });

    test('softening leaves the focus region untouched', () {
      final img = _gradient(40, 40);
      final mask = voxFocusMask(40, 40, const [
        VoxRect(0, 0, 20, 40),
      ], feather: 0);
      final soft = voxSoftenOutside(img, mask);
      expect(soft.rgb.sublist(0, 3), img.rgb.sublist(0, 3));
    });

    test('background blur eases off as the budget grows', () {
      expect(VoxImageDetail.standard.backgroundSoften, (2, 3));
      expect(VoxImageDetail.more.backgroundSoften, (1, 1));
      expect(VoxImageDetail.sharp.backgroundSoften, isNull);
      expect(VoxImageDetail.superSharp.backgroundSoften, isNull);
    });

    test('text boxes come from connected regions of the probability map', () {
      const w = 20, h = 10;
      final p = List<double>.filled(w * h, 0);
      for (var y = 2; y < 5; y++) {
        for (var x = 2; x < 8; x++) {
          p[y * w + x] = 0.9;
        }
        for (var x = 12; x < 18; x++) {
          p[y * w + x] = 0.9;
        }
      }
      final boxes = voxTextBoxesFromProb(p, w, h);
      expect(boxes.length, 2);
      expect(boxes.first.left, lessThan(2));
      expect(boxes.first.width, greaterThan(6));
    });
  });

  group('encode search', () {
    test('fits the budget and prefixes the version byte', () {
      final fake = _FakeAv1();
      final enc = voxEncodeImage(
        ref: _gradient(300, 200),
        detail: VoxImageDetail.standard,
        encode: fake.encode,
        decode: fake.decode,
      );
      expect(enc.payload.length, lessThanOrEqualTo(voxImageBaseBudget));
      expect(enc.payload[0], voxImagePayloadVersion);
      expect(enc.aspect, closeTo(1.5, 0.01));
      expect(enc.focused, isFalse);
      expect(enc.textPsnr, isNull);
      expect(voxDecodeImagePayload(enc.payload, fake.decode), isNotNull);
    });

    test('more detail never sends fewer bytes', () {
      final fake = _FakeAv1();
      final ref = _gradient(300, 200);
      final a = voxEncodeImage(
        ref: ref,
        detail: VoxImageDetail.standard,
        encode: fake.encode,
        decode: fake.decode,
      );
      final b = voxEncodeImage(
        ref: ref,
        detail: VoxImageDetail.more,
        encode: fake.encode,
        decode: fake.decode,
      );
      expect(b.payload.length, greaterThanOrEqualTo(a.payload.length));
      expect(b.payload.length, lessThanOrEqualTo(VoxImageDetail.more.budget));
    });

    test('focus regions are used and text gets a readability score', () {
      final fake = _FakeAv1();
      final enc = voxEncodeImage(
        ref: _gradient(300, 200),
        detail: VoxImageDetail.standard,
        encode: fake.encode,
        decode: fake.decode,
        focus: const VoxFocusRegions(text: [VoxRect(20, 20, 100, 20)]),
      );
      expect(enc.focused, isTrue);
      expect(enc.textPsnr, isNotNull);
    });

    test('a thumbnail rides in the first two packets, inside the budget', () {
      final fake = _FakeAv1();
      for (final detail in VoxImageDetail.values) {
        final enc = voxEncodeImage(
          ref: _gradient(300, 200),
          detail: detail,
          encode: fake.encode,
          decode: fake.decode,
        );
        expect(enc.payload.length, lessThanOrEqualTo(detail.budget));
        expect(enc.payload[0], 2);
        final n = enc.payload[1];
        expect(n, greaterThan(0));
        final head = voxThumbPackets * voxMaxCodecBytesPerPacket;
        expect(2 + n, lessThanOrEqualTo(head));
        // The first two packets alone give the thumbnail, at most 96 px.
        final first = Uint8List.sublistView(enc.payload, 0, head);
        final thumb = voxDecodeImageThumb(first, fake.decode);
        expect(thumb, isNotNull);
        expect(thumb!.width, lessThanOrEqualTo(voxThumbSide));
        expect(thumb.height, lessThanOrEqualTo(voxThumbSide));
        // The first packet alone is not enough when it's longer than that.
        if (2 + n > voxMaxCodecBytesPerPacket) {
          final one = Uint8List.sublistView(
            enc.payload,
            0,
            voxMaxCodecBytesPerPacket,
          );
          expect(voxDecodeImageThumb(one, fake.decode), isNull);
        }
        // And the whole payload still gives the photo, not the thumbnail.
        final photo = voxDecodeImagePayload(enc.payload, fake.decode)!;
        expect(photo.width, greaterThan(voxThumbSide));
      }
    });

    test('the thumbnail is 96 px when that fits', () {
      final fake = _FakeAv1();
      final t = voxEncodeThumb(_gradient(300, 200), fake.encode)!;
      expect(fake.decode(t)!.width, voxThumbSide);
      expect(t.length, lessThanOrEqualTo(voxThumbMaxBytes));
    });

    test('reads version 1 payloads, which carry no thumbnail', () {
      final fake = _FakeAv1();
      final obus = fake.encode(_gradient(120, 80), 20, 4)!;
      final v1 = Uint8List.fromList([voxImagePayloadV1, ...obus]);
      expect(voxDecodeImagePayload(v1, fake.decode)?.width, 120);
      expect(voxImageThumbObus(v1), isNull);
    });

    test('no thumbnail until all of it is in', () {
      final p = Uint8List.fromList([2, 10, 1, 2, 3]);
      expect(voxImageThumbObus(p), isNull);
      expect(voxImageThumbObus(Uint8List.fromList([2, 0, 9, 9])), isNull);
    });

    test('rejects payloads from an unknown format version', () {
      final fake = _FakeAv1();
      expect(
        voxDecodeImagePayload(Uint8List.fromList([9, 1, 2]), fake.decode),
        isNull,
      );
    });
  });
}
