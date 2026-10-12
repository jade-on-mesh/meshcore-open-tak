import 'package:flutter_test/flutter_test.dart';
import 'package:gpx/gpx.dart';
import 'package:meshcore_open/team/team_gpx.dart';
import 'package:meshcore_open/team/team_service.dart';
import 'package:meshcore_open/team/team_wire.dart';

void main() {
  test('GPX holds pins, CASEVACs, routes, drawings and trails', () {
    final t = DateTime(2026, 10, 12, 9);
    final xml = buildTeamGpx(
      now: t,
      markers: [
        TeamMarker(
          authorKey4: '01020304',
          markerId: 1,
          kind: MarkerKind.landingZone,
          lat: 46.85,
          lon: -121.76,
          time: t,
          label: 'LZ Paradise',
        ),
      ],
      casevacs: [
        TeamCasevac(
          authorKey4: '01020304',
          requestId: 2,
          lat: 46.8,
          lon: -121.7,
          time: t,
          urgent: 1,
        ),
      ],
      shapes: [
        TeamShape(
          authorKey4: '01020304',
          shapeId: 3,
          kind: ShapeKind.route,
          time: t,
          label: 'Wonderland',
          points: const [(46.8, -121.7), (46.81, -121.71), (46.82, -121.7)],
        ),
        TeamShape(
          authorKey4: '01020304',
          shapeId: 4,
          kind: ShapeKind.circle,
          time: t,
          label: 'Camp',
          radiusM: 200,
          geofence: TeamGeofence.entry,
          points: const [(46.79, -121.73)],
        ),
      ],
      members: [
        TeamMember(
          key4: '0a0b0c0d',
          position: const TeamPosition(
            senderKey4: '0a0b0c0d',
            lat: 46.8,
            lon: -121.7,
            callsign: 'ROVER',
          ),
          heard: t,
          trail: [(46.8, -121.7, t), (46.801, -121.701, t)],
        ),
      ],
    );
    final g = GpxReader().fromString(xml);
    expect(g.wpts.map((w) => w.name), contains('LZ Paradise'));
    expect(
      g.wpts.any((w) => (w.name ?? '').startsWith('CASEVAC URGENT')),
      isTrue,
    );
    expect(g.rtes.single.name, 'Wonderland');
    expect(g.rtes.single.rtepts.length, 3);
    expect(g.trks.map((t) => t.name), containsAll(['Camp', 'ROVER track']));
    final camp = g.trks.firstWhere((t) => t.name == 'Camp');
    expect(camp.type, 'Geofence');
    expect(camp.trksegs.single.trkpts.length, greaterThan(40));
  });
}
