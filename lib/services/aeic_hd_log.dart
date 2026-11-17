// MeshCore Open TAK - AI sketch HD's packet log, for the diagnostics sheet's
// Copy and Share (as voice, photos and videos have, voice_message_bubble.dart).
//
// One line per chunk sent or heard (index, status, SNR, hops, radio), per
// request and answer (aeic_hd_repair.dart), per auto-resume try, and per
// decode, newest kept, so a slow or stuck transfer can be read afterwards.

import 'package:flutter/foundation.dart';

/// One line of the AI sketch HD log.
@immutable
class AeicHdLogEntry {
  final DateTime time;

  /// The image, `prefix/imgId` (hex prefix), or '' when not tied to one.
  final String image;
  final String text;
  const AeicHdLogEntry(this.time, this.image, this.text);

  @override
  String toString() {
    final t = time.toIso8601String().substring(11, 23);
    return image.isEmpty ? '$t $text' : '$t [$image] $text';
  }
}

/// The AI sketch HD log: the last [capacity] lines, oldest first.
class AeicHdLog {
  AeicHdLog._();
  static final AeicHdLog instance = AeicHdLog._();

  static const int capacity = 400;

  final List<AeicHdLogEntry> _entries = [];

  /// Bumps on every new line (the diagnostics sheet listens to it).
  final ValueNotifier<int> version = ValueNotifier(0);

  /// The radio's settings, the log's first line (set in main.dart from the
  /// voice service, which knows radio2's).
  String Function()? radioSummary;

  List<AeicHdLogEntry> get entries => List.unmodifiable(_entries);

  /// `prefix/imgId` as the log names an image.
  static String imageTag(int senderPrefix, int imgId) =>
      '${senderPrefix.toRadixString(16).padLeft(4, '0')}/$imgId';

  void add(String text, {String image = ''}) {
    _entries.add(AeicHdLogEntry(DateTime.now(), image, text));
    if (_entries.length > capacity) {
      _entries.removeRange(0, _entries.length - capacity);
    }
    version.value++;
  }

  /// The whole log as text, newest first, under the radio summary.
  String text() => [
    radioSummary?.call() ?? '',
    ..._entries.reversed.map((e) => e.toString()),
  ].where((l) => l.isNotEmpty).join('\n');

  @visibleForTesting
  void clear() {
    _entries.clear();
    version.value++;
  }
}
