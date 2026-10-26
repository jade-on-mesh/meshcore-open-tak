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

  test('fetch budgets grow with size and with how much is in', () {
    expect(voxAttemptBudget(17), voxMaxAttempts);
    expect(voxAttemptBudget(234), 49);
    expect(voxStallBudget(0, 234), voxMaxStalls);
    expect(voxStallBudget(60, 234), voxMaxStalls);
    expect(voxStallBudget(120, 234), 5);
    expect(voxStallBudget(233, 234), 8);
    expect(voxStallBudget(14, 17), 8);
    const w = Duration(seconds: 10);
    expect(voxStallBackoff(w, 0), w);
    expect(voxStallBackoff(w, 1), const Duration(seconds: 15));
    expect(voxStallBackoff(w, 4), const Duration(seconds: 30));
    expect(voxStallBackoff(w, 5), const Duration(seconds: 45));
    expect(voxStallBackoff(w, 9), const Duration(microseconds: 227812500));
    expect(voxStallBackoff(w, 12), voxStallBackoffCap);
  });

  test('flooded channel answers wait and pace by the hops to the listener', () {
    // MediaMesh 250 kHz: 157 ms a packet; a relay is 157 + 2.5 * 180.55.
    expect(voxRelayMs(157), 608);
    expect(voxFloodGapMs(157, 0), 800);
    expect(voxFloodGapMs(157, 1), 800);
    expect(voxFloodGapMs(157, 4), 1600); // capped at twice
    expect(voxFloodSettleMs(157, 0), 0);
    expect(voxFloodSettleMs(157, 4), 4 * 608);
    expect(voxFloodSettleMs(157, 9), 4 * 608);
    // The main mesh's slower packets: the same as Wadamesh's host test.
    expect(voxFloodGapMs(500, 1), 2150);
    expect(voxFloodGapMs(500, 4), 4300);
    expect(voxFloodSettleMs(500, 1), 1938);
  });
}
