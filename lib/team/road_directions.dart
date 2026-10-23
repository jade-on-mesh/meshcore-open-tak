// MeshCore Open TAK - road directions for Bloodhound.
//
// A route along roads or paths to what Bloodhound tracks, from a Valhalla
// routing server (valhalla.github.io/valhalla: open source, OpenStreetMap
// data). The default is the public FOSSGIS server, which is for light use; a
// team can run its own and set its address in the Directions sheet.
//
// RoadGuide follows the route as the phone moves: the next maneuver and how
// far to it, what is left, and whether the phone has left the route (so the
// caller asks for a new one). TeamService ties it to Bloodhound, and can
// share the route with the team as an ordinary route shape, which standalone
// radios follow too (Wadamesh TAK: TeamRoute.h).
//
// Only directions need the internet. With no signal Bloodhound carries on with
// range and bearing.

import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'team_wire.dart';

const String defaultRoutingServer = 'https://valhalla1.openstreetmap.de';

/// How the route is travelled (Valhalla's costing models).
enum RoadMode {
  drive('auto'),
  walk('pedestrian'),
  bike('bicycle');

  const RoadMode(this.costing);
  final String costing;

  static RoadMode fromName(String? n) =>
      RoadMode.values.firstWhere((m) => m.name == n, orElse: () => drive);
}

class RoadManeuver {
  /// "Turn left onto Pine Street."
  final String instruction;

  /// Valhalla's maneuver type (turn, ramp, roundabout, destination...).
  final int type;

  /// The shape vertex it happens at.
  final int beginIndex;

  /// Street names after it, if any.
  final List<String> streets;

  /// Valhalla's words for speaking it: well before ("Turn left onto Pine
  /// Street."), at it, and after ("Continue for 2 kilometers.").
  final String? verbalAlert;
  final String? verbalPre;
  final String? verbalPost;

  const RoadManeuver({
    required this.instruction,
    required this.type,
    required this.beginIndex,
    this.streets = const [],
    this.verbalAlert,
    this.verbalPre,
    this.verbalPost,
  });

  String get sayAlert => verbalAlert ?? verbalPre ?? instruction;
  String get sayNow => verbalPre ?? instruction;

  bool get isDestination => type >= 4 && type <= 6;
}

class RoadRoute {
  final RoadMode mode;
  final List<(double, double)> shape;
  final List<RoadManeuver> maneuvers;
  final double lengthM;
  final double timeS;

  /// Where it was asked to go (Bloodhound's target at the time).
  final (double, double) to;

  const RoadRoute({
    required this.mode,
    required this.shape,
    required this.maneuvers,
    required this.lengthM,
    required this.timeS,
    required this.to,
  });
}

class RoadRouteError implements Exception {
  final String message;
  const RoadRouteError(this.message);
  @override
  String toString() => message;
}

/// Google's encoded polyline at 6 decimals, as Valhalla sends shapes.
List<(double, double)> decodePolyline6(String s) {
  final out = <(double, double)>[];
  var i = 0, lat = 0, lon = 0;
  int next() {
    var shift = 0, result = 0, b = 0;
    do {
      if (i >= s.length) throw const FormatException('cut-off polyline');
      b = s.codeUnitAt(i++) - 63;
      result |= (b & 0x1F) << shift;
      shift += 5;
    } while (b >= 0x20);
    return (result & 1) != 0 ? ~(result >> 1) : result >> 1;
  }

  while (i < s.length) {
    lat += next();
    lon += next();
    out.add((lat / 1e6, lon / 1e6));
  }
  return out;
}

String? _text(Object? v) => v is String && v.trim().isNotEmpty ? v : null;

/// A Valhalla /route answer (one leg) as a [RoadRoute].
RoadRoute parseValhallaRoute(
  Map<String, dynamic> json, {
  required RoadMode mode,
  required (double, double) to,
}) {
  final trip = json['trip'];
  if (trip is! Map) throw const RoadRouteError('No route in the answer');
  final legs = trip['legs'];
  if (legs is! List || legs.isEmpty) {
    throw const RoadRouteError('No route in the answer');
  }
  final shape = <(double, double)>[];
  final maneuvers = <RoadManeuver>[];
  for (final leg in legs) {
    final offset = shape.isEmpty ? 0 : shape.length - 1;
    final pts = decodePolyline6('${(leg as Map)['shape'] ?? ''}');
    shape.addAll(shape.isEmpty ? pts : pts.skip(1));
    for (final m in (leg['maneuvers'] as List? ?? const [])) {
      final map = m as Map;
      maneuvers.add(
        RoadManeuver(
          instruction: '${map['instruction'] ?? ''}',
          type: (map['type'] as num?)?.toInt() ?? 0,
          beginIndex:
              offset + ((map['begin_shape_index'] as num?)?.toInt() ?? 0),
          streets: [
            for (final n in (map['street_names'] as List? ?? const [])) '$n',
          ],
          verbalAlert: _text(map['verbal_transition_alert_instruction']),
          verbalPre: _text(map['verbal_pre_transition_instruction']),
          verbalPost: _text(map['verbal_post_transition_instruction']),
        ),
      );
    }
  }
  if (shape.length < 2) throw const RoadRouteError('The route is empty');
  final summary = trip['summary'] as Map? ?? const {};
  return RoadRoute(
    mode: mode,
    shape: shape,
    maneuvers: maneuvers,
    lengthM: ((summary['length'] as num?)?.toDouble() ?? 0) * 1000,
    timeS: (summary['time'] as num?)?.toDouble() ?? 0,
    to: to,
  );
}

