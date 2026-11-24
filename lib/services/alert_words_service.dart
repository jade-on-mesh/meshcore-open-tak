import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// The alert-word colour (Channels tab badge, channel list badge, message
/// chip and frame, highlighted word): a dark blue that white text reads on
/// in light and dark themes.
const Color alertBadgeColor = Color(0xFF1D4ED8);
import 'package:shared_preferences/shared_preferences.dart';

/// Alert words: words or phrases that make a channel message count like an
/// @mention. A dark-blue badge counts them on the Channels tab and in the
/// channel list; the message gets a blue frame, a bell chip naming the word,
/// and the word highlighted. Set per channel (the channel's ⋮ › Alert words)
/// or for every channel (App Settings › Messaging), on this phone only:
/// nothing about them goes over the air.
///
/// A word matches whole (case doesn't matter): "ice" matches "ICE" and
/// "Ice," but not "nice" or "icecream". A phrase matches as written, words
/// in order, any capitals.
class AlertWordsService extends ChangeNotifier {
  AlertWordsService._();

  static final AlertWordsService instance = AlertWordsService._();

  static const String _prefsKey = 'alert_words_v1';

  /// The longest word or phrase kept.
  static const int maxLength = 40;

  /// The most words a list holds.
  static const int maxWords = 30;

  List<String> _global = const [];
  bool _notify = true;
  Map<String, List<String>> _channels = const {};
  Set<String> _noGlobal = const {};
  bool _loaded = false;

  /// Words for every channel (App Settings).
  List<String> get globalWords => _global;

  /// A notification for an alert word even in a channel set to Mentions only.
  bool get notify => _notify;

  bool get loaded => _loaded;

  /// [channelKey]'s own words (a channel's `muteKey`).
  List<String> channelWords(String channelKey) =>
      _channels[channelKey] ?? const [];

  /// Whether [channelKey] also uses the global words (on unless opted out).
  bool usesGlobal(String channelKey) => !_noGlobal.contains(channelKey);

  /// Everything that alerts in [channelKey]: its own words, then the global
  /// ones unless it opted out, each once.
  List<String> wordsFor(String channelKey) {
    final own = channelWords(channelKey);
    final global = usesGlobal(channelKey) ? _global : const <String>[];
    if (global.isEmpty) return own;
    if (own.isEmpty) return global;
    final seen = <String>{};
    return [
      for (final w in [...own, ...global])
        if (seen.add(w.toLowerCase())) w,
    ];
  }

