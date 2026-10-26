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

  test('stall wait is three gaps and a second', () {
    expect(
      voxStallWait(const Duration(milliseconds: 800)),
      const Duration(milliseconds: 3400),
    );
  });

  test('the wait for an answer is short on MediaMesh, as before elsewhere', () {
    // MediaMesh 250 kHz (157 ms): a hop is 1014 ms.
    expect(voxAnswerWaitMs(trips: 3, hops: 0, airMs: 157, channel: true), 4528);
    expect(
      voxAnswerWaitMs(trips: 3, hops: 1, airMs: 157, channel: true),
      2 * 2 * 1014 + 2500 + 4 * 608,
    );
    expect(voxAnswerWaitMs(trips: 2, hops: 0, airMs: 157), 2 * 1014 + 2500);
    expect(
      voxAnswerWaitMs(trips: 2, hops: 0, airMs: 157, zeroHop: true),
      2 * 1014 + 3500,
    );
    // The main mesh's slow packets (1200 ms): unchanged.
    expect(
      voxAnswerWaitMs(trips: 3, hops: 1, airMs: 1200, channel: true),
      3 * 2 * 3100 + 8000,
    );
    expect(
      voxAnswerWaitMs(trips: 2, hops: 0, airMs: 1200, zeroHop: true),
      2 * 3100 + 6000,
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

  test('flooded answers start fast and learn from the requests after them', () {
    // MediaMesh 250 kHz: 157 ms a packet; a relay is 157 + 2.5 * 180.55.
    expect(voxRelayMs(157), 608);
    final p = VoxFloodPace(157);
    expect(p.gapMs(0), 778);
    expect(p.gapMs(1), 778);
    expect(p.gapMs(20), 922); // two relays' clearing time, on average
    expect(p.settleMs(0), 0); // heard direct: answer at once
    expect(p.settleMs(1), 608);
    expect(p.settleMs(20), 2 * 608); // relays far from us don't matter

    // An answer that lost most, its first packet among them: slower, and
    // one more relay of waiting.
    final a = VoxFloodAnswer([1, 4, 5, 7, 8, 9]);
    p.feedback(a, {1, 4, 5, 8, 9});
    expect(p.gapMs(4), 1167);
    expect(p.settleMs(4), 3 * 608);
    // Another listener saying the same about that answer moves nothing more.
    p.feedback(a, {1, 4, 5, 8, 9});
    expect(p.gapMs(4), 1167);
    expect(p.settleMs(4), 3 * 608);
    // One who got nearly all of it: the pace was fine, its loss was the
    // others' links. The slowing is undone and the pace speeds up.
    p.feedback(a, {});
    expect(p.gapMs(4), 922);
    expect(p.gapMs(0), 778);
    expect(p.settleMs(4), 2 * 608);
    // ...and after that, no report on that answer slows it.
    p.feedback(a, {1, 4, 5, 7, 8, 9});
    expect(p.gapMs(4), 922);

    // A congested mesh: answer after answer loses half. The gap grows to at
    // most twice the base, the wait to four relays.
    for (var k = 0; k < 6; k++) {
      p.feedback(VoxFloodAnswer([0, 1, 2, 3]), {0, 2, 3});
    }
    expect(p.gapMs(4), 1556);
    expect(p.settleMs(4), 4 * 608);
    // Then it clears: back to fast within a few answers.
    for (var k = 0; k < 6; k++) {
      p.feedback(VoxFloodAnswer([0, 1, 2, 3]), {});
    }
    expect(p.gapMs(4), 922);
    expect(p.settleMs(4), 2 * 608);

    // The main mesh's slower packets: the same numbers as Wadamesh's test.
    final m = VoxFloodPace(500);
    expect(m.gapMs(1), 2150);
    expect(m.gapMs(4), 2938);
    expect(m.settleMs(1), 1938);
    expect(voxFloodSlowGapMs(500), 4300);
  });
}
