// MeshCore Open TAK - spoken turn prompts for Bloodhound: what to say, and
// when, as the phone moves along road directions (road_directions.dart) or a
// route the team shared. Speaking itself is SpeechService's.
//
// Each turn is announced twice: well before it ("In 400 meters, turn left onto
// Pine Street") and as it comes up ("Turn left onto Pine Street"). Road
// directions use Valhalla's own spoken-style instructions, in the language
// they were asked for; a shared route's turns come from its shape.

import 'road_directions.dart';

/// The words the announcer needs that don't come from Valhalla (the app's
/// language; RoadVoiceWords.of in road_directions_ui.dart).
class RoadVoiceWords {
  /// "In {distance}, {what}".
  final String Function(String distance, String what) inDistance;

  /// A distance as said aloud: "400 meters", "1.5 kilometers".
  final String Function(double meters) distance;

  /// "Turn left", "Slight right"... for a turn of [deg] (+ right).
  final String Function(int deg) turn;
  final String arrived;
  final String rerouting;

  const RoadVoiceWords({
    required this.inDistance,
    required this.distance,
    required this.turn,
    required this.arrived,
    required this.rerouting,
  });

  static final RoadVoiceWords english = RoadVoiceWords(
    inDistance: (d, w) => 'In $d, $w',
    distance: spokenDistanceEnglish,
    turn: (deg) {
      final a = deg.abs();
      if (a >= 160) return 'Make a U-turn';
      final side = deg < 0 ? 'left' : 'right';
      if (a < 60) return 'Bear $side';
      if (a < 120) return 'Turn $side';
      return 'Turn sharp $side';
    },
    arrived: 'You have arrived.',
    rerouting: 'Rerouting.',
  );
}

/// A distance rounded the way it is said: 10 m steps under 100 m, 50 m under
/// a kilometre, then tenths of a kilometre (whole ones from 10 km).
(int meters, String km) spokenRound(double m) {
  if (m < 100) return ((m / 10).round() * 10, '');
  if (m < 1000) {
    final r = (m / 50).round() * 50;
    if (r < 1000) return (r, '');
  }
  final km = m / 1000;
  return (0, km >= 10 ? km.round().toString() : km.toStringAsFixed(1));
}

String spokenDistanceEnglish(double m) {
  final (meters, km) = spokenRound(m);
  return km.isEmpty ? '$meters meters' : '$km kilometers';
}

/// When to speak: well before a turn, and as it comes up, by how fast the
/// route is travelled.
({double far, double near}) roadVoiceDistances(RoadMode m) => switch (m) {
  RoadMode.drive => (far: 500.0, near: 80.0),
  RoadMode.bike => (far: 200.0, near: 35.0),
  RoadMode.walk => (far: 100.0, near: 20.0),
};

class RoadAnnouncer {
  Object? _route; // the route the stages below are about
  int _key = -2; // the maneuver (or route vertex) being announced
  int _stage = 0; // 0 nothing said, 1 the early call, 2 the call at the turn
  bool _arrived = false;

  void reset() {
    _route = null;
    _key = -2;
    _stage = 0;
    _arrived = false;
  }

  /// What to say now on road directions, if anything.
  String? road(RoadRoute r, RoadProgress p, RoadVoiceWords w) {
    String? lead;
    if (!identical(r, _route)) {
      lead = _route == null ? r.maneuvers.firstOrNull?.sayNow : w.rerouting;
      _route = r;
      _key = -2;
      _stage = 0;
      _arrived = false;
    }
    if (p.arrived) {
      if (_arrived) return lead;
      _arrived = true;
      return _join(lead, w.arrived);
    }
    if (p.next < 0 || p.next >= r.maneuvers.length) return lead;
    final t = roadVoiceDistances(r.mode);
    if (p.next != _key) {
      // Just past a turn: say how long the next stretch is, when the next
      // call is still some way off.
      final passed = _key;
      _key = p.next;
      _stage = 0;
      if (lead == null &&
          passed >= 0 &&
          passed < r.maneuvers.length &&
          p.toNextM > t.far) {
        lead = r.maneuvers[passed].verbalPost;
      }
    }
    final m = r.maneuvers[p.next];
    if (p.toNextM <= t.near && _stage < 2) {
      _stage = 2;
      // The destination is said as "you have arrived" when it is reached.
      return m.isDestination ? lead : _join(lead, m.sayNow);
    }
    if (p.toNextM <= t.far && _stage < 1) {
      _stage = 1;
      return _join(lead, w.inDistance(w.distance(p.toNextM), m.sayAlert));
    }
    return lead;
  }

  /// What to say now while following a shared route ([routeKey] tells routes
  /// apart), if anything.
  String? sharedRoute(
    String routeKey,
    RouteTurn turn,
    RoadMode mode,
    RoadVoiceWords w,
  ) {
    if (_route != routeKey) {
      _route = routeKey;
      _key = -2;
      _stage = 0;
      _arrived = false;
    }
    final t = roadVoiceDistances(mode);
    final key = turn.hasTurn ? turn.at : -1;
    if (key != _key) {
      _key = key;
      _stage = 0;
    }
    if (!turn.hasTurn) {
      if (turn.toTurnM <= RoadGuide.arriveM) {
        if (_arrived) return null;
        _arrived = true;
        return w.arrived;
      }
      return null;
    }
    final what = w.turn(turn.turnDeg);
    if (turn.toTurnM <= t.near && _stage < 2) {
      _stage = 2;
      return what;
    }
    if (turn.toTurnM <= t.far && _stage < 1) {
      _stage = 1;
      return w.inDistance(w.distance(turn.toTurnM), what);
    }
    return null;
  }

  static String? _join(String? a, String? b) {
    if (a == null || a.isEmpty) return b;
    if (b == null || b.isEmpty) return a;
    return '$a $b';
  }
}
