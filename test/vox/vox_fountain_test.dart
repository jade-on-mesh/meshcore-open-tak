import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/vox/vox_fec.dart';
import 'package:meshcore_open/vox/vox_fountain.dart';
import 'package:meshcore_open/vox/vox_timing.dart';
import 'package:meshcore_open/vox/voice_wire.dart';

void main() {
  List<Uint8List> clip(Random r, int n, {int last = 40}) => [
    for (var i = 0; i < n; i++)
      Uint8List.fromList(
        List.generate(i == n - 1 ? last : 156, (_) => r.nextInt(256)),
      ),
  ];

  /// A repair packet's codec data, as a listener stores it.
  Uint8List data(Uint8List pkt) =>
      Uint8List.sublistView(pkt, VoxVoicePacket.headerLength);

  test('any m repair packets (and a spare) bring back any m lost', () {
    final r = Random(7);
    var solvedExact = 0;
    for (var t = 0; t < 60; t++) {
      final n = 20 + r.nextInt(200);
      final packets = clip(r, n, last: 1 + r.nextInt(156));
      final m = 1 + r.nextInt(min(40, n));
      final lost = <int>{};
      while (lost.length < m) {
        lost.add(r.nextInt(n));
      }
      final present = {
        for (var i = 0; i < n; i++)
          if (!lost.contains(i)) i: packets[i],
      };
      final start = r.nextInt(voxFountainSeeds);
      Map<int, Uint8List> repairs(int count) => {
        for (var k = 0; k < count; k++)
          (start + k) % voxFountainSeeds: data(
            voxFountainEncode(
              '1a2b3c4d',
              packets,
              (start + k) % voxFountainSeeds,
            ),
          ),
      };
      final exact = voxFountainRebuild(
        total: n,
        present: present,
        repairs: repairs(m),
      );
      if (exact.length == m) solvedExact++;
      final got = voxFountainRebuild(
        total: n,
        present: present,
        repairs: repairs(m + 1),
      );
      expect(got.keys.toSet(), lost, reason: 'trial $t');
      for (final i in lost) {
        expect(got[i], packets[i], reason: 'trial $t packet $i');
      }
    }
    // Exactly m nearly always does too.
    expect(solvedExact, greaterThan(55));
  });

  test('too few repair packets bring nothing back', () {
    final r = Random(3);
    final packets = clip(r, 30);
    final present = {for (var i = 3; i < 30; i++) i: packets[i]};
    final got = voxFountainRebuild(
      total: 30,
      present: present,
      repairs: {
        for (final s in [1, 2])
          s: data(voxFountainEncode('00000001', packets, s)),
      },
    );
    expect(got, isEmpty);
  });

  test('repair packets have their own session id, not parity or data', () {
    const sid = 'deadbeef';
    expect(voxFountainSid(sid), isNot(sid));
    expect(voxFountainSid(sid), isNot(voxFecParitySid(sid)));
    expect(voxFountainDataSid(voxFountainSid(sid)), sid);
  });

  test('coefficients are never 0 and fixed (same on every platform)', () {
    for (var s = 0; s < voxFountainSeeds; s += 17) {
      for (var i = 0; i < 255; i += 13) {
        expect(voxFountainCoef(s, i), inInclusiveRange(1, 255));
      }
    }
    // Pinned against scripts/vox/fountain_ref.py.
    expect(
      [for (var i = 0; i < 4; i++) voxFountainCoef(0, i)],
      const [170, 198, 111, 183],
    );
    expect(
      [for (var i = 250; i < 254; i++) voxFountainCoef(200, i)],
      const [217, 252, 244, 168],
    );
  });

  test('a request says it takes repair packets on a channel only', () {
    const req = VoxVoiceFetchRequest(
      sessionId: '1a2b3c4d',
      requesterKey6: '0123456789ab',
      missingIndices: [3, 9],
      saltOk: true,
    );
    expect(VoxVoiceFetchRequest.tryParse(req.encode())!.fountainOk, isFalse);
    final ch = req.forChannel(fountain: true);
    final back = VoxVoiceFetchRequest.tryParse(ch.encode())!;
    expect(back.fountainOk, isTrue);
    expect(back.markOk, isTrue);
    expect(back.missingIndices, [3, 9]);
  });

  test('repair counts: the missing plus a margin; a tenth after a pass', () {
    expect(voxFountainNeeded(0), 0);
    expect(voxFountainNeeded(1), greaterThanOrEqualTo(2));
    expect(voxFountainNeeded(40), inInclusiveRange(46, 48));
    expect(voxFountainFirstPass(217), 23);
  });

  test('repair packets owed: data going out anyway counts towards them', () {
    // 18:00 field test: a listener lacking 221 of 226, all going out as
    // data for a listener on an older app, was owed 144 repair packets.
    expect(voxFountainOwed(uncovered: 0, covered: 221), 24);
    expect(voxFountainOwed(uncovered: 4, covered: 0), voxFountainNeeded(4));
    expect(voxFountainOwed(uncovered: 10, covered: 100, sentSince: 5), 19);
    expect(voxFountainOwed(uncovered: 2, covered: 0, sentSince: 50), 0);
    expect(voxFountainListCap, voxSaltedFetchIndices);
  });

  test('repair packets sized for the loss answers have seen lately', () {
    // No loss seen: as before.
    expect(voxFountainOwed(uncovered: 4, covered: 0, lossPct: 0), 6);
    expect(voxFountainPassShare(226, 0), voxFountainFirstPass(226));
    // A fifth lost: a pass of 226 ends with enough that the worst listener
    // still gets as many as it lost (45 of 226, 52 of 65 repairs arrive).
    expect(voxFountainPassShare(226, 20), 65);
    expect(voxFountainNeededAt(50, 20), voxFountainNeeded(63));
    // Capped: a listener on a link losing most of it asks again.
    expect(voxFountainPassShare(100, 90), voxFountainPassShare(100, 40));
  });

  test(
    'pace learns the loss of its answers: up at once, down by a quarter',
    () {
      final p = VoxFloodPace(338, fast: true);
      final a = VoxFloodAnswer(List.generate(100, (i) => i));
      p.feedback(a, {for (var i = 0; i < 20; i++) i * 5});
      expect(p.lossPct, 20);
      p.feedback(a, {for (var i = 0; i < 30; i++) i * 3});
      expect(p.lossPct, 30);
      final b = VoxFloodAnswer(List.generate(100, (i) => i));
      p.feedback(b, {});
      expect(p.lossPct, 22);
      final c = VoxFloodAnswer(List.generate(10, (i) => i));
      p.feedback(c, {for (var i = 0; i < 10; i++) i});
      expect(p.lossPct, 40);
    },
  );

  test('the same transfer: its parity, repair packets and other parts', () {
    const sid = '1a2b3c4d';
    expect(voxSameTransfer(sid, sid), isTrue);
    expect(voxSameTransfer(sid, voxFecParitySid(sid)), isTrue);
    expect(voxSameTransfer(sid, voxFountainSid(sid)), isTrue);
    // Parts 1-3 of a SuperMax clip (video_codec.dart voxVideoPartSid), and
    // each other's repair packets.
    final p1 = voxSessionIdFromInt(int.parse(sid, radix: 16) ^ 0x7A010101);
    final p2 = voxSessionIdFromInt(int.parse(sid, radix: 16) ^ 0x7A020202);
    expect(voxSameTransfer(sid, p2), isTrue);
    expect(voxSameTransfer(p1, p2), isTrue);
    expect(voxSameTransfer(p2, voxFountainSid(p1)), isTrue);
    expect(voxSameTransfer(sid, '1a2b3c4e'), isFalse);
    expect(voxSameTransfer(sid, 'deadbeef'), isFalse);
  });

  test('a request waits while its transfer is on the air, up to 3 minutes', () {
    expect(
      voxBusyAirHoldMs(sinceHeardMs: 1000, sinceAskedMs: 30000, quietMs: 4000),
      3000,
    );
    expect(
      voxBusyAirHoldMs(sinceHeardMs: 5000, sinceAskedMs: 30000, quietMs: 4000),
      isNull,
    );
    expect(
      voxBusyAirHoldMs(sinceHeardMs: 0, sinceAskedMs: 181000, quietMs: 4000),
      isNull,
    );
  });

  test('fast pace starts tighter and learns down only to its floor', () {
    const air = 338;
    final slow = VoxFloodPace(air);
    final fast = VoxFloodPace(air, fast: true);
    expect(fast.gapMs(1), lessThan(slow.gapMs(1)));
    expect(fast.gapMs(3), voxFloodFastBaseGapMs(air));
    expect(voxFloodFastBaseGapMs(air), greaterThan(2 * air));
  });
}
