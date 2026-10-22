import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/vox/voice_wire.dart';
import 'package:meshcore_open/vox/walkie_wire.dart';

String hex(List<int> b) =>
    b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();

Uint8List unhex(String s) => Uint8List.fromList([
  for (var i = 0; i < s.length; i += 2)
    int.parse(s.substring(i, i + 2), radix: 16),
]);

void main() {
  // The same bytes are checked by Wadamesh TAK's test/test_walkie.cpp.
  group('wire (golden bytes shared with Wadamesh TAK)', () {
    test('talk start', () {
      final s = const WalkieStart(sessionId: '1a2b3c4d', name: 'Alex');
      expect(hex(s.encode()), '531a2b3c4d01416c6578');
      final back = WalkieStart.tryParse(unhex('531a2b3c4d01416c6578'))!;
      expect(back.sessionId, '1a2b3c4d');
      expect(back.name, 'Alex');
      expect(back.mode, VoxVoiceMode.mode1200);
    });

    test('talk audio', () {
      final a = WalkieAudio(
        sessionId: '1a2b3c4d',
        index: 3,
        last: true,
        codecData: Uint8List.fromList(List.generate(12, (i) => i)),
      );
      expect(hex(a.encode()), '541a2b3c4d0381000102030405060708090a0b');
      final b = WalkieAudio.tryParse(
        unhex('541a2b3c4d0381000102030405060708090a0b'),
      )!;
      expect(b.index, 3);
      expect(b.last, isTrue);
      expect(b.codecData.length, 12);
      expect(b.totalIfLast, 4);
      expect(b.duration, const Duration(milliseconds: 80));

      final end = WalkieAudio.tryParse(unhex('541a2b3c4d0581'))!;
      expect(end.last, isTrue);
      expect(end.codecData, isEmpty);
      expect(end.totalIfLast, 5);
    });

    test('rejects what is not a talk', () {
      expect(WalkieAudio.tryParse(unhex('541a2b3c4d00')), isNull); // short
      expect(WalkieAudio.tryParse(unhex('541a2b3c4d00010001')), isNull); // half frame
      expect(WalkieAudio.tryParse(unhex('541a2b3c4d0020000102030405')), isNull); // Mimi
      expect(WalkieStart.tryParse(unhex('531a2b3c4d28')), isNull); // AV1 image
      expect(walkieIsLivePayload(unhex('561a2b3c4d00')), isFalse);
    });

    test('a full packet is VE3 packet size and fits a channel datagram', () {
      final full = WalkieAudio(
        sessionId: '1a2b3c4d',
        index: 0,
        codecData: Uint8List(walkieMode.bytesPerPacket),
      ).encode();
      expect(walkieMode.bytesPerPacket, 156);
      expect(full.length, voxMaxChannelDataBytes);
    });

    test('long names are cut on a character boundary', () {
      final s = WalkieStart(sessionId: '00000001', name: 'é' * 40).encode();
      expect(s.length, 6 + 32);
      expect(WalkieStart.tryParse(s)!.name, 'é' * 16);
    });
  });

  test('packetizer matches the voice message packets', () {
    final p = WalkiePacketizer('0badf00d');
    final rng = Random(7);
    final all = <int>[];
    final sent = <WalkieAudio>[];
    // 2.5 s of Codec2 1200 in uneven chunks.
    for (var i = 0; i < 62; i++) {
      final f = Uint8List.fromList(List.generate(6, (_) => rng.nextInt(256)));
      all.addAll(f);
      sent.addAll(p.add(f));
    }
    expect(sent.map((a) => a.index), [0, 1]);
    final last = p.finish();
    expect(last.last, isTrue);
    expect(last.index, 2);
    expect(last.codecData.length, 62 * 6 - 2 * 156);
    expect(p.bits, all);
    final ve3 = voxPacketize('0badf00d', Uint8List.fromList(all), walkieMode);
    for (final a in [...sent, last]) {
      expect(a.codecData, ve3[a.index].codecData);
    }

    // Ending on a packet boundary: an empty "end" packet.
    final q = WalkiePacketizer('0badf00e');
    expect(q.add(Uint8List(156)).length, 1);
    final end = q.finish();
    expect(end.index, 1);
    expect(end.codecData, isEmpty);
    expect(end.totalIfLast, 1);
  });

  group('jitter', () {
    final t0 = DateTime(2026, 10, 21, 12);
    DateTime at(int ms) => t0.add(Duration(milliseconds: ms));
    WalkieAudio pkt(int i, {bool last = false, int bytes = 156}) => WalkieAudio(
      sessionId: '00000001',
      index: i,
      last: last,
      codecData: Uint8List(bytes)..fillRange(0, bytes, i),
    );

    test('waits a little, then plays in order', () {
      final j = WalkieJitter();
      j.add(pkt(0), at(0));
      expect(j.due(at(100)), isEmpty);
      expect(j.due(at(500)).length, 1);
      j.add(pkt(1), at(1100));
      expect(j.due(at(1100)).single.first, 1);
      j.add(pkt(2, last: true, bytes: 60), at(2150));
      expect(j.due(at(2150)).single.length, 60);
      expect(j.finished(at(2150)), isTrue);
    });

    test('starts at once with two packets in', () {
      final j = WalkieJitter();
      j.add(pkt(0), at(0));
      j.add(pkt(1), at(50));
      expect(j.due(at(60)).length, 2);
    });

    test('skips a lost packet once it is too late', () {
      final j = WalkieJitter();
      j.add(pkt(0), at(0));
      j.add(pkt(1), at(10));
      expect(j.due(at(10)).length, 2); // plays until 10 + 2080 ms
      j.add(pkt(3), at(2100));
      expect(j.due(at(2200)), isEmpty); // 2 may still come
      final out = j.due(at(2500)); // past the grace: skip 2
      expect(out.single.first, 3);
      expect(j.nextIndex, 4);
    });

    test('a late packet already skipped is ignored', () {
      final j = WalkieJitter();
      j.add(pkt(0), at(0));
      j.add(pkt(2), at(10));
      j.due(at(10));
      j.due(at(1500)); // skips 1, plays 2
      j.add(pkt(1), at(1600));
      expect(j.due(at(1600)), isEmpty);
    });

    test('a talk whose first packet was lost starts at the next', () {
      final j = WalkieJitter();
      j.add(pkt(1), at(0));
      expect(j.due(at(600)).single.first, 1);
    });

    test('a talk that goes quiet ends', () {
      final j = WalkieJitter();
      j.add(pkt(0), at(0));
      j.due(at(600));
      expect(j.finished(at(2000)), isFalse);
      expect(j.finished(at(5000)), isTrue);
    });
  });

  test('decimator keeps a tone and drops what is above 4 kHz', () {
    double rms(Int16List x) {
      var s = 0.0;
      for (final v in x.skip(32)) {
        s += v * v.toDouble();
      }
      return sqrt(s / (x.length - 32));
    }

    Int16List tone(double hz) => Int16List.fromList([
      for (var i = 0; i < 48000; i++)
        (10000 * sin(2 * pi * hz * i / 48000)).round(),
    ]);
    // Fed in odd-sized chunks, as the mic stream does.
    Int16List run(Int16List x) {
      final d = WalkieDecimator();
      final out = <int>[];
      for (var i = 0; i < x.length; i += 1234) {
        out.addAll(d.process(Int16List.sublistView(x, i, min(i + 1234, x.length))));
      }
      return Int16List.fromList(out);
    }

    final low = run(tone(1000));
    expect(low.length, 8000);
    expect(rms(low), closeTo(10000 / sqrt2, 400));
    expect(rms(run(tone(6000))), lessThan(300));
  });

  group('talk marker and waveform', () {
    test('a talk is announced with the PTT caption', () {
      const env = VoxVoiceEnvelope(
        sessionId: '1a2b3c4d',
        mode: VoxVoiceMode.mode1200,
        totalPackets: 3,
        durationSeconds: 3,
        caption: walkieTalkCaption,
      );
      final text = env.encode();
      expect(text, endsWith(' PTT'));
      final back = VoxVoiceEnvelope.tryParse(text)!;
      expect(back.isTalk, isTrue);
      final plain = VoxVoiceEnvelope.tryParse(text.replaceAll(' PTT', ''))!;
      expect(plain.isTalk, isFalse);
    });

    test('loud then quiet', () {
      final pcm = Int16List(8000);
      for (var i = 0; i < 4000; i++) {
        pcm[i] = (sin(i / 3) * 12000).round();
      }
      for (var i = 4000; i < 8000; i++) {
        pcm[i] = (sin(i / 3) * 300).round();
      }
      final w = voxWaveform(pcm);
      expect(w.length, voxWaveBars);
      expect(w.first, closeTo(1, 0.05));
      expect(w.last, lessThan(0.3));
      expect(w.every((v) => v >= 0 && v <= 1), isTrue);
    });

    test('silence is flat', () {
      expect(voxWaveform(Int16List(800)).every((v) => v == 0), isTrue);
      expect(voxWaveform(Int16List(0)).length, voxWaveBars);
    });
  });
}
