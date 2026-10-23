// MeshCore Open TAK - the photo mosaic's two settings (photo_mosaic.dart):
// photos on the map, and tagging the photos this phone sends with where they
// were taken. Kept apart so the voice service can read them without the map.

import 'package:flutter/foundation.dart';

import '../storage/prefs_manager.dart';

class PhotoMosaicPrefs {
  PhotoMosaicPrefs._();

  static const _kShow = 'photo_mosaic_show_v1';
  static const _kTag = 'photo_mosaic_tag_v1';

  /// Photos show on the map where they were taken (off until turned on).
  static final ValueNotifier<bool> show = ValueNotifier(_read(_kShow));

  /// Photos sent from here carry "📍lat,lon" in their caption (off until
  /// turned on: it tells everyone who can see the photo where you were).
  static final ValueNotifier<bool> tagOwn = ValueNotifier(_read(_kTag));

  /// This phone's position for a tag (set by the team service).
  static (double, double)? Function()? ownPosition;

  static bool _read(String k) {
    try {
      return PrefsManager.instance.getBool(k) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> setShow(bool v) async {
    show.value = v;
    try {
      await PrefsManager.instance.setBool(_kShow, v);
    } catch (_) {}
  }

  static Future<void> setTagOwn(bool v) async {
    tagOwn.value = v;
    try {
      await PrefsManager.instance.setBool(_kTag, v);
    } catch (_) {}
  }

  /// [caption] with this phone's position added, when [tagOwn] is on and a
  /// position is known.
  static String tagged(String caption) {
    if (!tagOwn.value) return caption;
    final p = ownPosition?.call();
    if (p == null) return caption;
    final tag = '📍${p.$1.toStringAsFixed(5)},${p.$2.toStringAsFixed(5)}';
    if (caption.contains('📍')) return caption;
    return caption.trim().isEmpty ? tag : '${caption.trim()} $tag';
  }
}
