import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/radio_import.dart';

Uint8List _id({String name = ''}) {
  final b = Uint8List(128);
  for (var i = 0; i < 32; i++) {
    b[i] = 0xA0 + i % 16;
  }
  for (var i = 0; i < 64; i++) {
    b[32 + i] = i;
  }
  b.setRange(96, 96 + name.length, utf8.encode(name));
  return b;
}

void _put32(Uint8List b, int at, int v) =>
    ByteData.sublistView(b).setInt32(at, v, Endian.little);

void main() {
  test('a MeshCore backup JSON (the app, Wadamesh TAK, Squatch Mesh)', () {
    final json = jsonEncode({
      'name': 'Tiamat',
      'private_key': List.generate(64, (i) => i.toRadixString(16).padLeft(2, '0')).join(),
      'radio_settings': {'frequency': 910.525},
      'channels': [
        {'name': 'Public', 'secret': '8b3387e9c5cdea6ac9e5edbaa115cd72'},
        {'name': '', 'secret': ''},
        {'name': '#hike', 'secret': 'f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff'},
        {'name': '', 'secret': ''},
      ],
      'contacts': [
        {
          'public_key': '11' * 32,
          'name': 'Bob',
          'custom_name': 'Bobby',
          'type': 1,
          'flags': 1,
          'latitude': '47.606200',
          'longitude': '-122.332100',
          'last_advert': 1761500000,
          'last_modified': 1761500100,
        },
        {'public_key': 'zz', 'name': 'bad'},
      ],
      'wadamesh_settings': {'airtime_factor': 1.0},
    });
    final imp = parseRadioImport({'meshcore-backup.json': utf8.encode(json)})!;
    expect(imp.source, RadioImportSource.meshcoreBackup);
    expect(imp.name, 'Tiamat');
    expect(imp.privateKey!.length, 64);
    expect(imp.privateKey![63], 63);
    expect(imp.channels.length, 3); // trailing empty slot dropped
    expect(imp.channels[1], isNull);
    expect(imp.channels[2]!.name, '#hike');
    expect(imp.channels[2]!.secret[0], 0xf0);
    expect(imp.channelCount, 2);
    expect(imp.contacts.length, 1);
    final c = imp.contacts.single;
    expect(c.name, 'Bobby');
    expect(c.latitude, closeTo(47.6062, 1e-6));
    expect(c.longitude, closeTo(-122.3321, 1e-6));
    expect(c.lastAdvert, 1761500000);
  });

  test("MeshCore Open's contacts export", () {
    final json = jsonEncode([
      {
        'publicKey': base64Encode(List.filled(32, 0x22)),
        'name': 'Carol',
        'type': 2,
        'latitude': 45.5,
        'longitude': -122.6,
        'lastSeen': 1761400000000,
      },
      {'publicKey': 'bad', 'name': 'x'},
    ]);
    final imp = parseRadioImport({'meshcore_discovered_contacts.json': utf8.encode(json)})!;
    expect(imp.source, RadioImportSource.meshcoreOpenContacts);
    expect(imp.contacts.single.type, 2);
    expect(imp.contacts.single.lastAdvert, 1761400000);
    expect(imp.hasIdentity, isFalse);
    expect(imp.channels, isEmpty);
  });

  test("Squatch Mesh's companion files", () {
    final c3 = Uint8List(152 * 2);
    c3.fillRange(0, 32, 0x11);
    c3.setRange(32, 35, utf8.encode('Bob'));
    c3[64] = 1;
    _put32(c3, 72, 1761500000);
    _put32(c3, 140, 1761500100);
    _put32(c3, 144, 47606200);
    _put32(c3, 148, -122332100);
    final ch2 = Uint8List(68 * 3);
    ch2.setRange(4, 10, utf8.encode('Public'));
    ch2.setRange(68 * 2 + 4, 68 * 2 + 9, utf8.encode('#hike'));
    ch2[68 * 2 + 36] = 0xF0;
    final imp = parseRadioImport({
      'inw/identity/_main.id': _id(name: 'Tiamat'),
      'contacts3': c3,
      'channels2': ch2,
    })!;
    expect(imp.source, RadioImportSource.squatchMesh);
    expect(imp.name, 'Tiamat');
    expect(imp.privateKey![1], 1);
    expect(imp.channels.map((c) => c?.name), ['Public', null, '#hike']);
    expect(imp.contacts.single.name, 'Bob');
    expect(imp.contacts.single.latitude, closeTo(47.6062, 1e-6));
    expect(imp.contacts.single.lastModified, 1761500100);
  });

  test("MeshPunk's files", () {
    final mp = Uint8List(143);
    mp.fillRange(0, 32, 0x33);
    mp.setRange(32, 37, utf8.encode('Carol'));
    mp[64] = 1;
    _put32(mp, 131, 1761400000);
    _put32(mp, 135, 45500000);
    _put32(mp, 139, -122600000);
    const chans =
        '3\t#ops\t000102030405060708090a0b0c0d0e0f\n'
        '1\tFamily\tAABBCCDDEEFF00112233445566778899\n'
        'bad line\n';
    final imp = parseRadioImport({
      'identity': _id().sublist(0, 96),
      'contacts.bin': mp,
      'channels': utf8.encode(chans),
    })!;
    expect(imp.source, RadioImportSource.meshPunk);
    expect(imp.name, isNull);
    expect(imp.hasIdentity, isTrue);
    expect(imp.channels.map((c) => c?.name), ['Public', 'Family', null, '#ops']);
    expect(imp.channels[0]!.secret, radioImportPublicSecret);
    expect(imp.contacts.single.longitude, closeTo(-122.6, 1e-6));

    final noPublic = parseRadioImport({
      'channels': utf8.encode('pubdel\n2\tTeam\t00112233445566778899aabbccddeeff\n'),
    })!;
    expect(noPublic.channels.map((c) => c?.name), [null, null, 'Team']);
  });

  test('anything else is not an import', () {
    expect(parseRadioImport({'photo.jpg': Uint8List(10)}), isNull);
    expect(parseRadioImport({'x.json': utf8.encode('{"hello": 1}')}), isNull);
    expect(parseRadioImport({'x.json': utf8.encode('not json')}), isNull);
  });
}
