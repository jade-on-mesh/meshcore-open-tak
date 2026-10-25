import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/vox/vox_gaps.dart';
import 'package:meshcore_open/vox/voice_wire.dart';

void main() {
  const m = VoxVoiceMode.mode1200; // 156-byte packets, 26 frames of 320 samples
  Uint8List pk(int v, [int n = 156]) => Uint8List(n)..fillRange(0, n, v);

  test('runs of packets here, a packet of silence for each missing', () {
    final present = {0: pk(1), 1: pk(2), 3: pk(4), 4: pk(5, 60)};
    final plan = voxGapPlan(present, 6, m);
    expect(plan.length, 4);
    expect(plan[0].bits!.length, 312); // packets 0-1
    expect(plan[1].silenceSamples, 26 * 320); // packet 2
    expect(plan[2].bits!.length, 156 + 60); // packets 3-4
    expect(plan[3].silenceSamples, 26 * 320); // packet 5, the last
    expect(plan[2].bits![0], 4);
  });

  test('when a clip can play with gaps', () {
    expect(voxCanPlayPartial(m, 10, 11), isTrue); // 91%
    expect(voxCanPlayPartial(m, 9, 11), isTrue); // 82%
    expect(voxCanPlayPartial(m, 8, 11), isFalse); // 73%
    expect(voxCanPlayPartial(m, 11, 11), isFalse); // complete: plays whole
    expect(voxCanPlayPartial(m, 1, 1), isFalse);
    expect(voxCanPlayPartial(VoxVoiceMode.mimi, 10, 11), isFalse);
    expect(voxCanPlayPartial(VoxVoiceMode.av1Image, 200, 210), isFalse);
  });
}
