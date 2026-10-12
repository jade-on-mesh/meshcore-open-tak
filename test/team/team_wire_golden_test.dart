// Golden bytes shared with Wadamesh's native team support
// (jade-on-mesh/wadamesh, test/test_team_wire.cpp): the radio's C++ encoder
// produces exactly these payloads for the same objects, so a T-Deck and this
// app read each other's positions, alerts and pins.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/team/team_wire.dart';

String _hex(Uint8List b) =>
    b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();

Uint8List _unhex(String h) => Uint8List.fromList([
  for (var i = 0; i < h.length; i += 2)
    int.parse(h.substring(i, i + 2), radix: 16),
]);

const kP1 = '5001020304071c60218fb7159b54003803c0084d2501084a61646520e29ca8';
const kP2 = '500102030418ebd0073b5a20b51b0000000000ff8b0507416c7068612d31';
const kA1 =
    '53aabbccddbeef131c4fecc0b72221600c05427261766f174e65656420776174657220617420746865207269646765';
const kA2 = '53aabbccdd0001000000000000000000000000';
const kM1 =
    '4d0a0b0c0d1234567800041bed17f8b76cda4868eb2c5008526f636b66616c6c1d547261696c20626c6f636b65642070617374207468652062726964676500';
const kM2 =
    '4d0a0b0c0d000000ff0109000000000000000000000001204142434445464748494a4b4c4d4e4f505152535455565758595a3031323334350028deadbeef0c0102';

const kR1 = '4ca1b2c3d4020068ec0be0007b07454d5420e29c9a';
const kR2 = '4c0a0b0c0d110168ec0c44000000';
const kP3 = '5001020304201b224618b6e10d380000000000fff300064b392d52657814';

void main() {
  test('role names and added roles match the radio', () {
    final r1 = TeamRoleDef(
      authorKey4: 'a1b2c3d4',
      roleId: 2,
      time: DateTime.fromMillisecondsSinceEpoch(1760300000 * 1000),
      iconId: 123,
      name: 'EMT ✚',
    );
    expect(_hex(r1.encode()), kR1);
    final r2 = TeamRoleDef(
      authorKey4: '0a0b0c0d',
      roleId: 17,
      time: DateTime.fromMillisecondsSinceEpoch(1760300100 * 1000),
      reset: true,
      name: 'ignored',
    );
    expect(_hex(r2.encode()), kR2);
    final back = TeamRoleDef.tryParse(_unhex(kR1))!;
    expect(back.name, 'EMT ✚');
    expect(back.iconId, 123);
    expect(TeamRoleDef.tryParse(_unhex(kR2))!.reset, isTrue);
    expect(r1.beats(r2), isFalse);

    final p3 = TeamPosition(
      senderKey4: '01020304',
      lat: 45.5231,
      lon: -122.6765,
      roleId: 20,
      color: TeamColor.orange,
      callsign: 'K9-Rex',
    );
    expect(_hex(p3.encode()), kP3);
    expect(TeamPosition.tryParse(_unhex(kP3))!.roleId, 20);
    // Roles 9-14 fit the nibble: no extra byte.
    final p4 = TeamPosition(senderKey4: '01020304', lat: 1, lon: 1, roleId: 12);
    expect(p4.encode().length, p3.encode().length - 1 - 6);
    expect(TeamPosition.tryParse(p4.encode())!.roleId, 12);
  });

  test('positions match the radio', () {
    final p1 = TeamPosition(
      senderKey4: '01020304',
      lat: 47.6062095,
      lon: -122.3320748,
      altitudeM: 56,
      speedMps: 1.4,
      headingDeg: 270.5,
      accuracyM: 8,
      batteryPct: 77,
      roleId: TeamRole.medic.index,
      color: TeamColor.red,
      status: TeamStatus.ok,
      callsign: 'Jade ✨',
      fromRadio: true,
    );
    expect(_hex(p1.encode()), kP1);
    final p2 = TeamPosition(
      senderKey4: '01020304',
      lat: -33.8688197,
      lon: 151.2092955,
      roleId: TeamRole.command.index,
      color: TeamColor.green,
      status: TeamStatus.resting,
      callsign: '  Alpha-1  ',
      sosActive: true,
      relayed: true,
    );
    expect(_hex(p2.encode()), kP2);
    final back = TeamPosition.tryParse(_unhex(kP1))!;
    expect(back.callsign, 'Jade ✨');
    expect(back.role, TeamRole.medic);
    expect(back.fromRadio, isTrue);
  });

  test('alerts match the radio', () {
    const a1 = TeamAlert(
      senderKey4: 'aabbccdd',
      alertId: 0xBEEF,
      active: true,
      type: TeamAlertType.inContact,
      lat: 47.5,
      lon: -122.25,
      accuracyM: 12,
      callsign: 'Bravo',
      note: 'Need water at the ridge',
    );
    expect(_hex(a1.encode()), kA1);
    const a2 = TeamAlert(senderKey4: 'aabbccdd', alertId: 1, active: false);
    expect(_hex(a2.encode()), kA2);
  });

  test('pins match the radio', () {
    final m1 = TeamMarker(
      authorKey4: '0a0b0c0d',
      markerId: 0x12345678,
      kind: MarkerKind.hazard,
      lat: 46.8523,
      lon: -121.7603,
      time: DateTime.fromMillisecondsSinceEpoch(1760242768 * 1000),
      label: 'Rockfall',
      note: 'Trail blocked past the bridge',
    );
    expect(_hex(m1.encode()), kM1);
    final m2 = TeamMarker(
      authorKey4: '0a0b0c0d',
      markerId: 0xFF,
      kind: MarkerKind.searched,
      lat: 0,
      lon: 0,
      time: DateTime.fromMillisecondsSinceEpoch(1000),
      label: 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789',
      deleted: true,
      attachment: const TeamAttachment(40, 'deadbeef', 12, 0x0102),
    );
    expect(_hex(m2.encode()), kM2);
    final back = TeamMarker.tryParse(_unhex(kM2))!;
    expect(back.deleted, isTrue);
    expect(back.attachment!.sessionId, 'deadbeef');
  });
}
