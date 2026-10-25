import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/team/team_compat.dart';
import 'package:meshcore_open/team/team_compat_bridge.dart';
import 'package:meshcore_open/team/team_wire.dart';

// Golden strings worked out from MeshCore TEAM's wire formats (see
// lib/team/team_compat.dart). Wadamesh TAK's test/test_team_compat.cpp checks
// the same strings.
void main() {
  group('#TEL', () {
    test('encodes like TEAM', () {
      const p = TeamCompatPosition(
        lat: 47.6062,
        lon: -122.3321,
        companionMv: 3900,
      );
      expect(p.encodeTel(), '#TEL:HGAhMLcVmljBAQE');
      const q = TeamCompatPosition(
        lat: -33.8688,
        lon: 151.2093,
        companionMv: 4100,
        phoneMv: 3800,
      );
      expect(q.encodeTel(), '#TEL:69AIAFogtUjjsQE');
    });

    test('decodes', () {
      final p = TeamCompatPosition.parse('#TEL:HGAhMLcVmljBAQE')!;
      expect(p.lat, closeTo(47.6062, 1e-7));
      expect(p.lon, closeTo(-122.3321, 1e-7));
      expect(p.companionMv, 3896); // 6 mV steps
      expect(p.phoneMv, isNull);
      expect(p.autonomous, isFalse);
      expect(teamBatteryPct(p.batteryMv), 66);
    });

    test('a radio on its own GPS', () {
      final p = TeamCompatPosition.parse('#TEL:HE/swLciIWCg/wE')!;
      expect(p.autonomous, isTrue);
      expect(p.phoneMv, isNull);
      expect(p.companionMv, 3698);
      expect(p.lat, 47.5);
      expect(p.lon, -122.25);
    });

    test('topology reads as a position', () {
      final p = TeamCompatPosition.parse('#T:BkIsQAwR56DSAQoFAQ')!;
      expect(p.lat, 10.5);
      expect(p.lon, 20.25);
      expect(p.companionMv, 3998);
    });

    test('rejects junk', () {
      expect(TeamCompatPosition.parse('#TEL:abc'), isNull);
      expect(TeamCompatPosition.parse('#TEL:!!!!'), isNull);
      expect(TeamCompatPosition.parse('hello'), isNull);
    });
  });

  group('#CAP', () {
    test('v2 round trip', () {
      const c = TeamCompatCap(keyPrefix: 'a1b2c3d4e5f6', alias: 'Bravo: 2');
      expect(c.encode(), '#CAP:2:00:a1b2c3d4e5f6:-:Bravo: 2');
      final back = TeamCompatCap.parse(c.encode())!;
      expect(back.keyPrefix, 'a1b2c3d4e5f6');
      expect(back.appId, isNull);
      expect(back.alias, 'Bravo: 2');
    });

    test('v2 with an app id, early v2, v1', () {
      final a = TeamCompatCap.parse(
        '#CAP:2:05:0123456789ab:00112233aabbccdd:Echo',
      )!;
      expect(a.flags, 5);
      expect(a.appId, '00112233aabbccdd');
      expect(a.alias, 'Echo');
      final e = TeamCompatCap.parse('#CAP:2:01:0123456789ab:Fox')!;
      expect(e.alias, 'Fox');
      expect(e.appId, isNull);
      final v1 = TeamCompatCap.parse('#CAP:1:03')!;
      expect(v1.alias, isNull);
      expect(v1.flags, 3);
    });

    test('the alias is clipped to 24 bytes', () {
      final c = TeamCompatCap(alias: 'x' * 40).encode();
      expect(c.endsWith(':${'x' * 24}'), isTrue);
    });

    test('advert request', () {
      final r = TeamCompatCapRequest.parse('#CAP:R:a1b2c3d4e5f6:Hill Top')!;
      expect(r.radioName, 'Hill Top');
      expect(r.keyPrefix, 'a1b2c3d4e5f6');
      expect(TeamCompatCap.parse('#CAP:R:-:Hill Top'), isNull);
      expect(const TeamCompatCapRequest(radioName: 'X').encode(), '#CAP:R:-:X');
    });
  });

  group('#WAY', () {
    test('a waypoint', () {
      final (w, part, parts, _) = TeamCompatWaypoint.parse(
        '#WAY:abc-1|Camp 2|47.1|-122.2|By the creek|CAMP|',
      )!;
      expect(w.meshId, 'abc-1');
      expect(w.name, 'Camp 2');
      expect(w.type, TeamCompatWaypointType.camp);
      expect(w.description, 'By the creek');
      expect((part, parts), (1, 1));
    });

    test('older form, unknown type', () {
      final (w, _, _, _) = TeamCompatWaypoint.parse(
        '#WAY:Spot|1.5|2.5|note|THING',
      )!;
      expect(w.meshId, isNull);
      expect(w.type, TeamCompatWaypointType.custom);
    });

    test('a coloured route', () {
      const w = TeamCompatWaypoint(
        meshId: 'r1',
        name: 'Loop',
        lat: 47.0,
        lon: -122.0,
        type: TeamCompatWaypointType.route,
        color: 0xFFF44336,
        route: [(47.0, -122.0), (47.001, -122.002)],
      );
      final msgs = w.encode();
      expect(msgs, [
        '#WAY:r1|Loop|47.000000|-122.000000|@C:FFF44336|ROUTE|'
            '47.000000,-122.000000~47.001000,-122.002000',
      ]);
      final (back, _, _, _) = TeamCompatWaypoint.parse(msgs.single)!;
      expect(back.color, 0xFFF44336);
      expect(back.description, '');
      expect(back.route.length, 2);
    });

    test('a long route splits and reassembles', () {
      final pts = [for (var i = 0; i < 20; i++) (47.0 + i / 1000, -122.0)];
      final w = TeamCompatWaypoint(
        meshId: 'r2',
        name: 'Long',
        lat: pts.first.$1,
        lon: pts.first.$2,
        type: TeamCompatWaypointType.route,
        route: pts,
      );
      final msgs = w.encode(overhead: 12);
      expect(msgs.length, greaterThan(1));
      expect(msgs.first, startsWith('#WAY:r2|'));
      expect(msgs.first, endsWith('|1/${msgs.length}'));
      for (final m in msgs) {
        expect(m.length + 12, lessThanOrEqualTo(teamCompatMaxBytes));
      }
      expect(msgs[1], startsWith('#WRC:r2|'));
      final a = TeamCompatRouteAssembler();
      TeamCompatWaypoint? done;
      // Out of order is fine.
      for (final m in [...msgs.skip(1), msgs.first]) {
        done = a.accept('Alpha', m) ?? done;
      }
      expect(done, isNotNull);
      expect(done!.route.length, 20);
      expect(done.route.last.$1, closeTo(47.019, 1e-9));
    });

    test('separators in names are replaced', () {
      const w = TeamCompatWaypoint(
        name: 'A|B',
        lat: 1,
        lon: 2,
        type: TeamCompatWaypointType.custom,
      );
      expect(w.encode().single, '#WAY:|A/B|1.000000|2.000000||CUSTOM|');
    });
  });

  test('chat filter', () {
    expect(isTeamCompatText('#TEL:abc'), isTrue);
    expect(isTeamCompatText('#WRC:x|y|2/2'), isTrue);
    expect(isTeamCompatText('#trail meets at 9'), isFalse);
  });

  group('mapping', () {
    test('waypoint types and marker kinds', () {
      expect(
        markerKindForTeam(TeamCompatWaypointType.camp),
        MarkerKind.staging,
      );
      expect(
        markerKindForTeam(TeamCompatWaypointType.danger),
        MarkerKind.hazard,
      );
      expect(markerKindForTeam(TeamCompatWaypointType.game), MarkerKind.point);
      for (final t in [
        TeamCompatWaypointType.camp,
        TeamCompatWaypointType.meetup,
        TeamCompatWaypointType.danger,
        TeamCompatWaypointType.water,
      ]) {
        expect(teamTypeForMarker(markerKindForTeam(t)), t);
      }
      expect(teamTypeForMarker(MarkerKind.clue), TeamCompatWaypointType.custom);
    });

    test('route colours', () {
      expect(nearestTeamColor(0xFFF44336), TeamColor.red);
      expect(nearestTeamColor(0xFF673AB7), TeamColor.purple);
      expect(nearestTeamColor(0xFF2196F3), TeamColor.blue);
    });
  });
}
