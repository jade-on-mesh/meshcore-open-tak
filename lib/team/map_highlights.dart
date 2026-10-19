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

import 'team_service.dart';
import 'watch_feed.dart';

/// A point that can flash: its key, when it was made (if known), where it
/// is, and its own ring colour (null: the default cyan).
class HighlightPoint {
  final String key;
  final DateTime? time;
  final double lat, lon;
  final int? argb;
  const HighlightPoint(this.key, this.time, this.lat, this.lon, [this.argb]);
}

/// Teammates (not this phone), their pins, shared points, reports and
/// CASEVACs, and watched channels' reports on the map. A drone that keeps
/// reporting is one point (its serial).
Iterable<HighlightPoint> highlightPointsOf(
  TeamService team,
  List<WatchItem> watched,
) sync* {
  final self = team.selfKey4;
  for (final w in watched) {
    if (w.lat == null || w.lon == null) continue;
    yield HighlightPoint(
      w.trackId != null ? 'w:${w.channel.index}:${w.trackId}' : 'w:${w.key}',
      w.time,
      w.lat!,
      w.lon!,
      w.level.argb,
    );
  }
  for (final p in team.points) {
    if (p.authorKey4 != self) {
      yield HighlightPoint('pt:${p.key}', p.time, p.lat, p.lon);
    }
  }
  for (final r in team.reports) {
    if (r.authorKey4 != self) {
      yield HighlightPoint('r:${r.key}', r.observed, r.lat, r.lon);
    }
  }
  for (final c in team.casevacs) {
    if (c.authorKey4 != self) {
      yield HighlightPoint('c:${c.key}', c.time, c.lat, c.lon);
    }
  }
  for (final m in team.markers) {
    if (m.authorKey4 != self) {
      yield HighlightPoint('p:${m.key}', m.time, m.lat, m.lon);
    }
  }
  for (final m in team.members) {
    if (m.key4 != self) {
      yield HighlightPoint(
        'm:${m.key4}',
        null,
        m.position.lat,
        m.position.lon,
        m.position.color.argb,
      );
    }
  }
}

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

  TeamService? _team;
  WatchFeedService? _watch;
  DateTime? _attachedAt;

  /// Teammates already there in the first seconds (loaded from storage)
  /// aren't new.
  static const Duration _settle = Duration(seconds: 5);

  int get minutes => _minutes;

  /// Notes points as they arrive, so "new" means new here, map open or not.
  void attach(TeamService team, WatchFeedService watch) {
    _team = team;
    _watch = watch;
    _attachedAt = DateTime.now();
    team.addListener(_observe);
    watch.addListener(_observe);
    Timer(_settle + const Duration(seconds: 1), _observe);
    _observe();
  }

  void _observe() {
    final team = _team, watch = _watch, at = _attachedAt;
    if (team == null || watch == null || at == null) return;
    final now = DateTime.now();
    final settling = now.difference(at) < _settle;
    for (final p in highlightPointsOf(team, watch.mapItems)) {
      if (settling && p.key.startsWith('m:')) {
        _firstSeen.putIfAbsent(p.key, () => DateTime(2000));
      } else {
        _firstSeen.putIfAbsent(p.key, () => now);
      }
    }
  }
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
