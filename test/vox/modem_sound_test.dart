import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/vox/modem_sound.dart';

Duration _len(Int16List s) => VoxModemSound.durationOf(s);

void main() {
  group('VoxModemSound', () {
    test('the handshake: answer tone, warble, both ways (~3.4 s)', () {
      final h = VoxModemSound.handshake();
      expect(_len(h).inMilliseconds, inInclusiveRange(3300, 3500));
      expect(h.reduce(max), lessThan(32767));
      expect(h.reduce(min), greaterThan(-32768));
    });

    test('a burst is the packet at 2400 bps, at most 0.45 s', () {
      final small = Uint8List.fromList(List.generate(30, (i) => i * 7));
      // 30 bytes = 60 symbols at 600 baud = 0.1 s.
      expect(
        _len(VoxModemSound.burst(small)).inMilliseconds,
        inInclusiveRange(95, 105),
      );
      final big = Uint8List(400);
      expect(_len(VoxModemSound.burst(big)), VoxModemSound.maxBurst);
      expect(VoxModemSound.burst(Uint8List(0)), isEmpty);
    });

    test('scrambled: even all-zero data sounds like data', () {
      // Unscrambled, zeros would be one repeated symbol: a steady tone with
      // its energy in a single narrow band. Scrambled, the level moves around.
      final s = VoxModemSound.burst(Uint8List(135));
      const win = 160; // 10 ms
      final rms = <double>[];
      for (var i = 0; i + win <= s.length; i += win) {
        var e = 0.0;
        for (var j = i; j < i + win; j++) {
          e += s[j] * s[j].toDouble();
        }
        rms.add(sqrt(e / win));
      }
      final lo = rms.sublist(2, rms.length - 2).reduce(min);
      final hi = rms.sublist(2, rms.length - 2).reduce(max);
      expect(hi / lo, greaterThan(1.3));
    });

    test('the same packet always sounds the same', () {
      final p = Uint8List.fromList(List.generate(100, (i) => (i * 31) & 0xFF));
      expect(VoxModemSound.burst(p), VoxModemSound.burst(p));
    });

    test('a WAV file: 16 kHz mono 16-bit', () {
      final w = VoxModemSound.wav(Int16List.fromList([0, 1000, -1000]));
      final bd = ByteData.sublistView(w);
      expect(String.fromCharCodes(w.sublist(0, 4)), 'RIFF');
      expect(String.fromCharCodes(w.sublist(8, 12)), 'WAVE');
      expect(bd.getUint16(22, Endian.little), 1);
      expect(bd.getUint32(24, Endian.little), VoxModemSound.sampleRate);
      expect(bd.getUint32(40, Endian.little), 6);
      expect(w.length, 44 + 6);
    });
  });

  group('VoxModemPlayer', () {
    Duration wavLen(Uint8List w) =>
        Duration(microseconds: (w.length - 44) ~/ 2 * 1000000 ~/ 16000);

    // A hand-run clock: each sound's end is a callback the test fires.
    late List<void Function()> ends;
    Timer clock(Duration d, void Function() f) {
      ends.add(f);
      return Timer(Duration.zero, () {})..cancel();
    }

    void endSound() => ends.removeAt(0)();

    setUp(() => ends = []);

    test('handshake once per video, then a burst a packet, in turn', () {
      final played = <Duration>[];
      final p = VoxModemPlayer(
        play: (w) async => played.add(wavLen(w)),
        after: clock,
      );
      final pkt = Uint8List(200);
      p.onVideoPacket('a', pkt);
      // The handshake and the first burst play as one sound.
      expect(played, hasLength(1));
      expect(played.single.inMilliseconds, inInclusiveRange(3750, 3950));
      p.onVideoPacket('a', pkt); // waits for the first to end
      expect(played, hasLength(1));
      endSound();
      expect(played, hasLength(2));
      expect(played.last, VoxModemSound.maxBurst);
      endSound();
      // Another video gets its own handshake.
      p.onVideoPacket('b', pkt);
      expect(played.last.inMilliseconds, greaterThan(3700));
      // The same one doesn't.
      endSound();
      p.onVideoPacket('b', pkt);
      expect(played.last, VoxModemSound.maxBurst);
    });

    test('never falls behind: bursts past the backlog are dropped', () {
      final played = <Duration>[];
      final p = VoxModemPlayer(
        play: (w) async => played.add(wavLen(w)),
        maxBacklog: const Duration(seconds: 1),
        after: clock,
      );
      final pkt = Uint8List(200);
      p.onVideoPacket('a', pkt); // playing ~3.8 s
      for (var i = 0; i < 20; i++) {
        p.onVideoPacket('a', pkt); // 0.45 s each, while it plays
      }
      endSound();
      // Only enough to pass the 1 s backlog was kept: 3 x 0.45 s.
      expect(played, hasLength(2));
      expect(played.last.inMilliseconds, 3 * 450);
    });

    test('clear() drops what is waiting', () {
      final played = <Duration>[];
      final p = VoxModemPlayer(
        play: (w) async => played.add(wavLen(w)),
        after: clock,
      );
      p.onVideoPacket('a', Uint8List(200));
      p.onVideoPacket('a', Uint8List(200));
      p.clear();
      p.onVideoPacket('a', Uint8List(200));
      expect(played, hasLength(2));
      expect(played.last, VoxModemSound.maxBurst);
    });
  });
}
