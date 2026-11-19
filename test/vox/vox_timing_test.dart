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

  test('burst gap follows the gaps packets came at, up to 3x the model', () {
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
    // Coming slower (a sender with a longer preamble): waited for, up to
    // three times the model; never under the floor.
    expect(
      voxBurstGap(
        model: model,
        seen: const Duration(milliseconds: 2000),
        samples: 5,
        floor: floor,
      ),
      const Duration(milliseconds: 4000),
    );
    expect(
      voxBurstGap(model: model, seen: model * 5, samples: 5, floor: floor),
      model * 3,
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

  test('a marked packet: ask at once when none are left, else after them', () {
    expect(voxMarkedWaitMs(0, 900), 300);
    expect(voxMarkedWaitMs(1, 900), 2 * 900 + 450);
    expect(voxMarkedWaitMs(3, 600), 4 * 600 + 400);
    // A lost last packet is asked for sooner than the stall wait.
    expect(
      voxMarkedWaitMs(1, 900),
      lessThan(voxStallWait(const Duration(milliseconds: 900)).inMilliseconds),
    );
  });

  test('a marked answer that stops part-way is asked again within a stall', () {
    // The sender said ~100 more were coming, then its burst stopped: wait a
    // stall (three gaps and a second), not 101 gaps.
    final stall = voxStallWait(const Duration(milliseconds: 2100));
    expect(voxMarkedStallWaitMs(100, 2100), stall.inMilliseconds);
    expect(voxMarkedWaitMs(100, 2100), greaterThan(200000));
    // A short tail keeps its own, shorter wait; the end of an answer is 300.
    expect(voxMarkedStallWaitMs(1, 900), voxMarkedWaitMs(1, 900));
    expect(voxMarkedStallWaitMs(0, 900), 300);
  });

  test('a burst carries on through a few slow confirmations', () {
    expect(voxSlowConfirmsMax, greaterThanOrEqualTo(3));
    // In all, at most about the listen-before-talk limit.
    expect(
      voxSlowConfirmsMax * (5000 + voxSlowConfirmPause.inMilliseconds),
      lessThanOrEqualTo(voxLbtMaxWaitMs + 5000),
    );
  });

  test('a request with no answer yet holds while the clip is on the air', () {
    final quiet = voxAirQuietMs(220);
    expect(quiet, 2000);
    expect(voxAirQuietMs(700), 2800);
    // Heard 1 s ago, asked 8 s ago: wait for quiet and a holder's lead.
    expect(
      voxAirHoldMs(sinceHeardMs: 1000, sinceAskedMs: 8000, quietMs: quiet),
      quiet + voxHolderAnswerLeadMs - 1000,
    );
    // Quiet long enough: ask now.
    expect(
      voxAirHoldMs(sinceHeardMs: 6000, sinceAskedMs: 8000, quietMs: quiet),
      isNull,
    );
    // Past anything a holder waits: ask now, busy or not.
    expect(
      voxAirHoldMs(sinceHeardMs: 500, sinceAskedMs: 26000, quietMs: quiet),
      isNull,
    );
  });

  group('adaptive spacing', () {
    VoxFloodAnswer answer(int gap) =>
        VoxFloodAnswer(List<int>.generate(100, (i) => i), gapMs: gap);
    Set<int> lose(int n) => {for (var i = 0; i < n; i++) i};
    VoxFloodPace pace() => VoxFloodPace(153, fast: true)..adaptive = true;

    test('starts at the fast gap; off is the gap as it was', () {
      final off = VoxFloodPace(153, fast: true);
      expect(off.gapMs(0), 517);
      expect(pace().gapMs(0), 517);
      expect(pace().gapMs(5), 517);
      for (var k = 0; k < 5; k++) {
        off.feedback(answer(517), lose(0), who: 'a', nowMs: 0);
      }
      expect(off.gapMs(0), 517);
    });

    test('clean answers take it down a tenth at a time to the floor', () {
      final p = pace();
      expect(voxFloodAdaptiveFloorMs(153), 395);
      expect(p.feedback(answer(517), lose(1), who: 'a', nowMs: 0), isTrue);
      expect(p.gapMs(0, nowMs: 0), 465);
      for (var k = 0; k < 5; k++) {
        p.feedback(answer(p.gapMs(0)), lose(1), who: 'a', nowMs: 0);
      }
      // The same for any hop count: hops don't decide it.
      expect(p.gapMs(0, nowMs: 0), 395);
      expect(p.gapMs(4, nowMs: 0), 395);
    });

    test('a loss the spacing caused backs off, and holds above it', () {
      final p = pace();
      for (var k = 0; k < 6; k++) {
        p.feedback(answer(p.gapMs(0)), lose(1), who: 'a', nowMs: 0);
      }
      expect(p.gapMs(0, nowMs: 0), 395);
      // 'a' lost 1% at 517, now 12% at 395: the spacing's doing.
      expect(p.feedback(answer(395), lose(12), who: 'a', nowMs: 1000), isTrue);
      expect(p.gapMs(0, nowMs: 1000), 493);
      for (var k = 0; k < 4; k++) {
        p.feedback(answer(p.gapMs(0)), lose(0), who: 'a', nowMs: 2000);
      }
      expect(p.gapMs(0, nowMs: 2000), 434);
      final later = 1000 + voxFloodAdaptiveHoldMs + 1;
      p.feedback(answer(434), lose(0), who: 'a', nowMs: later);
      expect(p.gapMs(0, nowMs: later), 395);
      // A third lost: up by half.
      p.feedback(answer(395), lose(40), who: 'a', nowMs: later);
      expect(p.gapMs(0, nowMs: later), 592);
    });

    test('a listener on a poor link of its own does not hold it back', () {
      final p = pace();
      // Not heard from before, 20% lost: nothing to compare with, so up.
      p.feedback(answer(517), lose(20), who: 'b', nowMs: 0);
      expect(p.gapMs(0, nowMs: 0), 646);
      // As lossy at the wider gap: its link, not the spacing.
      expect(p.feedback(answer(646), lose(21), who: 'b', nowMs: 0), isFalse);
      p.feedback(answer(646), lose(0), who: 'a', nowMs: 0);
      expect(p.gapMs(0, nowMs: 0), 581);
      // Barely more at a tighter gap: still its link.
      final a = answer(581);
      expect(p.feedback(a, lose(22), who: 'b', nowMs: 0), isFalse);
      p.feedback(a, lose(0), who: 'a', nowMs: 0);
      expect(p.gapMs(0, nowMs: 0), 522);
    });

    test('a rise after a fall on the same answer wins', () {
      final p = pace();
      final first = answer(517);
      p.feedback(first, lose(1), who: 'a', nowMs: 0);
      p.feedback(first, lose(1), who: 'c', nowMs: 0);
      expect(p.gapMs(0, nowMs: 0), 465);
      final a = answer(465);
      p.feedback(a, lose(0), who: 'a', nowMs: 0);
      expect(p.gapMs(0, nowMs: 0), 418);
      p.feedback(a, lose(15), who: 'c', nowMs: 0);
      expect(p.gapMs(0, nowMs: 0), 522);
    });

    test('the learnt gap is kept across restarts, per airtime', () {
      final p = pace();
      p.feedback(answer(517), lose(0), who: 'a', nowMs: 0);
      final saved = p.saveAdaptive();
      expect((pace()..restoreAdaptive(saved)).gapMs(0, nowMs: 0), 465);
      final other = VoxFloodPace(338, fast: true)
        ..adaptive = true
        ..restoreAdaptive(saved);
      expect(other.gapMs(0, nowMs: 0), voxFloodFastBaseGapMs(338));
    });
  });

  test('the gap runs from the send: the radio\'s accept time is in it', () {
    const gap = Duration(milliseconds: 517);
    expect(
      voxGapAfterSend(gap, const Duration(milliseconds: 176)),
      const Duration(milliseconds: 341),
    );
    expect(
      voxGapAfterSend(gap, const Duration(milliseconds: 900)),
      Duration.zero,
    );
  });

  test('a small answer goes before bigger ones queued ahead of it', () {
    expect(voxPickServe([245, 222]), 0);
    expect(voxPickServe([222, 20]), 1);
    expect(voxPickServe([222, 40, 17]), 1);
    expect(voxPickServe([255]), 0);
  });
}
