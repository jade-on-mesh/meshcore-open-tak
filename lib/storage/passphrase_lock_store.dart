import 'prefs_manager.dart';

/// Persists the OTP passphrase-lock salt + check tag — NEVER the derived
/// key or the passphrase itself (see [PassphraseLockCrypto] in
/// `services/passphrase_lock_service.dart` for why that's safe to store in
/// plain SharedPreferences: the tag is a one-way HMAC, not the key).
///
/// Deliberately device-global (not scoped per companion-radio identity like
/// [OtpPadStore]) — this is a single app-level "is OTP protection turned
/// on" toggle, not a per-contact/per-channel setting.
class PassphraseLockStore {
  static const String _saltKey = 'otp_lock_salt_hex';
  static const String _tagKey = 'otp_lock_tag_hex';

  String? loadSaltHex() => PrefsManager.instance.getString(_saltKey);

  String? loadTagHex() => PrefsManager.instance.getString(_tagKey);

  bool get hasProtection => loadSaltHex() != null && loadTagHex() != null;

  Future<void> save({required String saltHex, required String tagHex}) async {
    await PrefsManager.instance.setString(_saltKey, saltHex);
    await PrefsManager.instance.setString(_tagKey, tagHex);
  }

  /// Clears the salt+tag — protection becomes disabled the moment this
  /// returns (matches Lua's panic-wipe: destroy the lock along with the
  /// secrets, don't leave the device locked-but-empty).
  Future<void> clear() async {
    await PrefsManager.instance.remove(_saltKey);
    await PrefsManager.instance.remove(_tagKey);
  }
}
