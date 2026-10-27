import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/vox/transfer_test.dart';

void main() {
  group('transfer test caption', () {
    test('is recognised, with or without a location tag after it', () {
      final c = voxTransferTestCaption(2, 5);
      expect(c, 'Transfer test 2/5 ⏱');
      expect(voxIsTransferTestCaption(c), isTrue);
      expect(voxIsTransferTestCaption('$c 📍1.00000,2.00000'), isTrue);
    });

    test('ordinary captions are not', () {
      expect(voxIsTransferTestCaption('Transfer test 2/5'), isFalse);
      expect(voxIsTransferTestCaption('my Transfer test 2/5 ⏱'), isFalse);
      expect(voxIsTransferTestCaption(''), isFalse);
    });
  });

  group('VoxTransferReport', () {
    test('round-trips', () {
      const r = VoxTransferReport(
        sessionId: '0a1b2c3d',
        ms: 12345,
        requests: 3,
        got: 17,
        total: 17,
      );
      expect(r.encode(), 'VT1:0a1b2c3d:12345:3:17/17');
      final p = VoxTransferReport.tryParse(r.encode())!;
      expect(p.sessionId, '0a1b2c3d');
      expect(p.ms, 12345);
      expect(p.requests, 3);
      expect(p.got, 17);
      expect(p.total, 17);
      expect(p.complete, isTrue);
    });

    test('rejects malformed reports', () {
      expect(VoxTransferReport.tryParse('VT1:abc:1:1:5/4'), isNull);
      expect(VoxTransferReport.tryParse('VT1:abc:1:1:0/0'), isNull);
      expect(VoxTransferReport.tryParse('VT1:abc:x:1:1/1'), isNull);
      expect(VoxTransferReport.tryParse('hello'), isNull);
      expect(VoxTransferReport.looksLikeReport('VT1:anything'), isTrue);
      expect(VoxTransferReport.looksLikeReport('VR3:x'), isFalse);
    });
  });

  group('voxTransferSummary', () {
    VoxTransferRun run(int i, Map<String, VoxTransferReport> reports) {
      final r = VoxTransferRun(
        index: i,
        sessionId: 's$i',
        totalPackets: 17,
        sentAt: DateTime(2026),
      );
      r.reports.addAll(reports);
      return r;
    }

    VoxTransferReport rep(int ms, int requests, int got) => VoxTransferReport(
      sessionId: 's',
      ms: ms,
      requests: requests,
      got: got,
      total: 17,
    );

    test('success rate, times and retries', () {
      final lines = voxTransferSummary([
        run(1, {'Bob': rep(10000, 1, 17)}),
        run(2, {'Bob': rep(20000, 3, 17)}),
        run(3, {'Bob': rep(90000, 6, 9)}),
      ], target: 'Bob');
      expect(lines[0], 'To Bob, 3 photos');
      expect(lines[1], 'Complete: 2 of 3 downloads (67%)');
      expect(lines[2], 'Time: median 15.0 s, best 10.0 s, worst 20.0 s');
      expect(lines[3], 'Requests: 10 (7 retries, median 3 per download)');
      expect(lines[6], contains('✗ 9/17'));
    });

    test('no reports', () {
      final lines = voxTransferSummary([run(1, {})]);
      expect(lines.first, startsWith('No reports came back'));
      expect(lines.last, contains('no report'));
    });

    test('counts receivers on a channel', () {
      final lines = voxTransferSummary([
        run(1, {'A': rep(1000, 1, 17), 'B': rep(2000, 2, 17)}),
      ]);
      expect(lines.first, 'Complete: 2 of 2 downloads (100%) by 2 receivers');
    });
  });

  test('the test image has the size asked for', () {
    final img = voxTransferTestImage(width: 32, height: 16);
    expect(img.rgb.length, 32 * 16 * 3);
  });
}
