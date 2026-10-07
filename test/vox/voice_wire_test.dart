import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/vox/voice_wire.dart';

Uint8List _hex(String h) => Uint8List.fromList([
  for (var i = 0; i < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16),
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
      expect(_toHex(req.encode()), '72deadbeef01a1b2c3d4e5f6030102' '04');
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
}
