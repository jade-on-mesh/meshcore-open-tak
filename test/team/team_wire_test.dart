import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/team/tak/cot.dart';
import 'package:meshcore_open/team/team_wire.dart';

String _long(int n) => List.filled(n, 'x').join();

void main() {
  group('position', () {
    test('round-trips', () {
      const p = TeamPosition(
        senderKey4: 'c99d98ce',
        lat: 47.6062095,
        lon: -122.3320708,
        altitudeM: 56,
        speedMps: 1.5,
        headingDeg: 90,
        accuracyM: 4,
        batteryPct: 81,
        role: TeamRole.medic,
        color: TeamColor.darkGreen,
        status: TeamStatus.needHelp,
        callsign: 'JADE',
        sosActive: true,
      );
      final b = TeamPosition.tryParse(p.encode())!;
      expect(b.senderKey4, 'c99d98ce');
      expect(b.lat, closeTo(p.lat, 1e-6));
      expect(b.lon, closeTo(p.lon, 1e-6));
      expect(b.altitudeM, 56);
      expect(b.speedMps, 1.5);
      expect(b.headingDeg, closeTo(90, 1.5));
      expect(b.batteryPct, 81);
      expect(b.role, TeamRole.medic);
      expect(b.color, TeamColor.darkGreen);
      expect(b.status, TeamStatus.needHelp);
      expect(b.callsign, 'JADE');
      expect(b.sosActive, isTrue);
      expect(b.relayed, isFalse);
    });

    test('optional fields stay absent and size is small', () {
      final bytes = TeamPosition(
        senderKey4: '00000001',
        lat: -33.9,
        lon: 151.2,
        callsign: _long(40),
        relayed: true,
      ).encode();
      expect(bytes.length, lessThanOrEqualTo(25 + 1 + teamMaxCallsignBytes));
      final b = TeamPosition.tryParse(bytes)!;
      expect(b.altitudeM, isNull);
      expect(b.speedMps, isNull);
      expect(b.batteryPct, isNull);
      expect(b.relayed, isTrue);
      expect(b.callsign.length, teamMaxCallsignBytes);
    });

    test('rejects garbage', () {
      expect(TeamPosition.tryParse(Uint8List.fromList([0x50, 1, 2])), isNull);
      expect(teamPeek(Uint8List.fromList([0x99, 1, 2, 3, 4])), isNull);
    });
  });

  group('alert', () {
    test('round-trips type, state and note', () {
      const a = TeamAlert(
        senderKey4: 'abcdef01',
        alertId: 4321,
        active: true,
        type: TeamAlertType.inContact,
        lat: 45.5,
        lon: -122.6,
        accuracyM: 8,
        callsign: 'ROVER',
        note: 'Two vehicles at the gate',
      );
      final b = TeamAlert.tryParse(a.encode())!;
      expect(b.type, TeamAlertType.inContact);
      expect(b.active, isTrue);
      expect(b.alertId, 4321);
      expect(b.lat, closeTo(45.5, 1e-6));
      expect(b.note, a.note);
      expect(b.key, 'abcdef01:4321');
    });

    test('works without a position', () {
      const a = TeamAlert(senderKey4: 'abcdef01', alertId: 1, active: false);
      final b = TeamAlert.tryParse(a.encode())!;
      expect(b.lat, isNull);
      expect(b.active, isFalse);
    });
  });

  group('marker', () {
    test('round-trips with an attachment', () {
      final m = TeamMarker(
        authorKey4: '01020304',
        markerId: 0xDEADBEEF,
        kind: MarkerKind.landingZone,
        lat: 46.85,
        lon: -121.76,
        time: DateTime.fromMillisecondsSinceEpoch(1760000000 * 1000),
        label: 'LZ Paradise',
        note: 'Flat meadow, wind from the west',
        attachment: const TeamAttachment(40, 'a1b2c3d4', 18, 133),
      );
      final b = TeamMarker.tryParse(m.encode())!;
      expect(b.key, m.key);
      expect(b.kind, MarkerKind.landingZone);
      expect(b.label, 'LZ Paradise');
      expect(b.time, m.time);
      expect(b.attachment!.sessionId, 'a1b2c3d4');
      expect(b.attachment!.packets, 18);
      expect(b.attachment!.extra, 133);
    });

    test('the largest marker fits one packet', () {
      final m = TeamMarker(
        authorKey4: '01020304',
        markerId: 1,
        kind: MarkerKind.hazard,
        lat: 0,
        lon: 0,
        time: DateTime.now(),
        label: _long(100),
        note: _long(200),
        attachment: const TeamAttachment(32, 'ffffffff', 255, 65535),
      );
      expect(m.encode().length, lessThanOrEqualTo(teamMaxPayload));
    });

    test('delete flag round-trips', () {
      final m = TeamMarker(
        authorKey4: '01020304',
        markerId: 9,
        kind: MarkerKind.point,
        lat: 1,
        lon: 2,
        time: DateTime.now(),
        deleted: true,
      );
      expect(TeamMarker.tryParse(m.encode())!.deleted, isTrue);
    });
  });

  group('SALUTE report', () {
    TeamReport sample({String? text, TeamAttachment? att}) => TeamReport(
      authorKey4: '0a0b0c0d',
      reportId: 77,
      lat: 47.3073,
      lon: -122.2285,
      observed: DateTime(2026, 10, 3, 11, 30),
      urgency: TeamUrgency.critical,
      affiliation: TeamAffiliation.hostile,
      vehicles: 3,
      people: 5,
      place: text ?? 'Auburn E Main St',
      activity: text ?? 'Checkpoint',
      unit: text ?? 'Dark uniforms',
      equipment: text ?? 'Radios',
      size: text ?? '',
      attachment: att,
    );

    test('round-trips every field', () {
      final r = sample(att: const TeamAttachment(40, '01234567', 18, 150));
      final b = TeamReport.tryParse(r.encode())!;
      expect(b.urgency, TeamUrgency.critical);
      expect(b.affiliation, TeamAffiliation.hostile);
      expect(b.vehicles, 3);
      expect(b.people, 5);
      expect(b.place, 'Auburn E Main St');
      expect(b.activity, 'Checkpoint');
      expect(b.observed, r.observed);
      expect(b.attachment!.sessionId, '01234567');
    });

    test('condensed card matches the feed format', () {
      final lines = sample().condensedLines();
      expect(lines[0], '🔴 CRITICAL');
      expect(lines[1], '10-03 11:30');
      expect(lines[2], '@Auburn E Main St');
      expect(lines[3], '3-🚗 5-🥾');
      expect(sample().condensedText().length, lessThanOrEqualTo(150));
    });

    test('the largest report with an attachment fits one packet', () {
      final r = sample(
        text: _long(200),
        att: const TeamAttachment(40, 'ffffffff', 255, 600),
      );
      expect(r.encode().length, lessThanOrEqualTo(teamMaxPayload));
      expect(TeamReport.tryParse(r.encode()), isNotNull);
    });
  });

  group('helpers', () {
    test('UTF-8 truncation never splits a character', () {
      final t = teamTruncateUtf8('ab🚗🚗', 7);
      expect(t.length, 6); // 'ab' + one 4-byte emoji
    });

    test('distance and bearing', () {
      // Seattle -> Tacoma is ~40 km almost due south.
      final d = teamDistanceMeters(47.6062, -122.3321, 47.2529, -122.4443);
      expect(d, closeTo(40300, 800));
      final b = teamBearingDeg(47.6062, -122.3321, 47.2529, -122.4443);
      expect(b, closeTo(192, 3));
      expect(teamRangeBearing(1234, 45), '1.2 km 045° NE');
    });

    test('smart beaconing', () {
      const p = TeamBeaconPolicy();
      bool send(int secs, {double m = 0, double v = 0, double turn = 0}) =>
          p.shouldSend(
            sinceLast: Duration(seconds: secs),
            metersSinceLast: m,
            speedMps: v,
            headingChangeDeg: turn,
          );
      expect(
        p.shouldSend(
          sinceLast: null,
          metersSinceLast: null,
          speedMps: null,
          headingChangeDeg: null,
        ),
        isTrue,
      );
      expect(send(10, v: 3, turn: 90), isFalse); // under the minimum
      expect(send(40, v: 3, turn: 90), isTrue); // sharp turn
      expect(send(100, v: 3), isTrue); // moving
      expect(send(100), isFalse); // still
      expect(send(50, m: 200), isTrue); // moved far
      expect(send(601), isTrue); // still, but due
    });
  });

  group('Cursor on Target', () {
    test('position becomes a friendly PLI that parses back', () {
      const p = TeamPosition(
        senderKey4: 'c99d98ce',
        lat: 47.5,
        lon: -122.2,
        speedMps: 2,
        headingDeg: 180,
        batteryPct: 50,
        role: TeamRole.lead,
        color: TeamColor.blue,
        callsign: 'JADE',
      );
      final xml = cotForPosition(p, uid: takUidForMember(p.senderKey4));
      final e = parseCot(xml)!;
      expect(e.uid, 'VOX-c99d98ce');
      expect(e.type, 'a-f-G-U-C');
      expect(e.callsign, 'JADE');
      expect(e.groupName, 'Blue');
      expect(e.groupRole, 'Team Lead');
      expect(e.battery, 50);
      expect(e.course, closeTo(180, 1.5));
      expect(e.lat, closeTo(47.5, 1e-6));
    });

    test('alerts use the ATAK emergency types', () {
      const a = TeamAlert(
        senderKey4: 'c99d98ce',
        alertId: 1,
        active: true,
        lat: 1,
        lon: 2,
        callsign: 'JADE',
      );
      final e = parseCot(cotForAlert(a, memberUid: 'VOX-c99d98ce'))!;
      expect(e.type, 'b-a-o-tbl');
      expect(e.emergencyType, '911 Alert');
      const c = TeamAlert(senderKey4: 'c99d98ce', alertId: 1, active: false);
      final ce = parseCot(cotForAlert(c, memberUid: 'VOX-c99d98ce'))!;
      expect(ce.type, 'b-a-o-can');
      expect(ce.emergencyCancel, isTrue);
    });

    test('stream splitter keeps partial events for later', () {
      final buf = StringBuffer(
        '<event uid="a" type="t-x-c-t"><point lat="0" lon="0"/></event>'
        '<event uid="b" type="a-f-G"><point lat="1" lon="2"/></ev',
      );
      final events = takSplitEvents(buf);
      expect(events.length, 1);
      expect(buf.toString(), startsWith('<event uid="b"'));
      buf.write('ent>');
      expect(takSplitEvents(buf).length, 1);
    });

    test('SALUTE report becomes a point coloured by affiliation', () {
      final r = TeamReport(
        authorKey4: '0a0b0c0d',
        reportId: 1,
        lat: 1,
        lon: 2,
        observed: DateTime.now(),
        affiliation: TeamAffiliation.hostile,
        vehicles: 2,
      );
      final e = parseCot(cotForReport(r))!;
      expect(e.type, 'a-h-G');
      expect(e.remarks, contains('SALUTE'));
    });
  });
}
