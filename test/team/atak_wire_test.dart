// Cross-checks the app's team wire formats against byte vectors produced by
// the ATAK plugin's Java implementation (atak-plugin/.../core). If either
// side changes its encoding, this fails.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/team/team_wire.dart';
import 'package:meshcore_open/team/team_wire_atak.dart';

Uint8List _hex(String s) => Uint8List.fromList([
  for (var i = 0; i < s.length; i += 2)
    int.parse(s.substring(i, i + 2), radix: 16),
]);

String _toHex(Uint8List b) =>
    b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();

// Produced by the plugin's Java encoder (see TeamWireTest / Gold.java).
const _position = '50c99d98ce0b1c60218fb7159b7c0038034004512c03044a414445';
const _marker =
    '4d01020304deadbeef00051becbe20b76ce60068e778000b4c5a2050617261646973650b'
    '466c6174206d6561646f7728a1b2c3d4120085';
const _point =
    '4f0a0b0c0d12345678000f1c12e3c0b757894068e7780104d2ffff00000b612d682d472d'
    '552d432d4909486f7374696c6520310e4e6561722074686520726964676521434f545f4d'
    '415050494e475f32353235422f612d682f612d682d472d552d432d492801020304030096';
const _shape =
    '470a0b0c0d00000063000101ff00ff004000ff0068e778020506417265612042000402cd'
    '29c0f8ba6d80d00f0000a01fcf0f00';
const _circle =
    '470a0b0c0d00000005000300ffffffff68e778030609506572696d6574657200dc0b0102'
    'aea540f8d8f200';
const _blobChunk =
    '580a0b0c0d01020001010099ff003c6576656e74207569643d2278222f3e';
const _blob2 = [
  '580a0b0c0d020300020201ed4505662e62696e6360e7139551d632b4b077f30d894eca2c28'
      'af6bed993c6be18af5dbf61e397de9e683e7efbefe61e612949057d335b176f20c088f4b'
      'cd29ae6aece89f3677c9ea4d3b0f1c3f77f5cee3571f7ffc67e3159156d23430b773f509'
      '8e4accc82fab6de99e3473c1f2755bf71c3e75f1c6fd676fbffc66e214109753d531b672'
      'f4f00f8b4dc92eaa6c68ef9b3a67f1aa8d',
  '580a0b0c0d020301023bf61f3b7be5f6a3971fbeff63e5119652d4d037b375f10e8a4c48cf'
      '2bad69ee9a3863feb2b55b761f3a79e1fabda76f3eff62e4e0179355d136b27470f70b8d'
      '49ce2aaca86feb9d327bd1ca0ddbf71d3d73f9d6c317efbffd65e116925450d733b571f6'
      '0a8c884fcb2da96eea9c307dded2359b771d3c71fedadd27af3ffd641864fe0700',
  '580a0b0c0d020302021c39f7f27e7e83d8c1fe71dd9f84f684c784e66487c486fc87c48664'
      'e784c68477a6538274476ead6826479007795a48d1c09e84f67487c486e487c4867cff84'
      'c684e784c6448774ab45b23b8736d4eb224a863735940890439a86f487c48664e784c684'
      'ff84c64487e486c48774a843bc2ca76e6c6b2349803827ba4810c39b860c746954d531b6'
      '72f4f00f8b4dc92eaa6c68ef9b3a67f1aa8d',
];

void main() {
  test('position bytes match the plugin', () {
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
    expect(_toHex(p.encode()), _position);
  });

  test('marker bytes match the plugin', () {
    final m = TeamMarker(
      authorKey4: '01020304',
      markerId: 0xDEADBEEF,
      kind: MarkerKind.landingZone,
      lat: 46.85,
      lon: -121.76,
      time: DateTime.fromMillisecondsSinceEpoch(1760000000 * 1000),
      label: 'LZ Paradise',
      note: 'Flat meadow',
      attachment: const TeamAttachment(40, 'a1b2c3d4', 18, 133),
    );
    expect(_toHex(m.encode()), _marker);
  });

  test('point round-trips the plugin bytes', () {
    final p = TeamPoint.tryParse(_hex(_point))!;
    expect(p.authorKey4, '0a0b0c0d');
    expect(p.itemId, 0x12345678);
    expect(p.cotType, 'a-h-G-U-C-I');
    expect(p.callsign, 'Hostile 1');
    expect(p.remarks, 'Near the ridge');
    expect(p.haeM, 1234);
    expect(p.argb, 0xFFFF0000 - 0x100000000);
    expect(p.iconset, 'COT_MAPPING_2525B/a-h/a-h-G-U-C-I');
    expect(p.attachment!.sessionId, '01020304');
    expect(p.affiliationLetter, 'h');
    expect(_toHex(p.encode()), _point);
    expect(teamPeek(_hex(_point))!.$1, teamMsgPoint);
  });

  test('shapes round-trip the plugin bytes', () {
    final s = TeamAtakShape.tryParse(_hex(_shape))!;
    expect(s.kind, TeamShapeKind.polygon);
    expect(s.label, 'Area B');
    expect(s.points.length, 4);
    expect(s.points[2].$1, closeTo(47.001, 1e-9));
    expect(s.points[2].$2, closeTo(-121.998, 1e-9));
    expect(s.strokeWidth, 2.5);
    expect(_toHex(s.encode()), _shape);

    final c = TeamAtakShape.tryParse(_hex(_circle))!;
    expect(c.kind, TeamShapeKind.circle);
    expect(c.radiusM, 1500);
    expect(c.points.single.$1, closeTo(45, 1e-9));
    expect(_toHex(c.encode()), _circle);
  });

  test('chunked transfers reassemble, recovering one lost chunk', () {
    final r = TeamChunkReassembler();
    final one = r.accept(_hex(_blobChunk))!;
    expect(one.isCot, isTrue);
    expect(one.text, '<event uid="x"/>');

    for (var drop = 0; drop < _blob2.length; drop++) {
      final rr = TeamChunkReassembler();
      TeamBlob? got;
      for (var i = 0; i < _blob2.length; i++) {
        if (i == drop) continue;
        got ??= rr.accept(_hex(_blob2[i]));
      }
      expect(got, isNotNull, reason: 'drop $drop');
      expect(got!.name, 'f.bin');
      expect(got.data.length, 400);
      for (var i = 0; i < 400; i++) {
        expect(got.data[i], (i * 7) & 0xFF);
      }
    }
  });

  test('garbage never throws', () {
    for (var n = 0; n < 60; n++) {
      final b = Uint8List.fromList([
        for (var i = 0; i < n; i++) (i * 37 + n) & 0xFF,
      ]);
      for (final t in [teamMsgPoint, teamMsgAtakShape, teamMsgChunk]) {
        if (b.isNotEmpty) b[0] = t;
        TeamPoint.tryParse(b);
        TeamAtakShape.tryParse(b);
        TeamChunkReassembler().accept(b);
      }
    }
  });
}
