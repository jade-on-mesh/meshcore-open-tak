import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/vox/vox_timing.dart';

void main() {
  test('push lead follows the announcement airtime, within bounds', () {
    expect(voxPushLead(null), const Duration(milliseconds: 1500));
    expect(
      voxPushLead(const Duration(milliseconds: 100)),
      const Duration(milliseconds: 700),
    );
    expect(
      voxPushLead(const Duration(milliseconds: 450)),
      const Duration(milliseconds: 950),
    );
    expect(
      voxPushLead(const Duration(seconds: 2)),
      const Duration(milliseconds: 1500),
    );
  });

  test('gap request waits less when nothing was relayed', () {
    const gap = Duration(milliseconds: 800);
    const zero = Duration(milliseconds: 210);
    expect(
      voxGapRequestDelay(relayed: false, packetGap: gap, zeroHopGap: zero),
      const Duration(milliseconds: 610),
    );
    expect(
      voxGapRequestDelay(relayed: true, packetGap: gap, zeroHopGap: zero),
      const Duration(milliseconds: 1800),
    );
  });

  test('stall wait is three gaps and a margin', () {
    expect(
      voxStallWait(const Duration(milliseconds: 800)),
      const Duration(milliseconds: 4900),
    );
  });

  test('passive finish needs half the packets', () {
    expect(voxShouldFinishPassive(received: 18, total: 36), isTrue);
    expect(voxShouldFinishPassive(received: 17, total: 36), isFalse);
    expect(voxShouldFinishPassive(received: 36, total: 36), isFalse);
    expect(voxShouldFinishPassive(received: 0, total: 0), isFalse);
  });

  test('burst gap follows the gaps packets came at, within the model', () {
    const model = Duration(milliseconds: 2725);
    const floor = Duration(milliseconds: 160);
    // Too few gaps measured: the model.
    expect(
      voxBurstGap(
        model: model,
        seen: const Duration(milliseconds: 350),
        samples: 2,
        floor: floor,
      ),
      model,
    );
    // Coming faster than the model: twice what they came at.
    expect(
      voxBurstGap(
        model: model,
        seen: const Duration(milliseconds: 350),
        samples: 5,
        floor: floor,
      ),
      const Duration(milliseconds: 700),
    );
    // Never above the model, never under the floor.
    expect(
      voxBurstGap(
        model: model,
        seen: const Duration(milliseconds: 2000),
        samples: 5,
        floor: floor,
      ),
      model,
    );
    expect(
      voxBurstGap(
        model: model,
        seen: const Duration(milliseconds: 40),
        samples: 5,
        floor: floor,
      ),
      floor,
    );
  });

  test('MediaMesh listen before talk', () {
    for (var r = 0; r < 200; r++) {
      final q = voxLbtQuietMs(120, r * 7919);
      expect(q, inInclusiveRange(170, 230));
    }
    expect(voxLbtQuietMs(0, 0), greaterThanOrEqualTo(150));
    expect(voxLbtHold(sinceHeardMs: null, quietMs: 200, waitedMs: 0), isFalse);
    expect(voxLbtHold(sinceHeardMs: 50, quietMs: 200, waitedMs: 0), isTrue);
    expect(voxLbtHold(sinceHeardMs: 200, quietMs: 200, waitedMs: 0), isFalse);
    expect(
      voxLbtHold(sinceHeardMs: 10, quietMs: 200, waitedMs: voxLbtMaxWaitMs),
      isFalse,
    );
  });
}
