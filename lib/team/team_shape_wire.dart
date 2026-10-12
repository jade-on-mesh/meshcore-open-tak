// MeshCore Open TAK - drawings, routes and geofences on the team channel.
//
// One message carries one shape. Points are on a 1e-5 degree grid (about a
// metre): the first as two i32, the rest as zigzag varint deltas, so a
// typical 30-point route is about 130 bytes. Freehand lines are simplified
// until they fit one packet.

part of 'team_wire.dart';

enum ShapeKind {
  line('Line'),
  freehand('Freehand'),
  polygon('Polygon'),
  rectangle('Rectangle'),
  circle('Circle'),
  route('Route');

  const ShapeKind(this.label);
  final String label;

  bool get closed => this == polygon || this == rectangle || this == circle;

  static ShapeKind fromIndex(int i) =>
      i >= 0 && i < values.length ? values[i] : line;
}

/// When a geofence alerts.
enum TeamGeofence {
  off('Off'),
  entry('Entry'),
  exit('Exit'),
  both('Entry and exit');

  const TeamGeofence(this.label);
  final String label;

  bool get onEntry => this == entry || this == both;
  bool get onExit => this == exit || this == both;

  static TeamGeofence fromIndex(int i) =>
      i >= 0 && i < values.length ? values[i] : off;
}

/// How a route is travelled (ATAK route methods).
enum RouteMethod {
  walking('Walking'),
  driving('Driving'),
  flying('Flying'),
  swimming('Swimming'),
  watercraft('Watercraft');

  const RouteMethod(this.label);
  final String label;

  static RouteMethod fromIndex(int i) =>
      i >= 0 && i < values.length ? values[i] : walking;
}

const int teamMaxShapeLabelBytes = 24;
const int teamMaxShapePoints = 120;

int _grid(double v) => (v * 1e5).round();
double _ungrid(int v) => v / 1e5;

class TeamShape {
  final String authorKey4;
  final int shapeId;
  final bool deleted;
  final ShapeKind kind;
  final TeamColor color;
  final DateTime time;
  final String label;
  final TeamGeofence geofence;
  final RouteMethod routeMethod;

  /// Circle radius in metres (circles only).
  final int radiusM;

  /// Vertices (lat, lon). A circle has one: its centre.
  final List<(double, double)> points;

  const TeamShape({
    required this.authorKey4,
    required this.shapeId,
    required this.kind,
    required this.time,
    required this.points,
    this.color = TeamColor.yellow,
    this.label = '',
    this.deleted = false,
    this.geofence = TeamGeofence.off,
    this.routeMethod = RouteMethod.walking,
    this.radiusM = 0,
  });

  String get key => '$authorKey4:${shapeId.toRadixString(16)}';

  bool get isGeofence => kind.closed && geofence != TeamGeofence.off;

  String get title => label.isNotEmpty ? label : kind.label;

  TeamShape copyWith({
    bool? deleted,
    TeamColor? color,
    DateTime? time,
    String? label,
    TeamGeofence? geofence,
    RouteMethod? routeMethod,
    int? radiusM,
    List<(double, double)>? points,
  }) => TeamShape(
    authorKey4: authorKey4,
    shapeId: shapeId,
    kind: kind,
    deleted: deleted ?? this.deleted,
    color: color ?? this.color,
    time: time ?? this.time,
    label: label ?? this.label,
    geofence: geofence ?? this.geofence,
    routeMethod: routeMethod ?? this.routeMethod,
    radiusM: radiusM ?? this.radiusM,
    points: points ?? this.points,
  );

  Uint8List encode() {
    final w = _W()
      ..u8(teamMsgShape)
      ..bytes(_key4(authorKey4))
      ..u32(shapeId)
      ..u8(deleted ? 1 : 0)
      ..u8(kind.index)
      ..u8(color.index)
      ..u32(time.millisecondsSinceEpoch ~/ 1000)
      ..str(label, teamMaxShapeLabelBytes)
      ..u8(kind.closed ? geofence.index : 0)
      ..varint(kind == ShapeKind.circle ? radiusM : routeMethod.index);
    final pts = points.length > teamMaxShapePoints
        ? points.sublist(0, teamMaxShapePoints)
        : points;
    w.u8(pts.length);
    var plat = 0, plon = 0;
    for (var i = 0; i < pts.length; i++) {
      final lat = _grid(pts[i].$1), lon = _grid(pts[i].$2);
      if (i == 0) {
        w
          ..i32(lat)
          ..i32(lon);
      } else {
        w
          ..svarint(lat - plat)
          ..svarint(lon - plon);
      }
      plat = lat;
      plon = lon;
    }
    return w.done();
  }

