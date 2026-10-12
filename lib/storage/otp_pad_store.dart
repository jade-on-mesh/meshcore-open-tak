import 'dart:convert';
import 'dart:typed_data';

import '../models/otp_pad.dart';
import '../services/passphrase_lock_service.dart';
import '../utils/app_logger.dart';
import 'prefs_manager.dart';

/// Persists OTP pads and their consumption offsets for contacts and
/// channels.
///
/// Follows the same self-identity scoping as [ContactSettingsStore] /
/// [ChannelSettingsStore] (keys are namespaced by a prefix of this device's
/// own public key, so switching companion radios doesn't mix pad state
/// between identities) but stores each pad as one JSON blob per target
/// rather than several scalar keys — a pad record is a single compound
/// object that's always read and written as a unit, so there's nothing to
/// gain from splitting it into separate booleans/ints the way the
/// Smaz/Cyr2Lat settings do.
///
/// Stored in plain SharedPreferences — unencrypted by default (matching how
/// every other per-contact/per-channel setting in this app is already
/// stored), UNLESS the OTP passphrase lock feature has been enabled and
/// unlocked (see [sessionKey]), in which case every pad blob is wrapped in
/// real AES-256-GCM authenticated encryption keyed by the passphrase-derived
/// session key before it ever reaches SharedPreferences. This is deliberate
/// defense in depth: the passphrase gate on the pad-manager screen is only
/// a UI speed bump unless the pad data itself is unreadable without the
/// key, e.g. to anyone with filesystem/backup access to the raw prefs blob.
class OtpPadStore {
  static const String _contactKeyPrefix = 'contact_otp_pad_';
  static const String _channelKeyPrefix = 'channel_otp_pad_';

  /// Marks a stored value as an encrypted envelope (see [_encode]/[_decode])
  /// rather than the bare JSON this store originally always wrote — lets
  /// old plaintext blobs and new encrypted ones coexist/migrate cleanly.
  static const String _encPrefix = 'ENC1:';

  String publicKeyHex = '';
  set setPublicKeyHex(String value) =>
      publicKeyHex = value.length > 10 ? value.substring(0, 10) : '';

  /// The passphrase-derived AES-256 key, or null when OTP protection is
  /// either not enabled or currently locked. While null, [_load] refuses to
  /// even attempt to read an encrypted blob — it simply reports "no pad" —
  /// which is exactly the gating behaviour the passphrase-lock feature
  /// needs: a locked device can't decrypt persisted pads, so OTP for any
  /// contact/channel whose pad predates the lock quietly (and safely)
  /// behaves as "not enabled" until unlocked. Callers (the connector) MUST
  /// clear their own in-memory pad caches whenever this changes, or a pad
  /// that failed to load while locked will stay cached as "absent" forever.
  Uint8List? sessionKey;

  String _contactKey(String contactKeyHex) =>
      '$_contactKeyPrefix${publicKeyHex}_$contactKeyHex';

  String _channelKey(int channelIndex) =>
      '$_channelKeyPrefix${publicKeyHex}_$channelIndex';

  OtpPad? loadContactPad(String contactKeyHex) {
    if (publicKeyHex.isEmpty) {
      appLogger.warn('Public key hex is not set. Cannot load OTP pad.');
      return null;
    }
    return _load(_contactKey(contactKeyHex));
  }

  Future<void> saveContactPad(String contactKeyHex, OtpPad pad) async {
    if (publicKeyHex.isEmpty) {
      appLogger.warn('Public key hex is not set. Cannot save OTP pad.');
      return;
    }
    await _save(_contactKey(contactKeyHex), pad);
  }

  Future<void> clearContactPad(String contactKeyHex) async {
    if (publicKeyHex.isEmpty) return;
    await PrefsManager.instance.remove(_contactKey(contactKeyHex));
  }

  OtpPad? loadChannelPad(int channelIndex) {
    if (publicKeyHex.isEmpty) {
      appLogger.warn('Public key hex is not set. Cannot load OTP pad.');
      return null;
    }
    return _load(_channelKey(channelIndex));
  }

  Future<void> saveChannelPad(int channelIndex, OtpPad pad) async {
    if (publicKeyHex.isEmpty) {
      appLogger.warn('Public key hex is not set. Cannot save OTP pad.');
      return;
    }
    await _save(_channelKey(channelIndex), pad);
  }

  Future<void> clearChannelPad(int channelIndex) async {
    if (publicKeyHex.isEmpty) return;
    await PrefsManager.instance.remove(_channelKey(channelIndex));
  }

