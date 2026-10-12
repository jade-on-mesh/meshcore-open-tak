import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:pointycastle/export.dart';

/// Pure crypto for the OTP passphrase lock + panic wipe feature.
///
/// This is a direct port of the key-derivation and check-tag design proved
/// out in WADAMESH OTP_2_RC15.lua's `derive_key`/`check_tag` functions —
/// only the "what does protection actually gate" scope is this app's own
/// decision (see the connector's `otpProtectionEnabled`/`otpLocked` and the
/// pad-manager screen); the mechanics below match Lua exactly:
///
///  - `derive_key(passphrase, salt)`: HMAC-SHA256, run [kdfRounds] + 1 = 3001
///    sequential rounds, with the running output re-used as the HMAC KEY
///    each round and the passphrase as the MESSAGE every round, seeded with
///    a random 16-byte salt as the initial "key" input. This is
///    deliberately slow — that's the KDF's whole point as a work factor
///    against offline passphrase guessing — so callers should only run it
///    from a user-facing "unlock"/"enable protection" action, never on a
///    hot path.
///  - `check_tag(key)`: HMAC-SHA256(key, [checkTagDomain]), hex-encoded.
///    Only the salt and this tag are ever persisted — never the derived key
///    or the passphrase itself. Unlocking re-derives the key from an
///    entered passphrase and compares its tag to the stored one.
///
/// At-rest encryption of the pad store under the session key (once
/// protection is enabled) is also provided here, as synchronous AES-256-GCM
/// via `package:pointycastle` (already a dependency, already used
/// elsewhere in this app for real symmetric crypto — see
/// `MeshCoreConnector._decryptPayload`). `package:cryptography`'s AEAD API
/// is async-only, and `OtpPadStore.loadContactPad`/`loadChannelPad` are
/// synchronous APIs called from many synchronous call sites throughout
/// `MeshCoreConnector` (e.g. `isContactOtpEnabled`) — switching the whole
/// pad-loading path to async to accommodate an async cipher would be a much
/// larger, riskier change than reusing the synchronous cipher this codebase
/// already has. This is a deliberate deviation from "prefer
/// `package:cryptography`" for that reason.
class PassphraseLockCrypto {
  PassphraseLockCrypto._();

  /// Matches Lua's `KDF_ROUNDS`. `deriveKey` runs this many HMAC rounds
  /// PLUS ONE (3001 total), matching Lua's `for i = 1, KDF_ROUNDS + 1 do`.
  static const int kdfRounds = 3000;

  /// Matches Lua's fixed domain-separation string for `check_tag`.
  static const String checkTagDomain = 'wadamesh-check-v1';

  static const int saltBytes = 16;

  /// AES-GCM key length used for the session key / at-rest cipher (AES-256).
  static const int sessionKeyBytes = 32;

  static const int _gcmNonceBytes = 12;
  static const int _gcmTagBits = 128;

  static Uint8List randomBytes(int length) {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(length, (_) => random.nextInt(256)),
    );
  }

  static Uint8List randomSalt() => randomBytes(saltBytes);

  /// HMAC-SHA256, [kdfRounds] + 1 (3001) sequential rounds — [salt] seeds
  /// the first round's HMAC key, [passphrase] (UTF-8) is the message every
  /// round, and each round's output becomes the next round's HMAC key.
  /// Returns a 32-byte derived key.
  static Uint8List deriveKey(String passphrase, Uint8List salt) {
    final passphraseBytes = Uint8List.fromList(utf8.encode(passphrase));
    var k = salt;
    for (var i = 0; i < kdfRounds + 1; i++) {
      final digest = crypto.Hmac(crypto.sha256, k).convert(passphraseBytes);
      k = Uint8List.fromList(digest.bytes);
    }
    return k;
  }

  /// `hex(hmac_sha256(key, "wadamesh-check-v1"))` — a value safe to persist
  /// alongside the salt: it reveals nothing about the passphrase or the
  /// derived key beyond letting a future unlock attempt verify a match.
  static String checkTag(Uint8List key) {
    final digest = crypto.Hmac(
      crypto.sha256,
      key,
    ).convert(utf8.encode(checkTagDomain));
    return digest.toString();
  }

  /// Encrypts [plaintext] under [sessionKey] (32 bytes) with AES-256-GCM,
  /// returning `base64(nonce || ciphertext || 16-byte tag)`. Synchronous.
  static String encryptString(String plaintext, Uint8List sessionKey) {
    final nonce = randomBytes(_gcmNonceBytes);
    final cipher = GCMBlockCipher(AESEngine())
      ..init(
        true,
        AEADParameters(
          KeyParameter(sessionKey),
          _gcmTagBits,
          nonce,
          Uint8List(0),
        ),
      );
    final cipherText = cipher.process(
      Uint8List.fromList(utf8.encode(plaintext)),
    );
    final combined = Uint8List(nonce.length + cipherText.length)
      ..setRange(0, nonce.length, nonce)
      ..setRange(nonce.length, nonce.length + cipherText.length, cipherText);
    return base64Encode(combined);
  }

  /// Reverses [encryptString]. Returns null on any failure — wrong key,
  /// corrupted/truncated data, or a failed GCM tag check — never throws,
  /// so callers can treat "can't decrypt" the same as "pad unavailable".
  static String? decryptString(String encoded, Uint8List sessionKey) {
    try {
      final combined = base64Decode(encoded);
      if (combined.length <= _gcmNonceBytes) return null;
      final nonce = combined.sublist(0, _gcmNonceBytes);
      final cipherText = combined.sublist(_gcmNonceBytes);
      final cipher = GCMBlockCipher(AESEngine())
        ..init(
          false,
          AEADParameters(
            KeyParameter(sessionKey),
            _gcmTagBits,
            nonce,
            Uint8List(0),
          ),
        );
      final plainBytes = cipher.process(Uint8List.fromList(cipherText));
      return utf8.decode(plainBytes);
    } catch (_) {
      return null;
    }
  }
}
