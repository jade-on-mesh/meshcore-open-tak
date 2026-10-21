import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshcore_open/team/road_directions.dart';
import 'package:meshcore_open/team/team_wire.dart';

// Encodes like Valhalla (polyline, 6 decimals), for building answers.
String encode6(List<(double, double)> pts) {
  final b = StringBuffer();
  var plat = 0, plon = 0;
  void put(int v) {
    var x = v < 0 ? ~(v << 1) : v << 1;
    while (x >= 0x20) {
      b.writeCharCode((0x20 | (x & 0x1F)) + 63);
      x >>= 5;
    }
    b.writeCharCode(x + 63);
  }

  for (final p in pts) {
    final lat = (p.$1 * 1e6).round(), lon = (p.$2 * 1e6).round();
    put(lat - plat);
    put(lon - plon);
    plat = lat;
    plon = lon;
  }
  return b.toString();
}

// 1 km east along a street, then 1 km north: start, a left turn, arrive.
const _lat0 = 47.6, _lon0 = -122.33;
final _dLon = 1000 / (111320.0 * 0.6743); // ~1 km at 47.6 N
final _dLat = 1000 / 110540.0;

List<(double, double)> _shape() => [
  for (var i = 0; i <= 10; i++) (_lat0, _lon0 + _dLon * i / 10),
  for (var i = 1; i <= 10; i++) (_lat0 + _dLat * i / 10, _lon0 + _dLon),
];

Map<String, dynamic> _answer() => {
  'trip': {
    'summary': {'length': 2.0, 'time': 240.0},
    'legs': [
      {
        'shape': encode6(_shape()),
        'maneuvers': [
          {
            'type': 1,
            'instruction': 'Drive east on Pine Street.',
            'begin_shape_index': 0,
            'street_names': ['Pine Street'],
          },
          {
            'type': 15,
            'instruction': 'Turn left onto 5th Avenue.',
            'begin_shape_index': 10,
            'street_names': ['5th Avenue'],
          },
          {
            'type': 4,
            'instruction': 'You have arrived at your destination.',
            'begin_shape_index': 20,
          },
        ],
      },
    ],
  },
};

