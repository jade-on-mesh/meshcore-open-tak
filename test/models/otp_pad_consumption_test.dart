import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/models/otp_pad.dart';

// Regression coverage for the 2026-10-05 fix: OtpPad's twoPartyHalfSplit
// mode used to carve the buffer into a FIXED 50/50 half per party, with
// Party B's own sends growing forward from the midpoint. Real WADAMESH
// Lua (pks()/pdib() in OTP_3_RC1.lua) has no fixed midpoint at all: Party
// A's sends grow forward from byte 0, Party B's sends grow BACKWARD from
// the very end of the buffer, and the only shared constraint is the
// combined remaining budget (myOffset + theirOffset <= totalBytes). The
// old fixed-half version produced a different, incompatible byte range
// for Party B than a real Lua peer expects, silently failing to decrypt.
// These cases are worked by hand against a known 16-byte pad so they
// cross-check the exact byte positions, not just "doesn't crash".
void main() {
  // 16 bytes: 0x00..0x0f, as lowercase hex.
  const padHex =
      '000102030405060708090a0b0c0d0e0f';
  final importedAt = DateTime(2026, 1, 1);

  OtpPad pad({required OtpPadRole role, int myOffset = 0, int theirOffset = 0}) {
    return OtpPad(
      padHex: padHex,
      mode: OtpPadMode.twoPartyHalfSplit,
      role: role,
      myOffset: myOffset,
      theirOffset: theirOffset,
      importedAt: importedAt,
    );
  }

  group('twoPartyHalfSplit byte positions (mirrors Lua pks()/pdib())', () {
    test('Party A\'s own sends grow forward from byte 0', () {
      final p = pad(role: OtpPadRole.a);
      expect(p.takeMyKeyBytes(3), [0x00, 0x01, 0x02]);
    });

    test('Party A\'s own sends continue forward after some have been sent', () {
      final p = pad(role: OtpPadRole.a, myOffset: 3);
      expect(p.takeMyKeyBytes(3), [0x03, 0x04, 0x05]);
    });

    test('Party A decrypting Party B reads from the back of the buffer', () {
      final p = pad(role: OtpPadRole.a);
      expect(p.takeTheirKeyBytes(3), [0x0d, 0x0e, 0x0f]);
    });

    test('Party B\'s own sends grow BACKWARD from the end of the buffer '
        '(not forward from the midpoint)', () {
      final p = pad(role: OtpPadRole.b);
      expect(p.takeMyKeyBytes(3), [0x0d, 0x0e, 0x0f]);
    });

    test('Party B\'s own sends continue backward after some have been sent', () {
      final p = pad(role: OtpPadRole.b, myOffset: 3);
      expect(p.takeMyKeyBytes(3), [0x0a, 0x0b, 0x0c]);
    });

    test('Party B decrypting Party A reads from the front of the buffer', () {
      final p = pad(role: OtpPadRole.b);
      expect(p.takeTheirKeyBytes(3), [0x00, 0x01, 0x02]);
    });

    test('Party A\'s "mine" bytes and Party B\'s "theirs" bytes are the '
        'exact same physical range for the same offset (A writes what B '
        'reads)', () {
      final a = pad(role: OtpPadRole.a, myOffset: 2);
      final b = pad(role: OtpPadRole.b, theirOffset: 2);
      expect(a.takeMyKeyBytes(4), b.takeTheirKeyBytes(4));
    });

    test('Party B\'s "mine" bytes and Party A\'s "theirs" bytes are the '
        'exact same physical range for the same offset (B writes what A '
        'reads)', () {
      final b = pad(role: OtpPadRole.b, myOffset: 2);
      final a = pad(role: OtpPadRole.a, theirOffset: 2);
      expect(b.takeMyKeyBytes(4), a.takeTheirKeyBytes(4));
    });
  });

  group('combined remaining budget (mirrors Lua emmb())', () {
    test('myBytesRemaining and theirBytesRemaining are the same number — '
        'there is no independent per-party cap', () {
      final p = pad(role: OtpPadRole.a, myOffset: 5, theirOffset: 3);
      expect(p.myBytesRemaining, 8); // 16 - 5 - 3
      expect(p.theirBytesRemaining, 8);
      expect(p.myBytesRemaining, p.theirBytesRemaining);
    });

    test('a fresh pad reports the full length as remaining on both sides', () {
      final p = pad(role: OtpPadRole.b);
      expect(p.myBytesRemaining, 16);
      expect(p.theirBytesRemaining, 16);
    });

    test('is exhausted once the combined offsets reach the total length', () {
      final p = pad(role: OtpPadRole.a, myOffset: 10, theirOffset: 6);
      expect(p.myBytesRemaining, 0);
      expect(p.isExhausted, isTrue);
    });

    test('usage fractions are each offset over the WHOLE buffer, not a '
        'fixed half — so the two fractions together approach 1.0 as the '
        'combined budget is used up, never independently reaching 1.0 '
        'from one side\'s offset alone exceeding a half', () {
      final p = pad(role: OtpPadRole.a, myOffset: 4, theirOffset: 4);
      expect(p.myUsageFraction, closeTo(4 / 16, 1e-9));
      expect(p.theirUsageFraction, closeTo(4 / 16, 1e-9));
    });
  });
}
