// MeshCore Open TAK - photos and voice stay off the main mesh.
//
// A photo burst on the main mesh is minutes of everyone's airtime, so photos
// and voice only go out when the connected radio sends them on MediaMesh
// (radio2) alone. Developers can still allow the main mesh: a hidden switch
// (long-press the MediaMesh settings title) until this is locked down fully.

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MediaLockdown {
  MediaLockdown._();

  static const _key = 'media_main_dev';

  /// Developer switch: photos and voice may use the main mesh.
  static final ValueNotifier<bool> devAllowMain = ValueNotifier(false);

  static const String blockedMessage =
      'Photos and voice only go out on MediaMesh (radio2). In MediaMesh '
      'settings, turn radio2 on (listen and send) with photos and voice on '
      'radio2.';

  static const String legacyBlockedMessage =
      'This photo type would go out on the main mesh. Use the photo button '
      '(sent on MediaMesh) instead.';

  static Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      devAllowMain.value = prefs.getBool(_key) ?? false;
    } catch (_) {}
  }

  static Future<void> set(bool v) async {
    devAllowMain.value = v;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_key, v);
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