void main() {
  test('decodes polylines at 6 decimals', () {
    // Google's example string, read at 1e6 rather than 1e5.
    final p = decodePolyline6('_p~iF~ps|U_ulLnnqC_mqNvxq`@');
    expect(p.length, 3);
    expect(p[0].$1, closeTo(3.85, 1e-9));
    expect(p[0].$2, closeTo(-12.02, 1e-9));
    expect(p[2].$1, closeTo(4.3252, 1e-9));
    expect(p[2].$2, closeTo(-12.6453, 1e-9));
    final round = decodePolyline6(encode6(_shape()));
    expect(round.length, 21);
    expect(round.last.$1, closeTo(_lat0 + _dLat, 1e-6));
  });

  test('reads a Valhalla answer', () {
    final r = parseValhallaRoute(
      _answer(),
      mode: RoadMode.drive,
      to: (_lat0 + _dLat, _lon0 + _dLon),
    );
    expect(r.shape.length, 21);
    expect(r.maneuvers.length, 3);
    expect(r.maneuvers[1].type, 15);
    expect(r.maneuvers[1].beginIndex, 10);
    expect(r.maneuvers[1].streets, ['5th Avenue']);
    expect(r.maneuvers.last.isDestination, isTrue);
    expect(r.lengthM, 2000);
    expect(r.timeS, 240);
    expect(
      () => parseValhallaRoute(const {}, mode: RoadMode.walk, to: (0, 0)),
      throwsA(isA<RoadRouteError>()),
    );
  });

  test('guides along the route', () {
    final r = parseValhallaRoute(_answer(), mode: RoadMode.drive, to: (0, 0));
    final g = RoadGuide(r);
    expect(g.lengthM, closeTo(2000, 15));

    // 300 m along Pine Street: the left turn is 700 m ahead.
    var p = g.update(_lat0, _lon0 + _dLon * 0.3);
    expect(p.next, 1);
    expect(p.toNextM, closeTo(700, 15));
    expect(p.remainingM, closeTo(1700, 20));
    expect(p.offRouteM, lessThan(2));
    expect(p.arrived, isFalse);

    // Round the corner, 400 m up 5th Avenue: the destination is next.
    p = g.update(_lat0 + _dLat * 0.4, _lon0 + _dLon);
    expect(p.next, 2);
    expect(p.toNextM, closeTo(600, 15));

    // 80 m off to the side: off the route.
    p = g.update(_lat0 + _dLat * 0.4, _lon0 + _dLon + 80 / (111320.0 * 0.6743));
    expect(p.offRouteM, closeTo(80, 3));
    expect(p.offRouteM > roadOffRouteM(RoadMode.drive), isTrue);

    // At the end.
    p = g.update(_lat0 + _dLat * 0.995, _lon0 + _dLon);
    expect(p.arrived, isTrue);
  });

  test('asks the server and reports its errors', () async {
    late http.Request seen;
    final ok = RoadRouter(
      server: 'routing.example.org/',
      client: MockClient((req) async {
        seen = req;
        return http.Response(jsonEncode(_answer()), 200);
      }),
    );
    final r = await ok.route((1, 2), (3, 4), RoadMode.walk, language: 'fr-FR');
    expect(seen.url.toString(), 'https://routing.example.org/route');
    final body = jsonDecode(seen.body) as Map<String, dynamic>;
    expect(body['costing'], 'pedestrian');
    expect(body['locations'][1], {'lat': 3, 'lon': 4});
    expect(body['directions_options']['language'], 'fr-FR');
    expect(r.mode, RoadMode.walk);
    expect(r.to, (3, 4));

    final bad = RoadRouter(
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({'error_code': 442, 'error': 'No path could be found for input'}),
          400,
        ),
      ),
    );
    expect(bad.server, defaultRoutingServer);
    await expectLater(
      bad.route((1, 2), (3, 4), RoadMode.drive),
      throwsA(
        isA<RoadRouteError>().having(
          (e) => e.message,
          'message',
          'No path could be found for input',
        ),
      ),
    );
  });

  test('a shared route keeps its turn and fits one team packet', () {
    final r = parseValhallaRoute(_answer(), mode: RoadMode.drive, to: (0, 0));
    final pts = roadRouteForTeam(r);
    expect(pts.length, 3); // start, the corner, the end
    expect(pts[1].$2, closeTo(_lon0 + _dLon, 1e-5));
    final s = TeamShape(
      authorKey4: '01020304',
      shapeId: 1,
      kind: ShapeKind.route,
      time: DateTime.fromMillisecondsSinceEpoch(1760000000000),
      points: pts,
      label: 'To Alpha-1',
      routeMethod: RouteMethod.driving,
    ).fitted();
    expect(s.encode().length, lessThanOrEqualTo(teamMaxPayload));
  });

  test('a shared route gives the same turns as a standalone radio', () {
    // As test/test_team_wire.cpp in Wadamesh TAK: 1.1 km east, left, 1 km north.
    const pts = [(47.6, -122.33), (47.6, -122.31523), (47.60905, -122.31523)];
    expect(routeTurnAt(pts, 1), -90);
    expect(routeTurnAt(pts.reversed.toList(), 1), 90);
    final t = routeNextTurn(pts, 1, 47.6, -122.325);
    expect(t.turnDeg, -90);
    expect(t.toTurnM, closeTo(730, 30));
    expect(t.remainingM, closeTo(1740, 40));
    final end = routeNextTurn(pts, 2, 47.605, -122.31523);
    expect(end.hasTurn, isFalse);
    expect(end.toTurnM, closeTo(450, 30));
  });

  test('distances and times read naturally', () {
    expect(roadDistance(47), '50 m');
    expect(roadDistance(730), '750 m');
    expect(roadDistance(1260), '1.3 km');
    expect(roadDistance(23400), '23 km');
    expect(roadDuration(20), '1 min');
    expect(roadDuration(600), '10 min');
    expect(roadDuration(4800), '1 h 20 min');
  });
}
