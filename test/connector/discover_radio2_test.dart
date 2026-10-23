// The radio2 profile in DISCOVER_RESP (Find MediaMesh). The golden bytes are
// the ones Wadamesh TAK's test/test_mediamesh_core.cpp (testDiscoverRadio2)
// checks, and the layout proposed to keymindCascade.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/models/radio_settings.dart';
import 'package:meshcore_open/services/media_mesh_find.dart';

Uint8List _hex(String h) => Uint8List.fromList([
  for (var i = 0; i < h.length; i += 2)
    int.parse(h.substring(i, i + 2), radix: 16),
]);

String _toHex(Uint8List b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Uint8List _resp(List<int> key, List<int> extra, {int snrQuarterDb = 20}) {
  final tag = ByteData(4)..setUint32(0, 0xCAFE0001, Endian.little);
  return Uint8List.fromList([
    pushCodeControlData,
    snrQuarterDb & 0xFF,
    (-70) & 0xFF,
    0,
    (controlSubtypeDiscoverResp << 4) | advTypeRepeater,
    0,
    ...tag.buffer.asUint8List(),
    ...key,
    ...extra,
  ]);
}

const _rxtx = DiscoverRadio2(
  configured: true,
  mode: 2,
  frequencyKHz: 910525,
  bandwidthHz: 250000,
  spreadingFactor: 7,
  codingRate: 5,
);

void main() {
  test('request sets the radio2 flag only when asked', () {
    expect(buildDiscoveryRequestPayload(1)[0], 0x80);
    expect(buildDiscoveryRequestPayload(1, wantRadio2: true)[0], 0x82);
    expect(
      buildDiscoveryRequestPayload(1, wantRadio2: true, prefixOnly: true)[0],
      0x83,
    );
  });

  test('golden bytes', () {
    expect(_toHex(_rxtx.encode()), '0105bde40d0090d003000705');
    const temp = DiscoverRadio2(
      configured: true,
      mode: 1,
      temporary: true,
      frequencyKHz: 911150,
      bandwidthHz: 125000,
      spreadingFactor: 8,
      codingRate: 6,
    );
    expect(_toHex(temp.encode()), '010b2ee70d0048e801000806');
    expect(_toHex(const DiscoverRadio2(configured: false).encode()), '0100');

    final p = DiscoverRadio2.tryParse(_hex('010b2ee70d0048e801000806'))!;
    expect(p.configured, isTrue);
    expect(p.mode, 1);
    expect(p.temporary, isTrue);
    expect(p.frequencyMHz, 911.15);
    expect(p.bandwidthHz, 125000);
    expect(p.spreadingFactor, 8);
    expect(p.codingRate, 6);
    expect(p.active, isTrue);
  });

  test('trailer edge cases', () {
    expect(DiscoverRadio2.tryParse(Uint8List(0)), isNull);
    expect(DiscoverRadio2.tryParse(_hex('00')), isNull);
    expect(DiscoverRadio2.tryParse(_hex('0000')), isNull); // version 0
    expect(DiscoverRadio2.tryParse(_hex('0105bde40d00')), isNull); // cut short
    final off = DiscoverRadio2.tryParse(_hex('0100'))!;
    expect(off.configured, isFalse);
    expect(off.active, isFalse);
    // A later version may append; the first twelve bytes still count.
    final v2 = DiscoverRadio2.tryParse(_hex('0205bde40d0090d003000705ffff'))!;
    expect(v2.frequencyKHz, 910525);
    // Configured but mode off is not active.
    expect(
      DiscoverRadio2.tryParse(_hex('0101bde40d0090d003000705'))!.active,
      isFalse,
    );
  });

  test('response carries the trailer after a full key or a prefix', () {
    final key = List<int>.generate(32, (i) => i + 1);
    final full = parseNodeDiscoverResponse(_resp(key, _rxtx.encode()))!;
    expect(full.publicKey, key);
    expect(full.radio2!.frequencyKHz, 910525);
    expect(full.radio2!.mode, 2);

    final prefix = parseNodeDiscoverResponse(
      _resp(key.sublist(0, 8), _rxtx.encode()),
    )!;
    expect(prefix.publicKey.length, 8);
    expect(prefix.radio2!.bandwidthHz, 250000);

    // Stock firmware: no trailer, so nothing said.
    final stock = parseNodeDiscoverResponse(_resp(key, const []))!;
    expect(stock.radio2, isNull);
    expect(stock.extra, isEmpty);
    final stockPrefix = parseNodeDiscoverResponse(
      _resp(key.sublist(0, 8), const []),
    )!;
    expect(stockPrefix.radio2, isNull);
  });

  test('pick: the profile most repeaters run, then the strongest', () {
    const range = DiscoverRadio2(
      configured: true,
      mode: 2,
      frequencyKHz: 911150,
      bandwidthHz: 125000,
      spreadingFactor: 7,
      codingRate: 5,
    );
    const off = DiscoverRadio2(configured: false);
    const odd = DiscoverRadio2(
      configured: true,
      mode: 2,
      frequencyKHz: 910525,
      bandwidthHz: 200000, // not a bandwidth the app can set
      spreadingFactor: 7,
      codingRate: 5,
    );
    expect(mediaMeshProfilePick(const []), isNull);
    expect(
      mediaMeshProfilePick([(radio2: off, snr: 9.0), (radio2: odd, snr: 9.0)]),
      isNull,
    );

    var p = mediaMeshProfilePick([
      (radio2: range, snr: 10.0),
      (radio2: _rxtx, snr: 2.0),
      (radio2: _rxtx, snr: -3.0),
      (radio2: off, snr: 12.0),
    ])!;
    expect(p.bandwidth, LoRaBandwidth.bw250);
    expect(p.repeaters, 2);
    expect(p.bestSnr, 2.0);
    expect(p.spreadingFactor, LoRaSpreadingFactor.sf7);
    expect(p.codingRate, LoRaCodingRate.cr4_5);
    expect(p.frequencyMHz, 910.525);

    // A tie in count goes to the stronger signal.
    p = mediaMeshProfilePick([
      (radio2: range, snr: 6.5),
      (radio2: _rxtx, snr: 4.0),
    ])!;
    expect(p.bandwidth, LoRaBandwidth.bw125);

    // Listen-only repeaters count too.
    const rxOnly = DiscoverRadio2(
      configured: true,
      mode: 1,
      frequencyKHz: 911150,
      bandwidthHz: 125000,
      spreadingFactor: 7,
      codingRate: 5,
    );
    p = mediaMeshProfilePick([
      (radio2: rxOnly, snr: 1.0),
      (radio2: range, snr: 1.0),
      (radio2: _rxtx, snr: 9.0),
    ])!;
    expect(p.repeaters, 2);
    expect(p.bandwidth, LoRaBandwidth.bw125);
  });
}
