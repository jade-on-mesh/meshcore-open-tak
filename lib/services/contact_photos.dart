import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Photos assigned to contacts, shown in a circle instead of their initials,
/// emoji or type icon ([AvatarCircle.photoKey]). Kept on this device only,
/// one PNG per contact (by public key) in the app's support folder; nothing
/// goes over the mesh. Not on the web (no files there).
class ContactPhotos extends ChangeNotifier {
  ContactPhotos._();
  static final ContactPhotos instance = ContactPhotos._();

  final Map<String, Uint8List> _photos = <String, Uint8List>{};
  Future<void>? _loading;

  bool get supported => !kIsWeb;

  static String _key(String keyHex) => keyHex.toLowerCase();

  /// [keyHex]'s photo (PNG), or null.
  Uint8List? photoFor(String? keyHex) =>
      keyHex == null || keyHex.isEmpty ? null : _photos[_key(keyHex)];

  bool has(String keyHex) => _photos.containsKey(_key(keyHex));

  Future<Directory> _dir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}contact_photos');
    if (!dir.existsSync()) await dir.create(recursive: true);
    return dir;
  }

  static final _name = RegExp(r'^([0-9a-f]{64})\.png$');

  /// Reads the saved photos (once; later calls wait for the first).
  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    if (!supported) return;
    try {
      final dir = await _dir();
      for (final f in dir.listSync().whereType<File>()) {
        final m = _name.firstMatch(f.uri.pathSegments.last);
        if (m == null) continue;
        try {
          _photos[m.group(1)!] = await f.readAsBytes();
        } catch (_) {}
      }
      notifyListeners();
    } catch (e) {
      debugPrint('contact photos: $e');
    }
  }

  /// Saves [png] as [keyHex]'s photo.
  Future<void> set(String keyHex, Uint8List png) async {
    if (!supported) return;
    final key = _key(keyHex);
    final dir = await _dir();
    await File('${dir.path}${Platform.pathSeparator}$key.png').writeAsBytes(
      png,
      flush: true,
    );
    _photos[key] = png;
    notifyListeners();
  }

  /// Back to the contact's usual avatar.
  Future<void> remove(String keyHex) async {
    if (!supported) return;
    final key = _key(keyHex);
    _photos.remove(key);
    notifyListeners();
    try {
      final f = File(
        '${(await _dir()).path}${Platform.pathSeparator}$key.png',
      );
      if (f.existsSync()) await f.delete();
    } catch (_) {}
  }
}
