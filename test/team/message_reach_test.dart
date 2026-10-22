import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/team/team_service.dart';
import 'package:meshcore_open/team/team_wire.dart';

String _hex(Uint8List b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

// The same golden bytes as Wadamesh TAK's test/test_team_wire.cpp.
void main() {
  test('a beacon says whose name it is and what it heard', () {
    const p = TeamPosition(
      senderKey4: 'a1b2c3d4',
      lat: 47.6,
      lon: -122.3,
      callsign: 'Sam',
      nameHash: 0x1234,
      heard: [0x9aa8, 0x477d],
    );
    expect(
      _hex(p.encode()),
      '50a1b2c3d4401c5f2f00b71a80400000000000ff00000353616d1234029aa8477d',
    );
    final back = TeamPosition.tryParse(p.encode())!;
    expect(back.nameHash, 0x1234);
    expect(back.heard, [0x9aa8, 0x477d]);
    expect(back.callsign, 'Sam');
  });

  test('with an added role, the heard part follows the role byte', () {
    const p = TeamPosition(
      senderKey4: 'a1b2c3d4',
      lat: 1,
      lon: 2,
      roleId: 17,
      callsign: 'X',
      nameHash: 7,
      heard: [1, 2, 3, 4, 5, 6],
    );
    final back = TeamPosition.tryParse(p.encode())!;
    expect(back.roleId, 17);
    expect(back.nameHash, 7);
    expect(back.heard, [3, 4, 5, 6]); // the last four
  });

  test('older beacons have none', () {
    const p = TeamPosition(senderKey4: 'a1b2c3d4', lat: 1, lon: 2);
    final back = TeamPosition.tryParse(p.encode())!;
    expect(back.nameHash, isNull);
    expect(back.heard, isEmpty);
  });

  test('name hash', () {
    expect(TeamService.nameHash('Sam'), 0x415f);
    expect(TeamService.nameHash('Jade T-Deck'), 0x2b34);
  });
}
