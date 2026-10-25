import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/vox/voice_dsp.dart';
import 'package:meshcore_open/vox/vox_voice_enhance.dart';

void main() {
  test('input is levelled like plain playback and padded to the minimum', () {
    final pcm = Int16List.fromList([0, 1000, -2000, 500]);
    final x = voxEnhanceInput(pcm);
    expect(x.length, VoxVoiceEnhanceModel.minSamples);
    final g = voxPlayNormGain(2000) / 32768.0;
    expect(x[1], closeTo(1000 * g, 1e-6));
    expect(x[2], closeTo(-2000 * g, 1e-6));
    expect(x.sublist(4).every((v) => v == 0), isTrue);
    final long = voxEnhanceInput(Int16List(5000));
    expect(long.length, 5000);
  });

  test('only the first 3 s set the level', () {
    final pcm = Int16List(4 * voxCodecRate);
    pcm[10] = 4000;
    pcm[3 * voxCodecRate + 5] = 30000; // after 3 s: ignored
    final x = voxEnhanceInput(pcm);
    expect(x[10], closeTo(4000 * voxPlayNormGain(4000) / 32768.0, 1e-6));
  });

  test('output is trimmed to 6x the input and soft-limited', () {
    final y = List<num>.generate(6 * 256, (i) => i == 0 ? 2.0 : 0.25);
    final out = voxEnhanceOutput(y, 100);
    expect(out.length, 600);
    expect(out[0], voxSoftLimit(65536).round());
    expect(out[0], lessThanOrEqualTo(32000));
    expect(out[1], 8192);
    expect(VoxVoiceEnhanceModel.outRate, 48000);
  });
}
