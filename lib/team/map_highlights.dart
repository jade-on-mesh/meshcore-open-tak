// MeshCore Open TAK - new points on the map flash for a while.
//
// A teammate, a pin, a shared point, a report or a watched channel's report
// that appears on the map gets a pulsing ring for 10 minutes (Settings > App
// settings > Map display). Mirrored on Wadamesh's map (UITask.cpp,
// "new point highlight").

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MapHighlights extends ChangeNotifier {
  MapHighlights._();
  static final MapHighlights instance = MapHighlights._();

  /// Choices offered in settings, in minutes; 0 turns it off.
  static const List<int> choicesMinutes = [0, 1, 5, 10, 15, 30, 60, 120];
  static const int defaultMinutes = 10;
  static const _key = 'map_new_point_highlight_minutes';

  /// A point already older than this, plus the highlight time, when it
  /// first shows up (loaded from storage, or relayed very late) isn't new.
  static const Duration _clockSlack = Duration(minutes: 5);

  int _minutes = defaultMinutes;
  final Map<String, DateTime> _firstSeen = {};
  Timer? _expiry;
  DateTime? _expiryAt;

  int get minutes => _minutes;
  Duration get duration => Duration(minutes: _minutes);

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final v = prefs.getInt(_key);
      if (v != null && v >= 0) _minutes = v;
    } catch (_) {}
  }

  Future<void> setMinutes(int minutes) async {
    _minutes = max(0, minutes);
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_key, _minutes);
    } catch (_) {}
  }

  /// Whether the point [key] should flash now. The first call for a key is
  /// when it appeared. [itemTime], when known, is when the point was made:
  /// one already old when it first appears is not highlighted.
  bool isNew(String key, {DateTime? itemTime, DateTime? now}) {
    final t = now ?? DateTime.now();
    final seen = _firstSeen.putIfAbsent(key, () => t);
    if (_minutes == 0) return false;
    final d = duration;
    if (itemTime != null && seen.difference(itemTime) > d + _clockSlack) {
      return false;
    }
    final until = seen.add(d);
    if (!t.isBefore(until)) return false;
    _wakeAt(until);
    return true;
  }

  /// Rebuild the map when the next highlight runs out.
  void _wakeAt(DateTime at) {
    final current = _expiryAt;
    if (current != null && !at.isBefore(current) && _expiry != null) return;
    _expiry?.cancel();
    _expiryAt = at;
    final wait = at.difference(DateTime.now());
    _expiry = Timer(
      wait.isNegative ? Duration.zero : wait + const Duration(milliseconds: 50),
      () {
        _expiry = null;
        _expiryAt = null;
        notifyListeners();
      },
    );
  }

  @visibleForTesting
  void resetForTest({int minutes = defaultMinutes}) {
    _firstSeen.clear();
    _expiry?.cancel();
    _expiry = null;
    _expiryAt = null;
    _minutes = minutes;
  }
}