  /// Whether any channel has alert words at all (skips the work otherwise).
  bool get any => _global.isNotEmpty || _channels.isNotEmpty;

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw != null) _apply(jsonDecode(raw) as Map<String, dynamic>);
    } catch (e) {
      debugPrint('Alert words: could not load ($e)');
    }
    _loaded = true;
    notifyListeners();
  }

  void _apply(Map<String, dynamic> json) {
    List<String> words(Object? v) => [
      for (final w in (v as List? ?? const []))
        if (w is String && normalize(w).isNotEmpty) normalize(w),
    ];
    _global = words(json['global']);
    _notify = json['notify'] as bool? ?? true;
    _channels = {
      for (final e in ((json['channels'] as Map?) ?? const {}).entries)
        if (e.key is String && words(e.value).isNotEmpty)
          e.key as String: words(e.value),
    };
    _noGlobal = {
      for (final k in (json['noGlobal'] as List? ?? const []))
        if (k is String) k,
    };
  }

  Future<void> _save() async {
    _cache.clear();
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _prefsKey,
        jsonEncode({
          'global': _global,
          'notify': _notify,
          'channels': _channels,
          'noGlobal': _noGlobal.toList(),
        }),
      );
    } catch (e) {
      debugPrint('Alert words: could not save ($e)');
    }
  }

  /// Trimmed, inner runs of spaces made one, at most [maxLength] characters.
  static String normalize(String word) {
    final w = word.trim().replaceAll(RegExp(r'\s+'), ' ');
    return w.length > maxLength ? w.substring(0, maxLength).trim() : w;
  }

  static List<String> _added(List<String> list, String word) {
    final w = normalize(word);
    if (w.isEmpty || list.length >= maxWords) return list;
    if (list.any((x) => x.toLowerCase() == w.toLowerCase())) return list;
    return [...list, w];
  }

  /// Adds [word] to the global list. False when it was empty, already there
  /// or the list is full.
  Future<bool> addGlobal(String word) async {
    final next = _added(_global, word);
    if (identical(next, _global)) return false;
    _global = next;
    await _save();
    return true;
  }

  Future<void> removeGlobal(String word) async {
    _global = [
      for (final w in _global)
        if (w.toLowerCase() != word.toLowerCase()) w,
    ];
    await _save();
  }

  Future<void> clearGlobal() async {
    _global = const [];
    await _save();
  }

  Future<void> setNotify(bool value) async {
    _notify = value;
    await _save();
  }

  Future<bool> addChannel(String channelKey, String word) async {
    final current = channelWords(channelKey);
    final next = _added(current, word);
    if (identical(next, current)) return false;
    _channels = {..._channels, channelKey: next};
    await _save();
    return true;
  }

  Future<void> removeChannel(String channelKey, String word) async {
    final next = [
      for (final w in channelWords(channelKey))
        if (w.toLowerCase() != word.toLowerCase()) w,
    ];
    _channels = {..._channels};
    if (next.isEmpty) {
      _channels.remove(channelKey);
    } else {
      _channels[channelKey] = next;
    }
    await _save();
  }

  Future<void> clearChannel(String channelKey) async {
    _channels = {..._channels}..remove(channelKey);
    await _save();
  }

  Future<void> setUsesGlobal(String channelKey, bool value) async {
    _noGlobal = {..._noGlobal};
    if (value) {
      _noGlobal.remove(channelKey);
    } else {
      _noGlobal.add(channelKey);
    }
    await _save();
  }

  final Map<String, RegExp?> _cache = {};

  /// One pattern for [words]: each a whole word or phrase, any capitals.
  /// Null for no words.
  RegExp? patternFor(List<String> words) {
    if (words.isEmpty) return null;
    final key = words.join('\u0000');
    return _cache.putIfAbsent(key, () => alertPattern(words));
  }

  /// The first alert word in [text] (as written in the list), or null.
  String? firstMatch(String text, List<String> words) =>
      matchIn(text, patternFor(words), words);

  @visibleForTesting
  void resetForTest() {
    _global = const [];
    _notify = true;
    _channels = const {};
    _noGlobal = const {};
    _cache.clear();
    _loaded = false;
  }
}

/// A pattern matching any of [words] whole: not inside a longer word (letters
/// and digits on either side don't match), any capitals; spaces in a phrase
/// match any run of spaces.
RegExp alertPattern(List<String> words) {
  final parts = [
    for (final w in words)
      RegExp.escape(w).replaceAll(r'\ ', ' ').split(' ').join(r'\s+'),
  ]..sort((a, b) => b.length.compareTo(a.length));
  return RegExp(
    '(?<![\\p{L}\\p{N}_])(?:${parts.join('|')})(?![\\p{L}\\p{N}_])',
    caseSensitive: false,
    unicode: true,
  );
}

/// The list's own spelling of the first alert word [pattern] finds in [text].
String? matchIn(String text, RegExp? pattern, List<String> words) {
  if (pattern == null || text.isEmpty) return null;
  final m = pattern.firstMatch(text);
  if (m == null) return null;
  final found = m[0]!.replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
  for (final w in words) {
    if (w.toLowerCase() == found) return w;
  }
  return m[0];
}

/// Alert words to highlight in the message text below it
/// (LinkHandler's message text reads this).
class AlertWordHighlight extends InheritedWidget {
  final RegExp? pattern;

  const AlertWordHighlight({
    super.key,
    required this.pattern,
    required super.child,
  });

  static RegExp? of(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<AlertWordHighlight>()
      ?.pattern;

  @override
  bool updateShouldNotify(AlertWordHighlight oldWidget) =>
      oldWidget.pattern?.pattern != pattern?.pattern;
}
