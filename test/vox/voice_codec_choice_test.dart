import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/vox/voice_codec_choice.dart';
import 'package:meshcore_open/vox/voice_wire.dart';

void main() {
  final t0 = DateTime.utc(2026, 10, 14, 9);
  DateTime at(Duration d) => t0.add(d);
  const dm =
      'c:aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899';
  const ch = 'ch:0123456789abcdef0123456789abcdef';

  group('receiving tells the codecs apart', () {
    // What a Wadamesh radio posts (src/ui-touch/VoxWire.h encodeVoiceEnvelope).
    test('a Wadamesh clip is Codec2 1200, a VOX Mimi clip is Mimi', () {
      final radio = VoxVoiceEnvelope.tryParse('VE3:2sbggd:1:a:a')!;
      expect(radio.mode, VoxVoiceMode.mode1200);
      expect(radio.mode.isCodec2, isTrue);
      expect(radio.totalPackets, 10);
      expect(radio.durationSeconds, 10);
      final mimi = VoxVoiceEnvelope.tryParse('VM1:2sbggd:w:a:a')!;
      expect(mimi.mode.isMimi, isTrue);
      // A Mimi mode id under the Codec2 prefix is refused, and vice versa.
      expect(VoxVoiceEnvelope.tryParse('VE3:2sbggd:w:a:a'), isNull);
      expect(VoxVoiceEnvelope.tryParse('VM1:2sbggd:1:a:a'), isNull);
    });
  });

  group('DMs reply in kind', () {
    test('nothing heard: the default codec', () {
      final c = VoxCodecChoice();
      expect(c.forcesCodec2(dm, now: t0), isFalse);
      expect(c.forcesCodec2(null, now: t0), isFalse);
    });

    test('a Codec2 clip from a contact switches replies to Codec2', () {
      final c = VoxCodecChoice();
      final changed = c.learn(dm, mimi: false, at: t0, now: t0);
      expect(changed, isTrue);
      expect(c.autoCodec2(dm, now: t0), isTrue);
      expect(c.forcesCodec2(dm, now: t0), isTrue);
      expect(c.manualCodec2(dm), isFalse);
    });

    test('a later Mimi clip switches back, a later Codec2 clip again', () {
      final c = VoxCodecChoice();
      c.learn(dm, mimi: false, at: t0, now: t0);
      c.learn(dm, mimi: true, at: at(const Duration(minutes: 5)), now: t0);
      expect(c.forcesCodec2(dm, now: t0), isFalse);
      c.learn(dm, mimi: false, at: at(const Duration(minutes: 9)), now: t0);
      expect(c.forcesCodec2(dm, now: t0), isTrue);
    });

    test('an older clip synced late does not override a newer one', () {
      final c = VoxCodecChoice();
      c.learn(dm, mimi: true, at: at(const Duration(hours: 2)), now: t0);
      c.learn(dm, mimi: false, at: at(const Duration(hours: 1)), now: t0);
      expect(c.forcesCodec2(dm, now: t0), isFalse);
    });

    test('a DM stays on Codec2 however long ago they sent it', () {
      final c = VoxCodecChoice();
      c.learn(dm, mimi: false, at: t0, now: t0);
      expect(c.forcesCodec2(dm, now: at(const Duration(days: 90))), isTrue);
    });
  });

  group('channels', () {
    test('Codec2 heard in the last two weeks keeps the channel on Codec2', () {
      final c = VoxCodecChoice();
      c.learn(ch, mimi: false, at: t0, now: t0);
      c.learn(ch, mimi: true, at: at(const Duration(minutes: 1)), now: t0);
      // A Mimi clip from someone else doesn't switch it off: the radio user is
      // still on the channel.
      expect(c.forcesCodec2(ch, now: at(const Duration(days: 13))), isTrue);
      expect(c.forcesCodec2(ch, now: at(const Duration(days: 15))), isFalse);
    });
  });

  group('the per-chat switch', () {
    test('on forces Codec2 with nothing heard', () {
      final c = VoxCodecChoice();
      expect(c.setManual(dm, true, now: t0), isTrue);
      expect(c.forcesCodec2(dm, now: t0), isTrue);
      expect(c.manualCodec2(dm), isTrue);
    });

    test('off against the automatic choice sticks', () {
      final c = VoxCodecChoice();
      c.learn(dm, mimi: false, at: t0, now: t0);
      c.setManual(dm, false, now: t0);
      expect(c.manualMimi(dm), isTrue);
      expect(c.forcesCodec2(dm, now: t0), isFalse);
      // Another Codec2 clip doesn't flip it back on.
      c.learn(dm, mimi: false, at: at(const Duration(minutes: 1)), now: t0);
      expect(c.forcesCodec2(dm, now: t0), isFalse);
      // Switching it on again clears the override.
      c.setManual(dm, true, now: t0);
      expect(c.manualMimi(dm), isFalse);
      expect(c.forcesCodec2(dm, now: t0), isTrue);
    });

    test('off with nothing automatic leaves no override behind', () {
      final c = VoxCodecChoice();
      c.setManual(dm, true, now: t0);
      c.setManual(dm, false, now: t0);
      expect(c.manualCodec2(dm), isFalse);
      expect(c.manualMimi(dm), isFalse);
      // So a later Codec2 clip can still switch it on automatically.
      c.learn(dm, mimi: false, at: t0, now: t0);
      expect(c.forcesCodec2(dm, now: t0), isTrue);
    });

    test('setManual reports no change when nothing changed', () {
      final c = VoxCodecChoice();
      expect(c.setManual(dm, false, now: t0), isFalse);
      c.setManual(dm, true, now: t0);
      expect(c.setManual(dm, true, now: t0), isFalse);
    });
  });

  group('persistence', () {
    test('round-trips through the saved form', () {
      final a = VoxCodecChoice();
      a.learn(dm, mimi: false, at: t0, now: t0);
      a.learn(ch, mimi: true, at: t0, now: t0);
      a.setManual(ch, true, now: t0);
      final b = VoxCodecChoice()
        ..load(
          codec2: a.manualCodec2Targets,
          mimi: a.manualMimiTargets,
          heardJson: a.heardJson(),
        );
      expect(b.forcesCodec2(dm, now: t0), isTrue);
      expect(b.manualCodec2(ch), isTrue);
      expect(b.autoCodec2(ch, now: t0), isFalse);
    });

    test('damaged saved data is ignored, not fatal', () {
      final c = VoxCodecChoice()
        ..load(heardJson: '{"c:x": [1, "two"], "c:y": 7, "c:z": [5, null]');
      expect(c.forcesCodec2('c:z', now: t0), isFalse); // whole blob unreadable
      final d = VoxCodecChoice()
        ..load(heardJson: '{"c:x": [1, "two"], "c:y": 7, "c:z": [5, null]}');
      expect(d.autoCodec2('c:x', now: t0), isFalse);
      expect(d.autoCodec2('c:y', now: t0), isFalse);
      expect(d.autoCodec2('c:z', now: t0), isTrue);
    });

    test('remembers a bounded number of chats, oldest dropped', () {
      final c = VoxCodecChoice();
      for (var i = 0; i < VoxCodecChoice.maxRemembered + 5; i++) {
        c.learn('c:$i', mimi: false, at: t0, now: t0);
      }
      expect(c.autoCodec2('c:0', now: t0), isFalse);
      expect(
        c.autoCodec2('c:${VoxCodecChoice.maxRemembered + 4}', now: t0),
        isTrue,
      );
    });
  });
}
