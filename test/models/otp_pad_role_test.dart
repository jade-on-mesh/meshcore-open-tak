import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/models/otp_pad.dart';

// resolveDmRole must match the Lua app's resolve_dm_role byte-for-byte -
// same tie-break rule, same case-folding - since the two sides never
// exchange anything to agree on a role; they just have to independently
// compute the same answer. These cases mirror the ones added to
// test_rc1.lua for the Lua side.
void main() {
  group('resolveDmRole', () {
    test('returns null when this device\'s own key is unavailable', () {
      expect(
        resolveDmRole(selfPublicKeyHex: null, contactPublicKeyHex: 'aa11'),
        isNull,
      );
      expect(
        resolveDmRole(selfPublicKeyHex: '', contactPublicKeyHex: 'aa11'),
        isNull,
      );
    });

    test('returns null when the contact\'s key is unavailable', () {
      expect(
        resolveDmRole(selfPublicKeyHex: 'bb00', contactPublicKeyHex: null),
        isNull,
      );
      expect(
        resolveDmRole(selfPublicKeyHex: 'bb00', contactPublicKeyHex: ''),
        isNull,
      );
    });

    test('a lower-sorting own key resolves to Party A', () {
      expect(
        resolveDmRole(selfPublicKeyHex: 'cc11', contactPublicKeyHex: 'dd99'),
        OtpPadRole.a,
      );
    });

    test('a higher-sorting own key resolves to Party B', () {
      expect(
        resolveDmRole(selfPublicKeyHex: 'dd99', contactPublicKeyHex: 'cc11'),
        OtpPadRole.b,
      );
    });

    test('equal keys default to Party A', () {
      expect(
        resolveDmRole(selfPublicKeyHex: 'bb00', contactPublicKeyHex: 'bb00'),
        OtpPadRole.a,
      );
    });

    test('comparison is ASCII-case-insensitive (lowercased first)', () {
      expect(
        resolveDmRole(selfPublicKeyHex: 'CC11', contactPublicKeyHex: 'dd99'),
        OtpPadRole.a,
      );
      expect(
        resolveDmRole(selfPublicKeyHex: 'cc11', contactPublicKeyHex: 'DD99'),
        OtpPadRole.a,
      );
    });

    test('the two sides of a DM always land on opposite roles', () {
      const mine = 'aa11bb';
      const theirs = 'cc22dd';
      final myRole = resolveDmRole(
        selfPublicKeyHex: mine,
        contactPublicKeyHex: theirs,
      );
      final theirRole = resolveDmRole(
        selfPublicKeyHex: theirs,
        contactPublicKeyHex: mine,
      );
      expect(myRole, isNotNull);
      expect(theirRole, isNotNull);
      expect(myRole, isNot(theirRole));
    });
  });
}