  static TeamShape? tryParse(Uint8List p) {
    final r = _R(p);
    if (!r.has(17) || r.u8() != teamMsgShape) return null;
    final key = teamKey4Hex(r.take(4));
    final id = r.u32();
    final op = r.u8();
    final kind = ShapeKind.fromIndex(r.u8());
    final color = TeamColor.fromIndex(r.u8());
    final t = DateTime.fromMillisecondsSinceEpoch(r.u32() * 1000);
    final label = r.str();
    if (label == null || !r.has(1)) return null;
    final geo = TeamGeofence.fromIndex(r.u8());
    final param = r.varint();
    if (param == null || !r.has(1)) return null;
    final n = r.u8();
    final pts = <(double, double)>[];
    var lat = 0, lon = 0;
    for (var i = 0; i < n; i++) {
      if (i == 0) {
        if (!r.has(8)) return null;
        lat = r.i32();
        lon = r.i32();
      } else {
        final dl = r.svarint(), dn = r.svarint();
        if (dl == null || dn == null) return null;
        lat += dl;
        lon += dn;
      }
      final a = _ungrid(lat), b = _ungrid(lon);
      if (a.abs() > 90 || b.abs() > 180) return null;
      pts.add((a, b));
    }
    if (pts.isEmpty && op != 1) return null;
    return TeamShape(
      authorKey4: key,
      shapeId: id,
      deleted: op == 1,
      kind: kind,
      color: color,
      time: t,
      label: label,
      geofence: kind.closed ? geo : TeamGeofence.off,
      routeMethod: kind == ShapeKind.circle
          ? RouteMethod.walking
          : RouteMethod.fromIndex(param),
      radiusM: kind == ShapeKind.circle ? param : 0,
      points: pts,
    );
  }

  /// This shape, with points thinned (Douglas-Peucker, growing tolerance)
  /// until it fits one team packet.
  TeamShape fitted() {
    var s = this;
    if (s.points.length > teamMaxShapePoints) {
      s = s.copyWith(points: teamSimplify(s.points, 1));
    }
    var tol = 2.0;
    while (s.encode().length > teamMaxPayload && s.points.length > 2) {
      final thinner = teamSimplify(points, tol);
      s = s.copyWith(
        points: thinner.length < s.points.length
            ? thinner
            : [
                // Tolerance stopped helping: drop every other vertex.
                for (var i = 0; i < s.points.length; i++)
                  if (i.isEven || i == s.points.length - 1) s.points[i],
              ],
      );
      tol *= 1.6;
    }
    return s;
  }

  // ---------------------------------------------------------- geometry

  /// Total length in metres (closed shapes include the closing edge).
  double get lengthM {
    if (kind == ShapeKind.circle) return 2 * pi * radiusM;
    var d = 0.0;
    for (var i = 1; i < points.length; i++) {
      d += teamDistanceMeters(
        points[i - 1].$1,
        points[i - 1].$2,
        points[i].$1,
        points[i].$2,
      );
    }
    if (kind.closed && points.length > 2) {
      d += teamDistanceMeters(
        points.last.$1,
        points.last.$2,
        points.first.$1,
        points.first.$2,
      );
    }
    return d;
  }

  /// Enclosed area in square metres (closed shapes only).
  double get areaM2 {
    if (kind == ShapeKind.circle) return pi * radiusM * radiusM;
    if (!kind.closed || points.length < 3) return 0;
    final xy = _project(points);
    var a = 0.0;
    for (var i = 0; i < xy.length; i++) {
      final j = (i + 1) % xy.length;
      a += xy[i].$1 * xy[j].$2 - xy[j].$1 * xy[i].$2;
    }
    return a.abs() / 2;
  }

