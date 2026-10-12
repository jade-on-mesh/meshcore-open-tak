import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/team/team_wire.dart';

String _long(int n) => List.filled(n, 'x').join();

TeamShape _shape(
  ShapeKind kind,
  List<(double, double)> pts, {
  int radius = 0,
  TeamGeofence geo = TeamGeofence.off,
  String label = 'Test',
}) => TeamShape(
  authorKey4: '0a0b0c0d',
  shapeId: 0x1234abcd,
  kind: kind,
  time: DateTime.fromMillisecondsSinceEpoch(1760000000 * 1000),
  points: pts,
  color: TeamColor.orange,
  label: label,
  geofence: geo,
  radiusM: radius,
  routeMethod: RouteMethod.driving,
);

void main() {
  group('shapes', () {
    test('route round-trips on a 1 m grid', () {
      final s = _shape(ShapeKind.route, [
        (47.6062095, -122.3320708),
        (47.6100000, -122.3300000),
        (47.6200000, -122.3000000),
      ]);
      final b = TeamShape.tryParse(s.encode())!;
      expect(b.key, s.key);
      expect(b.kind, ShapeKind.route);
      expect(b.color, TeamColor.orange);
      expect(b.routeMethod, RouteMethod.driving);
      expect(b.label, 'Test');
      expect(b.time, s.time);
      expect(b.points.length, 3);
      for (var i = 0; i < 3; i++) {
        expect(b.points[i].$1, closeTo(s.points[i].$1, 1e-5));
        expect(b.points[i].$2, closeTo(s.points[i].$2, 1e-5));
      }
    });

    test('circle keeps its radius and geofence', () {
      final s = _shape(
        ShapeKind.circle,
        [(45.5, -122.6)],
        radius: 250,
        geo: TeamGeofence.both,
      );
      final b = TeamShape.tryParse(s.encode())!;
      expect(b.radiusM, 250);
      expect(b.geofence, TeamGeofence.both);
      expect(b.isGeofence, isTrue);
      expect(b.contains(45.5, -122.6), isTrue);
      expect(b.contains(45.51, -122.6), isFalse); // ~1.1 km away
    });

    test('lines never carry a geofence', () {
      final s = _shape(ShapeKind.line, [
        (1, 1),
        (1.001, 1.001),
      ], geo: TeamGeofence.entry);
      expect(TeamShape.tryParse(s.encode())!.geofence, TeamGeofence.off);
    });

    test('polygon contains, area and length', () {
      // ~111 m x ~111 m square near the equator.
      final s = _shape(ShapeKind.polygon, [
        (0, 0),
        (0, 0.001),
        (0.001, 0.001),
        (0.001, 0),
      ]);
      expect(s.contains(0.0005, 0.0005), isTrue);
      expect(s.contains(0.002, 0.0005), isFalse);
      expect(s.areaM2, closeTo(111.2 * 111.2, 150));
      expect(s.lengthM, closeTo(4 * 111.2, 2));
    });

    test('a long freehand line is thinned to fit one packet', () {
      final pts = [
        for (var i = 0; i < 400; i++)
          (47.0 + i * 0.0001, -122.0 + sin(i / 7) * 0.002),
      ];
      final s = _shape(ShapeKind.freehand, pts, label: _long(40)).fitted();
      expect(s.encode().length, lessThanOrEqualTo(teamMaxPayload));
      expect(s.points.length, greaterThan(10));
      expect(s.points.first, pts.first);
      expect(s.points.last, pts.last);
      expect(TeamShape.tryParse(s.encode()), isNotNull);
    });

    test('a short shape is left alone by fitted()', () {
      final s = _shape(ShapeKind.line, [(1, 1), (1.5, 1.5), (2, 1)]);
      expect(identical(s.fitted(), s), isTrue);
    });

    test('delete flag round-trips', () {
      final s = _shape(ShapeKind.line, [(1, 1), (2, 2)]).copyWith(
        deleted: true,
      );
      expect(TeamShape.tryParse(s.encode())!.deleted, isTrue);
    });

    test('simplify keeps the ends and drops collinear points', () {
      final pts = [for (var i = 0; i <= 10; i++) (0.0, i * 0.001)];
      final s = teamSimplify(pts, 1);
      expect(s, [pts.first, pts.last]);
    });

    test('teamPeek knows the new types', () {
      final s = _shape(ShapeKind.line, [(1, 1), (2, 2)]);
      expect(teamPeek(s.encode())!.$1, teamMsgShape);
    });
  });

  group('CASEVAC 9-line', () {
    TeamCasevac sample({String? text}) => TeamCasevac(
      authorKey4: 'c99d98ce',
      requestId: 42,
      lat: 47.3073,
      lon: -122.2285,
      time: DateTime(2026, 10, 12, 14, 5),
      frequency: text ?? '146.520',
      callsign: text ?? 'JADE',
      urgent: 1,
      priority: 2,
      equipment: {CasevacEquipment.hoist, CasevacEquipment.ventilator},
      litter: 1,
      ambulatory: 2,
      security: CasevacSecurity.possibleEnemy,
      marking: CasevacMarking.smoke,
      markingDetail: text ?? 'red',
      usCivilian: 3,
      terrain: {CasevacTerrain.slope},
      nbc: CasevacNbc.none,
      place: text ?? 'Trailhead',
      remarks: text ?? 'Fall, leg injury',
    );

    test('round-trips every line', () {
      final c = sample();
      final b = TeamCasevac.tryParse(c.encode())!;
      expect(b.key, c.key);
      expect(b.frequency, '146.520');
      expect(b.callsign, 'JADE');
      expect(b.urgent, 1);
      expect(b.priority, 2);
      expect(b.equipment, {
        CasevacEquipment.hoist,
        CasevacEquipment.ventilator,
      });
      expect(b.litter, 1);
      expect(b.ambulatory, 2);
      expect(b.security, CasevacSecurity.possibleEnemy);
      expect(b.marking, CasevacMarking.smoke);
      expect(b.markingDetail, 'red');
      expect(b.usCivilian, 3);
      expect(b.terrain, {CasevacTerrain.slope});
      expect(b.place, 'Trailhead');
      expect(b.remarks, 'Fall, leg injury');
      expect(b.time, c.time);
      expect(b.totalPatients, 3);
      expect(b.precedenceLabel, 'URGENT');
    });

    test('the largest request fits one packet', () {
      final c = sample(text: _long(100));
      expect(c.encode().length, lessThanOrEqualTo(teamMaxPayload));
      expect(TeamCasevac.tryParse(c.encode()), isNotNull);
    });

    test('nine lines read like a 9-line', () {
      final l = sample().nineLines();
      expect(l.length, 9);
      expect(l[2], '3 A1 C2');
      expect(l[3], '4 B Hoist, D Ventilator');
      expect(l[4], '5 L1 A2');
      expect(l[5], startsWith('6 P '));
      expect(l[6], '7 C Smoke (red)');
      expect(l[7], '8 B3');
      expect(sample().condensedText().length, lessThanOrEqualTo(150));
    });
  });
}