/// Asks a Valhalla server for routes.
class RoadRouter {
  final http.Client _client;
  final String server;

  RoadRouter({http.Client? client, String? server})
    : _client = client ?? http.Client(),
      server = _clean(server);

  static String _clean(String? s) {
    final t = (s ?? '').trim();
    if (t.isEmpty) return defaultRoutingServer;
    final withScheme = t.contains('://') ? t : 'https://$t';
    return withScheme.endsWith('/')
        ? withScheme.substring(0, withScheme.length - 1)
        : withScheme;
  }

  Future<RoadRoute> route(
    (double, double) from,
    (double, double) to,
    RoadMode mode, {
    String language = 'en-US',
  }) async {
    final body = jsonEncode({
      'locations': [
        {'lat': from.$1, 'lon': from.$2},
        {'lat': to.$1, 'lon': to.$2},
      ],
      'costing': mode.costing,
      'directions_options': {'units': 'kilometers', 'language': language},
    });
    final http.Response r;
    try {
      r = await _client
          .post(
            Uri.parse('$server/route'),
            headers: const {
              'Content-Type': 'application/json',
              'User-Agent': 'MeshCoreOpenTAK',
            },
            body: body,
          )
          .timeout(const Duration(seconds: 25));
    } catch (e) {
      throw RoadRouteError("Can't reach the routing server ($e)");
    }
    Map<String, dynamic>? json;
    try {
      json = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {}
    if (r.statusCode != 200 || json == null) {
      final why = json?['error'];
      throw RoadRouteError(
        why is String && why.isNotEmpty
            ? why
            : 'The routing server answered ${r.statusCode}',
      );
    }
    try {
      return parseValhallaRoute(json, mode: mode, to: to);
    } on RoadRouteError {
      rethrow;
    } catch (e) {
      throw RoadRouteError("Couldn't read the route ($e)");
    }
  }
}

/// Where the phone is along a [RoadRoute].
class RoadProgress {
  /// Index into the route's maneuvers of the next one to do.
  final int next;

  /// Metres along the route to it.
  final double toNextM;

  /// Metres along the route to the end.
  final double remainingM;

  /// Metres from the route line.
  final double offRouteM;

  final bool arrived;

  const RoadProgress({
    required this.next,
    required this.toNextM,
    required this.remainingM,
    required this.offRouteM,
    required this.arrived,
  });
}

/// Follows a [RoadRoute] fix by fix.
class RoadGuide {
  final RoadRoute route;
  late final List<(double, double)> _xy; // metres, local projection
  late final List<double> _cum; // metres along the route at each vertex
  final double _lat0, _cosLat;
  int _seg = 0;

  /// Metres from the end that count as arrived.
  static const double arriveM = 25;

  RoadGuide(this.route)
    : _lat0 = route.shape.first.$1,
      _cosLat = cos(route.shape.first.$1 * pi / 180) {
    _xy = [for (final p in route.shape) _project(p.$1, p.$2)];
    _cum = [0];
    for (var i = 1; i < _xy.length; i++) {
      _cum.add(_cum[i - 1] + _dist(_xy[i - 1], _xy[i]));
    }
  }

  double get lengthM => _cum.last;

  (double, double) _project(double lat, double lon) => (
    (lon - route.shape.first.$2) * 111320.0 * _cosLat,
    (lat - _lat0) * 110540.0,
  );

  static double _dist((double, double) a, (double, double) b) {
    final dx = a.$1 - b.$1, dy = a.$2 - b.$2;
    return sqrt(dx * dx + dy * dy);
  }

  /// Distance from p to segment i, and how far along it (0..1).
  (double, double) _toSegment((double, double) p, int i) {
    final a = _xy[i], b = _xy[i + 1];
    final dx = b.$1 - a.$1, dy = b.$2 - a.$2;
    final len2 = dx * dx + dy * dy;
    var t = len2 == 0 ? 0.0 : ((p.$1 - a.$1) * dx + (p.$2 - a.$2) * dy) / len2;
    t = t.clamp(0.0, 1.0);
    return (_dist(p, (a.$1 + t * dx, a.$2 + t * dy)), t);
  }

