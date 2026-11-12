import 'dart:convert';

import '../connector/meshcore_connector.dart';
import '../services/media_mesh.dart';
import 'prefs_manager.dart';

/// What Off-Grid Repeat replaced on a radio, so turning it off puts it back,
/// even after the app restarts: the main radio settings, and radio2,
/// `radio2.cross` and `tx.media` when the app set MediaMesh for it. A Keymind
/// Cascade companion needs that; a Wadamesh TAK standalone sets radio2 itself
/// and leaves those null. Kept per radio (the first 10 hex of its key).
class OffGridRepeatMemory {
  final MeshCoreRadioStateSnapshot? radio;

  /// The `set radio2 ...` (or `set radio2 off`) that puts radio2 back.
  final String? radio2Restore;

  /// The `tx.media` choice to put back.
  final String? txMedia;

  /// The `radio2.cross` choice to put back.
  final String? cross;

  const OffGridRepeatMemory({
    this.radio,
    this.radio2Restore,
    this.txMedia,
    this.cross,
  });

  OffGridRadio2Hold get radio2Hold => OffGridRadio2Hold(
    radio2Restore: radio2Restore,
    txMedia: txMedia,
    cross: cross,
  );

  bool get holdsRadio2 =>
      radio2Restore != null || txMedia != null || cross != null;

  OffGridRepeatMemory copyWith({
    MeshCoreRadioStateSnapshot? radio,
    OffGridRadio2Hold? hold,
  }) => OffGridRepeatMemory(
    radio: radio ?? this.radio,
    radio2Restore: hold != null ? hold.radio2Restore : radio2Restore,
    txMedia: hold != null ? hold.txMedia : txMedia,
    cross: hold != null ? hold.cross : cross,
  );

  Map<String, Object?> toJson() => {
    if (radio != null)
      'radio': {
        'freqHz': radio!.freqHz,
        'bwHz': radio!.bwHz,
        'sf': radio!.sf,
        'cr': radio!.cr,
        'tx': radio!.txPowerDbm,
      },
    'radio2Restore': ?radio2Restore,
    'txMedia': ?txMedia,
    'cross': ?cross,
  };

  static OffGridRepeatMemory? fromJson(Object? json) {
    if (json is! Map) return null;
    MeshCoreRadioStateSnapshot? radio;
    final r = json['radio'];
    if (r is Map &&
        r['freqHz'] is int &&
        r['bwHz'] is int &&
        r['sf'] is int &&
        r['cr'] is int &&
        r['tx'] is int) {
      radio = MeshCoreRadioStateSnapshot(
        freqHz: r['freqHz'] as int,
        bwHz: r['bwHz'] as int,
        sf: r['sf'] as int,
        cr: r['cr'] as int,
        txPowerDbm: r['tx'] as int,
      );
    }
    const choices = {'auto', 'radio', 'radio2', 'both', 'off', 'on'};
    final restore = json['radio2Restore'];
    final media = json['txMedia'];
    final cross = json['cross'];
    return OffGridRepeatMemory(
      radio: radio,
      radio2Restore: restore is String && restore.startsWith('set radio2 ')
          ? restore
          : null,
      txMedia: media is String && choices.contains(media) ? media : null,
      cross: cross is String && choices.contains(cross) ? cross : null,
    );
  }
}

class OffGridRepeatStore {
  static const String _keyPrefix = 'off_grid_repeat_';

  static String? _key(String publicKeyHex) => publicKeyHex.length >= 10
      ? '$_keyPrefix${publicKeyHex.substring(0, 10).toLowerCase()}'
      : null;

  static OffGridRepeatMemory? load(String publicKeyHex) {
    final key = _key(publicKeyHex);
    if (key == null) return null;
    try {
      final text = PrefsManager.instance.getString(key);
      return text == null
          ? null
          : OffGridRepeatMemory.fromJson(jsonDecode(text));
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(String publicKeyHex, OffGridRepeatMemory m) async {
    final key = _key(publicKeyHex);
    if (key == null) return;
    try {
      await PrefsManager.instance.setString(key, jsonEncode(m.toJson()));
    } catch (_) {}
  }

  static Future<void> clear(String publicKeyHex) async {
    final key = _key(publicKeyHex);
    if (key == null) return;
    try {
      await PrefsManager.instance.remove(key);
    } catch (_) {}
  }
}
