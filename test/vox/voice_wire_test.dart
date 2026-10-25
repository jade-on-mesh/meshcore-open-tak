import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/vox/voice_wire.dart';

Uint8List _hex(String h) => Uint8List.fromList([
  for (var i = 0; i < h.length; i += 2)
    int.parse(h.substring(i, i + 2), radix: 16),
]);

String _toHex(List<int> b) =>
    b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('recording quality', () {
    test('offers the three rates Wadamesh records in', () {
      expect(voxCodec2RecordModes.map((m) => m.wireId), [1, 5, 6]);
      expect(voxCodec2RecordModes.first, voxDefaultVoiceMode);
    });

    test('a 20 s clip fits the packet limit at every rate', () {
      for (final m in voxCodec2RecordModes) {
        final bytes = 20 * m.bytesPerSecond;
        final packets = (bytes / m.bytesPerPacket).ceil();
        expect(packets, lessThanOrEqualTo(voxMaxPackets), reason: m.label);
      }
      expect(VoxVoiceMode.mode1600.bytesPerSecond, 200);
      expect(VoxVoiceMode.mode3200.bytesPerSecond, 400);
    });
  });

  group('VE3 envelope', () {
    test('parses the VE3 reference example', () {
      final env = VoxVoiceEnvelope.tryParse('VE3:a:1:4:4')!;
      expect(env.sessionId, '0000000a');
      expect(env.mode, VoxVoiceMode.mode1200);
      expect(env.totalPackets, 4);
      expect(env.durationSeconds, 4);
    });

    test('round-trips base36 fields', () {
      const env = VoxVoiceEnvelope(
        sessionId: 'deadbeef',
        mode: VoxVoiceMode.mode1200,
        totalPackets: 20,
        durationSeconds: 19,
      );
      expect(env.encode(), 'VE3:1ps9wxb:1:k:j');
      final back = VoxVoiceEnvelope.tryParse(env.encode())!;
      expect(back.sessionId, 'deadbeef');
      expect(back.totalPackets, 20);
      expect(back.durationSeconds, 19);
    });

    test('rejects malformed envelopes', () {
      for (final bad in [
        'VE3:a:1:4',
        'VE3:a:9:4:4', // unknown mode
        'VE3:a:1:0:4', // zero packets
        'VE3:a:1:74:4', // 256 packets
        'VE3:A:1:4:4', // uppercase is not base36 on the wire
        'hello VE3:a:1:4:4',
        'VE2:a:1:4:4',
        'VE3:a:1:4:4X hi', // a bad field is not rescued by a caption
      ]) {
        expect(VoxVoiceEnvelope.tryParse(bad), isNull, reason: bad);
      }
    });
  });

  group('caption', () {
    const photo = VoxVoiceEnvelope(
      sessionId: 'deadbeef',
      mode: VoxVoiceMode.av1Image,
      totalPackets: 18,
      durationSeconds: 75,
    );

    test('without a caption the text is plain VE3, unchanged', () {
      expect(photo.encode(), isNot(contains(' ')));
      expect(photo.withCaption('  ').encode(), photo.encode());
      expect(VoxVoiceEnvelope.tryParse(photo.encode())!.caption, isEmpty);
    });

    test('rides after the envelope and round-trips', () {
      final text = photo.withCaption('Look at this: the T-Deck!').encode();
      expect(text, startsWith('${photo.encode()} '));
      final back = VoxVoiceEnvelope.tryParse(text)!;
      expect(back.caption, 'Look at this: the T-Deck!');
      expect(back.sessionId, 'deadbeef');
      expect(back.totalPackets, 18);
      expect(back.imageAspect, 0.75);
    });

    test('keeps line breaks and emoji', () {
      final text = photo.withCaption('Two lines\nsecond 🌲').encode();
      expect(VoxVoiceEnvelope.tryParse(text)!.caption, 'Two lines\nsecond 🌲');
    });

    test('a voice clip carries one too', () {
      final back = VoxVoiceEnvelope.tryParse('VE3:a:1:4:4 on my way')!;
      expect(back.mode, VoxVoiceMode.mode1200);
      expect(back.caption, 'on my way');
    });

    test('the longest envelope is voxEnvelopeMaxLength', () {
      final env = VoxVoiceEnvelope(
        sessionId: 'ffffffff',
        mode: VoxVoiceMode.av1Image,
        totalPackets: voxMaxPackets,
        durationSeconds: voxMaxDurationSeconds,
      );
      expect(env.encode().length, voxEnvelopeMaxLength);
      for (final m in VoxVoiceMode.values) {
        final e = VoxVoiceEnvelope(
          sessionId: 'ffffffff',
          mode: m,
          totalPackets: voxMaxPackets,
          durationSeconds: voxMaxDurationSeconds,
        );
        expect(
          e.encode().length,
          lessThanOrEqualTo(voxEnvelopeMaxLength),
          reason: m.label,
        );
      }
    });

    test('a fitted caption and envelope stay within the text limit', () {
      const limit = 133;
      final long = 'é' * 200;
      final fitted = voxFitCaption(long, voxCaptionMaxBytes(limit));
      final text = photo.withCaption(fitted).encode();
      expect(utf8.encode(text).length, lessThanOrEqualTo(limit));
      expect(fitted, isNotEmpty);
      // Cut on a character boundary, never mid-way through one.
      expect(fitted.runes.every((r) => r == 0xE9), isTrue);
    });

    test('previews read like a chat app', () {
      expect(VoxVoiceEnvelope.previewText(photo.encode()), '📷 Photo');
      expect(
        VoxVoiceEnvelope.previewText(photo.withCaption('Hi').encode()),
        '📷 Photo: Hi',
      );
      expect(VoxVoiceEnvelope.previewText('VE3:a:1:4:4'), '🎙 Voice message');
      expect(VoxVoiceEnvelope.previewText('just text'), isNull);
    });
  });

  group('voice packet', () {
    test('encodes and parses [0x56][sid][idx][data]', () {
      final pkt = VoxVoicePacket(
        sessionId: 'deadbeef',
        index: 3,
        codecData: Uint8List.fromList([0, 1, 2, 3, 4, 5]),
      );
      expect(_toHex(pkt.encode()), '56deadbeef03000102030405');
      final back = VoxVoicePacket.tryParse(_hex('56deadbeef03000102030405'))!;
      expect(back.sessionId, 'deadbeef');
      expect(back.index, 3);
      expect(back.codecData, [0, 1, 2, 3, 4, 5]);
    });

    test('ignores other magic bytes and empty payloads', () {
      expect(VoxVoicePacket.tryParse(_hex('49deadbeef0300')), isNull);
      expect(VoxVoicePacket.tryParse(_hex('56deadbeef03')), isNull);
    });
  });

  group('fetch request', () {
    test('missing-only request sorts and dedupes indices', () {
      const req = VoxVoiceFetchRequest(
        sessionId: 'deadbeef',
        requesterKey6: 'a1b2c3d4e5f6',
        missingIndices: [4, 2, 1, 2],
      );
      expect(
        _toHex(req.encode()),
        '72deadbeef01a1b2c3d4e5f6030102'
        '04',
      );
    });

    test('send-all request has flags 0 and count 0', () {
      const req = VoxVoiceFetchRequest(
        sessionId: 'deadbeef',
        requesterKey6: 'a1b2c3d4e5f6',
      );
      expect(_toHex(req.encode()), '72deadbeef00a1b2c3d4e5f600');
      final back = VoxVoiceFetchRequest.tryParse(req.encode())!;
      expect(back.missingIndices, isNull);
      expect(back.requesterKey6, 'a1b2c3d4e5f6');
    });

    test('parses a request', () {
      final req = VoxVoiceFetchRequest.tryParse(
        _hex('72deadbeef01a1b2c3d4e5f6020104'),
      )!;
      expect(req.sessionId, 'deadbeef');
      expect(req.missingIndices, [1, 4]);
    });
  });

  group('packetize', () {
    test('1200 bps packs 26 frames (1040 ms, 156 bytes) per packet', () {
      const m = VoxVoiceMode.mode1200;
      expect(m.framesPerPacket, 26);
      expect(m.bytesPerPacket, 156);
      expect(m.packetDurationMs, 1040);
      // 10 s of 1200 bps audio = 250 frames * 6 bytes = 1500 bytes.
      final packets = voxPacketize('0000000a', Uint8List(1500), m);
      expect(packets.length, 10);
      expect(packets.last.codecData.length, 1500 - 9 * 156);
      expect(packets.every((p) => p.encode().length <= 162), isTrue);
    });
  });

  group('VR3 text request', () {
    test('matches the VR3 reference example', () {
      final req = VoxVoiceTextRequest.tryParse('VR3:00112233:a:aabbccddeeff');
      // The reference uses a 7+ char base36 sid only when needed; this one
      // is 8 chars, so it must be rejected as out of range or parsed.
      expect(req == null || req.requesterKey6 == 'aabbccddeeff', isTrue);
    });

    test('round-trips all and missing-only requests', () {
      const all = VoxVoiceFetchRequest(
        sessionId: 'deadbeef',
        requesterKey6: 'a1b2c3d4e5f6',
      );
      expect(VoxVoiceTextRequest.encode(all), 'VR3:1ps9wxb:a:a1b2c3d4e5f6');
      expect(
        VoxVoiceTextRequest.tryParse(
          VoxVoiceTextRequest.encode(all),
        )!.missingIndices,
        isNull,
      );

      const some = VoxVoiceFetchRequest(
        sessionId: 'deadbeef',
        requesterKey6: 'a1b2c3d4e5f6',
        missingIndices: [7, 1, 2, 3, 40],
      );
      final text = VoxVoiceTextRequest.encode(some);
      expect(text, 'VR3:1ps9wxb:m1-3.7.14:a1b2c3d4e5f6');
      expect(VoxVoiceTextRequest.tryParse(text)!.missingIndices, [
        1,
        2,
        3,
        7,
        40,
      ]);
    });

    test('rejects malformed requests', () {
      for (final bad in [
        'VR3:1ps9wxb:x:a1b2c3d4e5f6',
        'VR3:1ps9wxb:a:a1b2',
        'VR3:1ps9wxb:m:a1b2c3d4e5f6',
        'VR3:1ps9wxb:m3-1:a1b2c3d4e5f6',
        'VE3:a:1:4:4',
      ]) {
        expect(VoxVoiceTextRequest.tryParse(bad), isNull, reason: bad);
      }
    });
  });

  test('voice packets fit in one channel data payload', () {
    final pkts = voxPacketize('0000000a', Uint8List(1500), voxDefaultVoiceMode);
    expect(
      pkts.every((p) => p.encode().length <= voxMaxChannelDataBytes),
      isTrue,
    );
  });

  group('Mimi', () {
    test('VM1 envelope round-trips and is distinct from VE3', () {
      const env = VoxVoiceEnvelope(
        sessionId: 'deadbeef',
        mode: VoxVoiceMode.mimi,
        totalPackets: 5,
        durationSeconds: 5,
      );
      final text = env.encode();
      expect(text, 'VM1:1ps9wxb:w:5:5');
      final back = VoxVoiceEnvelope.tryParse(text)!;
      expect(back.mode, VoxVoiceMode.mimi);
      // A Mimi mode id must never be accepted inside a VE3 envelope,
      // nor a Codec2 mode inside VM1.
      expect(VoxVoiceEnvelope.tryParse('VE3:1ps9wxb:w:5:5'), isNull);
      expect(VoxVoiceEnvelope.tryParse('VM1:1ps9wxb:1:5:5'), isNull);
    });

    test('11-bit code packing round-trips', () {
      const frames = 63;
      final codes = <int>[
        for (var q = 0; q < VoxMimiSpec.codebooks; q++)
          for (var f = 0; f < VoxMimiSpec.maxFrames; f++)
            f < frames ? (q * 257 + f * 31) % 2048 : 0,
      ];
      final packed = voxPackMimiCodes(
        codes,
        frames,
        stride: VoxMimiSpec.maxFrames,
      );
      expect(packed.length, frames * 11); // 693 bytes for 5 s
      final back = voxUnpackMimiCodes(packed);
      expect(back.length, VoxMimiSpec.codebooks * VoxMimiSpec.maxFrames);
      expect(back.toList(), codes);
    });

    test('a 5 s Mimi clip fits in 5 raw packets', () {
      final pkts = voxPacketize('0000000a', Uint8List(693), VoxVoiceMode.mimi);
      expect(VoxVoiceMode.mimi.bytesPerPacket, 154); // 14 whole frames
      expect(pkts.length, 5);
      expect(pkts.every((p) => p.encode().length <= 162), isTrue);
    });
  });

  group('salted packets', () {
    test('salted packet carries the same data and differs per salt', () {
      final pkt = VoxVoicePacket(
        sessionId: 'deadbeef',
        index: 1,
        codecData: Uint8List.fromList([1, 2, 3]),
      );
      final a = pkt.encode(salt: 7);
      final b = pkt.encode(salt: 9);
      expect(_toHex(a), '57deadbeef0101020307');
      expect(_toHex(a) == _toHex(b), isFalse);
      final back = VoxVoicePacket.tryParse(a)!;
      expect(back.index, 1);
      expect(back.codecData, [1, 2, 3]);
      // Unsalted packets are unchanged (standard VE3).
      expect(_toHex(pkt.encode()), '56deadbeef01010203');
    });

    test('fetch request carries the salt-ok flag without breaking VE3', () {
      const req = VoxVoiceFetchRequest(
        sessionId: 'deadbeef',
        requesterKey6: 'a1b2c3d4e5f6',
        missingIndices: [1],
        saltOk: true,
      );
      final bytes = req.encode();
      expect(bytes[5], 0x03); // missing-only (VE3 bit 0) + salt-ok (bit 1)
      final back = VoxVoiceFetchRequest.tryParse(bytes)!;
      expect(back.saltOk, isTrue);
      expect(back.missingIndices, [1]);
      expect(
        VoxVoiceFetchRequest.tryParse(
          const VoxVoiceFetchRequest(
            sessionId: 'deadbeef',
            requesterKey6: 'a1b2c3d4e5f6',
          ).encode(),
        )!.saltOk,
        isFalse,
      );
    });

    test('salted packets still fit channel data', () {
      for (final mode in [voxDefaultVoiceMode, VoxVoiceMode.mimi]) {
        final pkts = voxPacketize('0000000a', Uint8List(3000), mode);
        expect(
          pkts.every((p) => p.encode(salt: 1).length <= voxMaxChannelDataBytes),
          isTrue,
        );
      }
    });
  });

  group('requester path', () {
    test('round-trips with missing indices and an empty (direct) path', () {
      const req = VoxVoiceFetchRequest(
        sessionId: 'deadbeef',
        requesterKey6: 'a1b2c3d4e5f6',
        missingIndices: [11],
        saltOk: true,
        requesterPath: [],
      );
      final back = VoxVoiceFetchRequest.tryParse(req.encode())!;
      expect(back.missingIndices, [11]);
      expect(back.requesterPath, isEmpty);
      expect(back.saltOk, isTrue);
    });

    test('round-trips a multi-hop path for a send-all request', () {
      const req = VoxVoiceFetchRequest(
        sessionId: 'deadbeef',
        requesterKey6: 'a1b2c3d4e5f6',
        saltOk: true,
        requesterPath: [0x19, 0x1e],
      );
      final bytes = req.encode();
      expect(bytes[5] & voxFetchFlagHasPath, voxFetchFlagHasPath);
      final back = VoxVoiceFetchRequest.tryParse(bytes)!;
      expect(back.missingIndices, isNull);
      expect(back.requesterPath, [0x19, 0x1e]);
    });

    test('requests without a path stay byte-identical to plain VE3', () {
      const req = VoxVoiceFetchRequest(
        sessionId: 'deadbeef',
        requesterKey6: 'a1b2c3d4e5f6',
      );
      expect(
        VoxVoiceFetchRequest.tryParse(req.encode())!.requesterPath,
        isNull,
      );
      expect(req.encode().length, VoxVoiceFetchRequest.minLength);
    });
  });

  group('salted fetch request', () {
    // mikecarper/MeshCore's CompanionTrafficRouting.h rawTrafficKind: how
    // that firmware decides a raw packet is a photo/voice request (and so
    // sends it on radio2 rather than the main mesh).
    bool firmwareSeesMedia(List<int> d) {
      if (d.length < 13 || d[0] != 0x72) return false;
      final flags = d[5], count = d[12];
      if ((flags & ~7) != 0 || ((flags & 1) == 0 && count != 0)) return false;
      if (count > d.length - 13) return false;
      final end = 13 + count;
      if ((flags & 4) == 0) return d.length == end;
      return d.length > end && d[end] <= 63 && d.length - end - 1 == d[end];
    }

    const req = VoxVoiceFetchRequest(
      sessionId: 'deadbeef',
      requesterKey6: 'a1b2c3d4e5f6',
      missingIndices: [61],
      saltOk: true,
    );

    test('retries for the same packet are not byte-identical', () {
      final seen = {for (var s = 0; s < 256; s++) _toHex(req.encode(salt: s))};
      expect(seen.length, greaterThanOrEqualTo(8));
      expect(seen, isNot(contains(_toHex(req.encode()))));
    });

    test('consecutive salts: 16 distinct retries for one missing packet', () {
      final c = VoxSaltCounter(Random(3));
      final seen = {
        for (var i = 0; i < 16; i++) _toHex(req.encode(salt: c.next())),
      };
      expect(seen.length, 16);
      const two = VoxVoiceFetchRequest(
        sessionId: 'deadbeef',
        requesterKey6: 'a1b2c3d4e5f6',
        missingIndices: [213, 214],
        saltOk: true,
      );
      final c2 = VoxSaltCounter(Random(9));
      final seen2 = {
        for (var i = 0; i < 32; i++) _toHex(two.encode(salt: c2.next())),
      };
      expect(seen2.length, 32);
    });

    test('same bytes as Wadamesh for the same salt', () {
      // test/test_vox_wire.cpp: {1,2,3,35} with salt 0x13 repeats 2 four times.
      const r = VoxVoiceFetchRequest(
        sessionId: '1a2b3c4d',
        requesterKey6: 'a1b2c3d4e5f6',
        missingIndices: [35, 2, 1, 3, 2],
        saltOk: true,
        requesterPath: [0xAB, 0xCD],
      );
      final got = r.encode(salt: 0x13).sublist(12);
      expect(got, [8, 1, 2, 3, 35, 2, 2, 2, 2, 2, 0xAB, 0xCD]);
    });

    test('salted requests still ask for the same packets', () {
      for (final s in [0, 7, 8, 255]) {
        final back = VoxVoiceFetchRequest.tryParse(req.encode(salt: s))!;
        expect(back.missingIndices!.toSet(), {61});
      }
      const two = VoxVoiceFetchRequest(
        sessionId: 'deadbeef',
        requesterKey6: 'a1b2c3d4e5f6',
        missingIndices: [3, 61],
        saltOk: true,
        requesterPath: [0x19, 0x1e],
      );
      final back = VoxVoiceFetchRequest.tryParse(two.encode(salt: 0xab))!;
      expect(back.missingIndices!.toSet(), {3, 61});
      expect(back.requesterPath, [0x19, 0x1e]);
    });

    test('salted requests keep the shape firmware routes as media', () {
      const withPath = VoxVoiceFetchRequest(
        sessionId: 'deadbeef',
        requesterKey6: 'a1b2c3d4e5f6',
        missingIndices: [3, 61],
        saltOk: true,
        requesterPath: [0x19, 0x1e],
      );
      for (var s = 0; s < 256; s++) {
        expect(firmwareSeesMedia(req.encode(salt: s)), isTrue);
        expect(firmwareSeesMedia(withPath.encode(salt: s)), isTrue);
      }
      const all = VoxVoiceFetchRequest(
        sessionId: 'deadbeef',
        requesterKey6: 'a1b2c3d4e5f6',
        saltOk: true,
      );
      expect(firmwareSeesMedia(all.encode(salt: 9)), isTrue);
    });

    test('a long salted request still fits one raw packet', () {
      final big = VoxVoiceFetchRequest(
        sessionId: 'deadbeef',
        requesterKey6: 'a1b2c3d4e5f6',
        missingIndices: List.generate(200, (i) => i),
        saltOk: true,
        requesterPath: List.filled(8, 1),
      );
      expect(big.encode(salt: 255).length, lessThanOrEqualTo(162));
    });
  });
}