  RoadProgress update(double lat, double lon) {
    final p = _project(lat, lon);
    final segs = _xy.length - 1;
    // Near where it was last (a route can pass the same spot twice); the
    // whole route when that is far off.
    var best = double.infinity, bestSeg = _seg, bestT = 0.0;
    void scan(int from, int to) {
      for (var i = max(0, from); i < min(segs, to); i++) {
        final (d, t) = _toSegment(p, i);
        if (d < best) {
          best = d;
          bestSeg = i;
          bestT = t;
        }
      }
    }

    scan(_seg - 2, _seg + 40);
    if (best > 60) scan(0, segs);
    _seg = bestSeg;
    final segLen = _cum[bestSeg + 1] - _cum[bestSeg];
    final along = _cum[bestSeg] + bestT * segLen;
    final remaining = max(0.0, lengthM - along);

    // The next maneuver starts at a vertex further along than us.
    var next = route.maneuvers.length - 1;
    for (var m = 0; m < route.maneuvers.length; m++) {
      final at = _cum[min(route.maneuvers[m].beginIndex, _cum.length - 1)];
      if (at > along + 3) {
        next = m;
        break;
      }
    }
    final nextAt = next >= 0
        ? _cum[min(route.maneuvers[next].beginIndex, _cum.length - 1)]
        : lengthM;
    return RoadProgress(
      next: next,
      toNextM: max(0.0, nextAt - along),
      remainingM: remaining,
      offRouteM: best,
      arrived: remaining <= arriveM && best <= 60,
    );
  }
}

/// How far off the route counts as off it, by mode.
double roadOffRouteM(RoadMode m) => m == RoadMode.walk ? 40 : 60;

/// The route made small enough to share as one team route shape: thinned
/// (keeping its turns) and, if still long, labelled as such by the caller.
List<(double, double)> roadRouteForTeam(RoadRoute r) {
  var pts = teamSimplify(r.shape, r.mode == RoadMode.walk ? 5 : 10);
  if (pts.length > teamMaxShapePoints) {
    pts = teamSimplify(r.shape, r.mode == RoadMode.walk ? 15 : 30);
  }
  return pts;
}

/// "350 m", "1.2 km", "14 km".
String roadDistance(double m) {
  if (m < 1000) {
    final r = m < 100 ? (m / 10).round() * 10 : (m / 50).round() * 50;
    return '$r m';
  }
  return '${(m / 1000).toStringAsFixed(m >= 10000 ? 0 : 1)} km';
}

/// "8 min", "1 h 20 min".
String roadDuration(double s) {
  final min = (s / 60).round();
  if (min < 60) return '${max(1, min)} min';
  return '${min ~/ 60} h ${min % 60} min';
}

/// The next turn on a route followed checkpoint by checkpoint (a route the
/// team shared), read from its shape as standalone radios do (Wadamesh TAK's
/// TeamRoute.h): a bend of 30° or more is a turn.
class RouteTurn {
  /// Degrees, + right, - left; 0 when nothing but the end is ahead.
  final int turnDeg;

  /// Metres to the turn (or to the end, with no turn).
  final double toTurnM;
  final double remainingM;

  /// The route vertex it is at (-1: none, only the end).
  final int at;

  const RouteTurn(this.turnDeg, this.toTurnM, this.remainingM, [this.at = -1]);

  bool get hasTurn => turnDeg != 0;
}

int routeTurnAt(List<(double, double)> pts, int i) {
  if (i <= 0 || i >= pts.length - 1) return 0;
  final a = teamBearingDeg(pts[i - 1].$1, pts[i - 1].$2, pts[i].$1, pts[i].$2);
  final b = teamBearingDeg(pts[i].$1, pts[i].$2, pts[i + 1].$1, pts[i + 1].$2);
  var d = (b - a + 540) % 360 - 180;
  if (d < -180) d += 360;
  return d.round();
}

/// From (lat, lon), heading for checkpoint [next] of [pts].
RouteTurn routeNextTurn(
  List<(double, double)> pts,
  int next,
  double lat,
  double lon,
) {
  if (pts.isEmpty) return const RouteTurn(0, 0, 0);
  final k = next.clamp(0, pts.length - 1);
  var along = teamDistanceMeters(lat, lon, pts[k].$1, pts[k].$2);
  var turn = 0, toTurn = -1.0, at = -1;
  for (var i = k; i < pts.length; i++) {
    if (i > k) {
      along += teamDistanceMeters(
        pts[i - 1].$1,
        pts[i - 1].$2,
        pts[i].$1,
        pts[i].$2,
      );
    }
    final t = routeTurnAt(pts, i);
    if (toTurn < 0 && t.abs() >= 30) {
      turn = t;
      toTurn = along;
      at = i;
    }
  }
  return RouteTurn(turn, toTurn < 0 ? along : toTurn, along, at);
}
