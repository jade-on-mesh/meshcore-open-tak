import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/team/tak/cot.dart';
import 'package:meshcore_open/team/tak/data_package.dart';
import 'package:meshcore_open/team/team_wire.dart';

TeamShape _shape(ShapeKind k, List<(double, double)> pts, {int r = 0}) =>
    TeamShape(
      authorKey4: '0a0b0c0d',
      shapeId: 5,
      kind: k,
      time: DateTime.now(),
      points: pts,
      radiusM: r,
      color: TeamColor.red,
      label: 'Item',
      geofence: TeamGeofence.exit,
    );

void main() {
  test('a data package round-trips its items', () {
    final marker = TeamMarker(
      authorKey4: '0a0b0c0d',
      markerId: 1,
      kind: MarkerKind.hazard,
      lat: 47.1,
      lon: -122.1,
      time: DateTime.now(),
      label: 'Washout',
    );
    final poly = _shape(ShapeKind.polygon, [(1, 1), (1, 1.01), (1.01, 1.01)]);
    final items = [
      for (final x in [cotForMarker(marker), cotForShape(poly)])
        (parseCot(x)!.uid, x),
    ];
    final zip = buildTakDataPackage(
      packageUid: 'pkg-1',
      name: 'Test package',
      items: items,
    );
    final back = readTakDataPackage(zip);
    expect(back.isConnection, isFalse);
    expect(back.name, 'Test package');
    expect(back.events.length, 2);
    final m = teamMarkerFromCot(
      back.events.firstWhere((e) => e.isMarker),
      authorKey4: 'ffffffff',
      markerId: 9,
    )!;
    expect(m.kind, MarkerKind.hazard);
    expect(m.label, startsWith('Washout'));
  });

  test('ATAK drawings convert back to team shapes', () {
    TeamShape back(TeamShape s) => teamShapeFromCot(
      parseCot(cotForShape(s))!,
      authorKey4: 'ffffffff',
      shapeId: 1,
    )!;
    final poly = back(_shape(ShapeKind.polygon, [(1, 1), (1, 2), (2, 2)]));
    expect(poly.kind, ShapeKind.polygon);
    expect(poly.points.length, 3);
    expect(poly.geofence, TeamGeofence.exit);
    expect(poly.color, TeamColor.red);

    final circle = back(_shape(ShapeKind.circle, [(1, 1)], r: 120));
    expect(circle.kind, ShapeKind.circle);
    expect(circle.radiusM, 120);

    final route = back(_shape(ShapeKind.route, [(1, 1), (1.1, 1), (1.2, 1)]));
    expect(route.kind, ShapeKind.route);
    expect(route.points.length, 3);

    final rect = back(
      _shape(ShapeKind.rectangle, [(1, 1), (1, 2), (2, 2), (2, 1)]),
    );
    expect(rect.kind, ShapeKind.rectangle);

    final line = back(_shape(ShapeKind.line, [(1, 1), (2, 2)]));
    expect(line.kind, ShapeKind.line);
    expect(line.geofence, TeamGeofence.off);
  });
}