  OtpPad? _load(String key) {
    final raw = PrefsManager.instance.getString(key);
    if (raw == null || raw.isEmpty) return null;
    final jsonString = _decode(key, raw);
    if (jsonString == null) return null;
    try {
      final json = jsonDecode(jsonString) as Map<String, dynamic>;
      return OtpPad.fromJson(json);
    } catch (e) {
      appLogger.warn('Failed to parse stored OTP pad for $key: $e');
      return null;
    }
  }

  Future<void> _save(String key, OtpPad pad) async {
    await PrefsManager.instance.setString(key, _encode(jsonEncode(pad.toJson())));
  }

  /// Wraps [jsonString] in an encrypted envelope when [sessionKey] is set,
  /// or returns it unchanged (legacy plaintext behaviour) when it isn't.
  String _encode(String jsonString) {
    final key = sessionKey;
    if (key == null) return jsonString;
    return '$_encPrefix${PassphraseLockCrypto.encryptString(jsonString, key)}';
  }

  /// Reverses [_encode]. A plaintext (un-prefixed) [raw] value is returned
  /// as-is regardless of [sessionKey] — that's the normal case for anyone
  /// not using the passphrase-lock feature at all, and also how an
  /// already-plaintext blob reads correctly even right up until the moment
  /// [migrateAllToEncrypted] re-saves it. An `ENC1:`-prefixed value can only
  /// be read back with the matching key: no key (locked, or protection
  /// never enabled on this run) or a wrong/rotated key both fail closed by
  /// returning null — the pad is simply unavailable, never partially or
  /// incorrectly decrypted.
  String? _decode(String key, String raw) {
    if (!raw.startsWith(_encPrefix)) return raw;
    final sessionKeyNow = sessionKey;
    if (sessionKeyNow == null) {
      appLogger.info('OTP pad for $key is locked (passphrase not entered)');
      return null;
    }
    final decrypted = PassphraseLockCrypto.decryptString(
      raw.substring(_encPrefix.length),
      sessionKeyNow,
    );
    if (decrypted == null) {
      appLogger.warn(
        'Failed to decrypt stored OTP pad for $key — wrong session key or corrupted data',
      );
    }
    return decrypted;
  }

  /// Re-saves every pad currently persisted for THIS identity (scoped the
  /// same way [loadContactPad]/[loadChannelPad] already are), converting
  /// any still-plaintext blob to an encrypted one under the now-active
  /// [sessionKey]. Call this once, right after enabling protection for the
  /// first time (with [sessionKey] already set), so pads imported BEFORE
  /// protection existed get protected immediately rather than only on their
  /// next natural write.
  ///
  /// Known limitation: this only covers pads under the CURRENT
  /// `publicKeyHex` scope. If this device was previously paired with a
  /// different companion radio and has leftover pads stored under that old
  /// identity's prefix, those are not touched — an existing scoping
  /// property of [OtpPadStore] this method inherits rather than changes.
  Future<void> migrateAllToEncrypted() async {
    final key = sessionKey;
    if (publicKeyHex.isEmpty || key == null) return;
    final contactPrefix = '$_contactKeyPrefix${publicKeyHex}_';
    final channelPrefix = '$_channelKeyPrefix${publicKeyHex}_';
    final keys = PrefsManager.instance.getKeys().where(
      (k) => k.startsWith(contactPrefix) || k.startsWith(channelPrefix),
    ).toList();
    for (final storageKey in keys) {
      final raw = PrefsManager.instance.getString(storageKey);
      if (raw == null || raw.isEmpty || raw.startsWith(_encPrefix)) continue;
      // Already-plaintext JSON: round-trip it through OtpPad so a corrupt
      // entry is dropped rather than blindly re-encrypted, then re-save
      // through the normal (now-encrypting) path.
      try {
        final json = jsonDecode(raw) as Map<String, dynamic>;
        final pad = OtpPad.fromJson(json);
        if (pad == null) continue;
        await _save(storageKey, pad);
      } catch (e) {
        appLogger.warn('Skipped migrating unreadable OTP pad $storageKey: $e');
      }
    }
  }

  /// Panic-wipe support: permanently deletes EVERY OTP pad this store has
  /// ever written, for every identity this device has ever been used with
  /// — deliberately broader than the per-identity scoping every other
  /// method here uses, because a panic wipe should err on the side of
  /// destroying too much rather than leaving some pad behind.
  Future<void> wipeAllPads() async {
    final keys = PrefsManager.instance.getKeys().where(
      (k) => k.startsWith(_contactKeyPrefix) || k.startsWith(_channelKeyPrefix),
    ).toList();
    for (final storageKey in keys) {
      await PrefsManager.instance.remove(storageKey);
    }
  }
}
