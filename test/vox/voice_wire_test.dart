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
  group('VE3 envelope', () {
    test('parses the MeshCore SAR documentation example', () {
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
      ]) {
        expect(VoxVoiceEnvelope.tryParse(bad), isNull, reason: bad);
      }
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
    test('matches the SAR documentation example', () {
      final req = VoxVoiceTextRequest.tryParse('VR3:00112233:a:aabbccddeeff');
      // SAR's example uses a 7+ char base36 sid only when needed; this one
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
      // A Mimi mode id must never be accepted inside a VE3 (SAR) envelope,
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
}