  /// Whether ([lat], [lon]) is inside this (closed) shape.
  bool contains(double lat, double lon) {
    if (points.isEmpty) return false;
    if (kind == ShapeKind.circle) {
      return teamDistanceMeters(points[0].$1, points[0].$2, lat, lon) <=
          radiusM;
    }
    if (!kind.closed || points.length < 3) return false;
    var inside = false;
    for (var i = 0, j = points.length - 1; i < points.length; j = i++) {
      final (yi, xi) = points[i];
      final (yj, xj) = points[j];
      if ((yi > lat) != (yj > lat) &&
          lon < (xj - xi) * (lat - yi) / (yj - yi) + xi) {
        inside = !inside;
      }
    }
    return inside;
  }

  /// A point to hang the label on.
  (double, double) get anchor {
    if (points.isEmpty) return (0, 0);
    if (kind == ShapeKind.circle || !kind.closed) return points.first;
    var la = 0.0, lo = 0.0;
    for (final p in points) {
      la += p.$1;
      lo += p.$2;
    }
    return (la / points.length, lo / points.length);
  }

  /// The outline as points (a circle becomes a [segments]-gon).
  List<(double, double)> outline({int segments = 48}) {
    if (kind != ShapeKind.circle || points.isEmpty) return points;
    final (clat, clon) = points.first;
    final mPerDegLat = 111320.0;
    final mPerDegLon = 111320.0 * cos(clat * pi / 180);
    return [
      for (var i = 0; i <= segments; i++)
        (
          clat + radiusM * cos(2 * pi * i / segments) / mPerDegLat,
          clon +
              radiusM *
                  sin(2 * pi * i / segments) /
                  (mPerDegLon == 0 ? 1 : mPerDegLon),
        ),
    ];
  }
}

/// Local equirectangular projection to metres around the first point.
List<(double, double)> _project(List<(double, double)> pts) {
  if (pts.isEmpty) return const [];
  final lat0 = pts.first.$1 * pi / 180;
  const r = 6371000.0;
  return [
    for (final p in pts)
      (
        (p.$2 - pts.first.$2) * pi / 180 * r * cos(lat0),
        (p.$1 - pts.first.$1) * pi / 180 * r,
      ),
  ];
}

/// Douglas-Peucker simplification with a tolerance in metres.
List<(double, double)> teamSimplify(
  List<(double, double)> pts,
  double toleranceM,
) {
  if (pts.length < 3) return List.of(pts);
  final xy = _project(pts);
  final keep = List<bool>.filled(pts.length, false);
  keep[0] = true;
  keep[pts.length - 1] = true;
  final stack = <(int, int)>[(0, pts.length - 1)];
  while (stack.isNotEmpty) {
    final (a, b) = stack.removeLast();
    var maxD = 0.0;
    var idx = -1;
    final (ax, ay) = xy[a];
    final (bx, by) = xy[b];
    final dx = bx - ax, dy = by - ay;
    final len2 = dx * dx + dy * dy;
    for (var i = a + 1; i < b; i++) {
      final (px, py) = xy[i];
      double d;
      if (len2 == 0) {
        d = sqrt((px - ax) * (px - ax) + (py - ay) * (py - ay));
      } else {
        final t = (((px - ax) * dx + (py - ay) * dy) / len2).clamp(0.0, 1.0);
        final qx = ax + t * dx, qy = ay + t * dy;
        d = sqrt((px - qx) * (px - qx) + (py - qy) * (py - qy));
      }
      if (d > maxD) {
        maxD = d;
        idx = i;
      }
    }
    if (idx >= 0 && maxD > toleranceM) {
      keep[idx] = true;
      stack
        ..add((a, idx))
        ..add((idx, b));
    }
  }
  return [
    for (var i = 0; i < pts.length; i++)
      if (keep[i]) pts[i],
  ];
}

/// "1.2 km" / "350 m"
String teamFormatLength(double m) => m >= 1000
    ? '${(m / 1000).toStringAsFixed(m >= 10000 ? 0 : 1)} km'
    : '${m.round()} m';

/// "2.4 ha" / "0.8 km²" / "450 m²"
String teamFormatArea(double m2) {
  if (m2 >= 1e6) return '${(m2 / 1e6).toStringAsFixed(1)} km²';
  if (m2 >= 1e4) return '${(m2 / 1e4).toStringAsFixed(1)} ha';
  return '${m2.round()} m²';
}
