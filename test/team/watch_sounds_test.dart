import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/team/watch_sounds.dart';

void main() {
  test('every sound is a short, valid, distinct WAV', () {
    final seen = <String>{};
    for (final s in WatchSound.values.where((s) => s != WatchSound.off)) {
      final w = s.wav();
      final d = ByteData.sublistView(w);
      expect(String.fromCharCodes(w.sublist(0, 4)), 'RIFF');
      expect(String.fromCharCodes(w.sublist(8, 12)), 'WAVE');
      expect(d.getUint32(40, Endian.little), w.length - 44);
      final seconds = (w.length - 44) / 2 / d.getUint32(24, Endian.little);
      expect(seconds, inInclusiveRange(0.2, 1.0), reason: s.label);
      var peak = 0;
      for (var i = 44; i < w.length; i += 2) {
        final v = d.getInt16(i, Endian.little).abs();
        if (v > peak) peak = v;
      }
      expect(peak, greaterThan(8000), reason: '${s.label} is audible');
      expect(seen.add(w.length.toString() + w.sublist(44, 2044).join()), isTrue);
    }
  });

  test('names round-trip; unknown is off', () {
    for (final s in WatchSound.values) {
      expect(WatchSound.fromName(s.name), s);
    }
    expect(WatchSound.fromName('gone'), WatchSound.off);
    expect(WatchSound.fromName(null), WatchSound.off);
    expect(WatchSound.off.wav().length, 44);
  });
}
