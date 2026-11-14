// MeshCore Open TAK - photos and voice stay off the main mesh.
//
// A photo burst on the main mesh is minutes of everyone's airtime, so photos,
// voice and video only go out when the connected radio sends them on
// MediaMesh (radio2) alone. There is no switch to allow the main mesh.
//
// Public and #public: everyone on the mesh shares them, so photos, voice
// messages and push-to-talk stay off there unless the user switches them on
// (meant for emergencies), like OTP, which Public refuses outright.

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/channel.dart';

class MediaLockdown {
  MediaLockdown._();

  /// The removed developer switch's preference, cleared on load.
  static const _oldDevKey = 'media_main_dev';
  static const _publicKey = 'media_public_allowed';

  static const String blockedMessage =
      'Photos and voice only go out on MediaMesh (radio2). In MediaMesh '
      'settings, turn radio2 on (listen and send) with photos and voice on '
      'radio2.';

  /// Photos, voice and push-to-talk on Public and #public. Off by default;
  /// the settings say to switch it on only in an emergency.
  static final ValueNotifier<bool> publicAllowed = ValueNotifier(false);

  static const String publicBlockedMessage =
      'Photos and voice are off on Public and #public. Use another channel, '
      'or in an emergency switch on "Photos and voice on Public" in '
      'Settings > Messaging.';

  /// Public (the well-known key) or #public: the channels everyone shares.
  static bool isPublicMediaChannel(Channel channel) =>
      channel.isPublicChannel || channel.name.trim().toLowerCase() == '#public';

  /// Whether photos and voice are refused on [channel].
  static bool blocksChannel(Channel channel) =>
      !publicAllowed.value && isPublicMediaChannel(channel);

  static Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_oldDevKey);
      publicAllowed.value = prefs.getBool(_publicKey) ?? false;
    } catch (_) {}
  }

  static Future<void> setPublicAllowed(bool v) async {
    publicAllowed.value = v;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_publicKey, v);
    } catch (_) {}
  }
}

/// A photo or voice send refused because it would go out on the main mesh.
class MediaBlockedException implements Exception {
  final String message;
  const MediaBlockedException([this.message = MediaLockdown.blockedMessage]);
  @override
  String toString() => message;
}

/// A photo or voice send refused because it is for Public or #public and
/// photos and voice are off there ([MediaLockdown.publicAllowed]).
class PublicMediaBlockedException extends MediaBlockedException {
  const PublicMediaBlockedException()
    : super(MediaLockdown.publicBlockedMessage);
}
