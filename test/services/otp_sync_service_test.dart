import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/models/otp_pad.dart';
import 'package:meshcore_open/services/otp_sync_service.dart';

// CascadiaMesh field report: a device that hadn't been updated in a while
// was still emitting the old ('z1') sync-check wire format. An up-to-date
// peer's looksLikeSyncMessage only recognized the CURRENT marker ('z3'),
// so it didn't treat the stale peer's message as a control message at all -
// it fell straight through and showed up as literal garbage text in the
// chat view ("z1sak", "z1sao", ...). These tests lock in the fix (legacy
// markers are recognized for suppression, even though they can't be
// parsed/acted on) and the one marker that must NOT be treated as legacy
// ('z2' - still OtpChannelOffsetService's live channel-offset marker).
void main() {
  group('OtpSyncService.looksLikeSyncMessage', () {
    test('recognizes the current wire format', () {
      final msg = OtpSyncService.buildShared(isReply: false, offset: 5);
      expect(OtpSyncService.looksLikeSyncMessage(msg), isTrue);
    });

    test('recognizes a stale peer\'s old (z1) sync-check chatter', () {
      expect(OtpSyncService.looksLikeSyncMessage('z1sak'), isTrue);
      expect(OtpSyncService.looksLikeSyncMessage('z1sao'), isTrue);
      expect(OtpSyncService.looksLikeSyncMessage('z1pA5:3'), isTrue);
    });

    test('recognizes the original v1 pipe-delimited format', () {
      expect(
        OtpSyncService.looksLikeSyncMessage('OTPSYNC1|2P|0|5:3'),
        isTrue,
      );
    });

    test(
      'does NOT treat z2 as a legacy sync marker - it is permanently '
      'OtpChannelOffsetService\'s own channel-offset marker, and real '
      'channel ciphertext legitimately starts with it',
      () {
        // A plausible real z2-framed channel message: offset "5" then a
        // pipe then hex ciphertext - must NOT be swallowed as a sync-check.
        expect(OtpSyncService.looksLikeSyncMessage('z25|a1b2c3d4'), isFalse);
      },
    );

    test('ordinary chat text and ciphertext are never flagged', () {
      expect(OtpSyncService.looksLikeSyncMessage('hello there'), isFalse);
      expect(OtpSyncService.looksLikeSyncMessage('a1b2c3d4'), isFalse);
    });
  });

  group('OtpSyncService.parse', () {
    test('still only ever succeeds against the current marker', () {
      final msg = OtpSyncService.buildTwoParty(
        isReply: false,
        myOffset: 5,
        theirOffset: 3,
        role: OtpPadRole.a,
      );
      expect(OtpSyncService.parse(msg), isNotNull);
    });

    test(
      'legacy-marker text parses to null - callers already treat that as '
      '"suppress from chat, nothing actionable", never as a real exchange',
      () {
        expect(OtpSyncService.parse('z1sak'), isNull);
        expect(OtpSyncService.parse('OTPSYNC1|2P|0|5:3'), isNull);
      },
    );
  });
}
