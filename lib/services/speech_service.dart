// MeshCore Open TAK - speech with the platform's own voice (no plugin):
// Android TextToSpeech (SpeechChannel.kt), AVSpeechSynthesizer on iOS
// (AppDelegate.swift) and macOS (MainFlutterWindow.swift). Elsewhere it
// quietly does nothing. Used for Bloodhound's spoken turn prompts.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class SpeechService {
  SpeechService._();
  static final SpeechService instance = SpeechService._();

  static const _channel = MethodChannel('meshcore_open/speech');

  /// Whether this platform can speak at all.
  bool get available =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS);

  /// Says [text], cutting off anything still being said. False when it can't.
  Future<bool> say(String text, {String? language}) async {
    if (!available || text.trim().isEmpty) return false;
    try {
      return await _channel.invokeMethod<bool>('speak', {
            'text': text,
            'language': language,
          }) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<void> stop() async {
    if (!available) return;
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (_) {}
  }
}
