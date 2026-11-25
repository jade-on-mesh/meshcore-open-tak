// MeshCore Open TAK - whether chats show upstream's Compression strip at the
// top (ChatCompressionSelector). Hidden unless turned on in App Settings ›
// Messaging, or the chat already uses compression: few people use SMAZ or
// Cyr2Lat and the strip confused people. On this phone only.

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/chat_compression_mode.dart';

class ChatCompressionStrip extends ChangeNotifier {
  ChatCompressionStrip._();

  static final ChatCompressionStrip instance = ChatCompressionStrip._();

  static const String _prefsKey = 'chat_compression_strip_v1';

  bool _show = false;

  /// The setting: show the strip in every chat.
  bool get show => _show;

  /// Whether a chat compressing with [mode] shows the strip: always when
  /// the setting is on, and when the chat already compresses (so it can be
  /// seen and turned off).
  bool showFor(ChatCompressionMode mode) =>
      _show || mode != ChatCompressionMode.off;

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _show = prefs.getBool(_prefsKey) ?? false;
    } catch (e) {
      debugPrint('Compression strip: could not load ($e)');
    }
    notifyListeners();
  }

  Future<void> setShow(bool value) async {
    if (value == _show) return;
    _show = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefsKey, value);
    } catch (e) {
      debugPrint('Compression strip: could not save ($e)');
    }
  }

  @visibleForTesting
  void debugSetShow(bool value) {
    _show = value;
    notifyListeners();
  }
}
