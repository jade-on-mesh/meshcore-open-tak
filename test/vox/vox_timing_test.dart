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
}
