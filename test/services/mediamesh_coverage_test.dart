import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/models/contact.dart';
import 'package:meshcore_open/services/mediamesh_coverage.dart';

// The same values Wadamesh TAK's test/test_mediamesh_coverage.cpp checks.
void main() {
  test('radio2 margin from a main-mesh SNR', () {
    double m(double snr, int bw2, int sf) => mediaMeshMargin(
      snr: snr,
      mainBwHz: 62500,
      radio2BwHz: bw2,
      radio2Sf: sf,
    );
    expect(m(3, 250000, 7), closeTo(4.4794, 1e-3));
    expect(m(-2, 250000, 7), closeTo(-0.5206, 1e-3));
    expect(m(3, 125000, 7), closeTo(7.4897, 1e-3));
    expect(m(0, 62500, 9), closeTo(12.5, 1e-9));
    expect(mediaMeshReachFor(m(3, 250000, 7)), MediaMeshReach.marginal);
    expect(mediaMeshReachFor(m(-2, 250000, 7)), MediaMeshReach.out);
    expect(mediaMeshReachFor(m(3, 125000, 7)), MediaMeshReach.good);
    expect(mediaMeshReachFor(null), MediaMeshReach.none);
  });

  test('samples round trip and export', () {
    final s = CoverageSample(
      lat: 47.6,
      lon: -122.3,
      time: DateTime.fromMillisecondsSinceEpoch(1760000000000),
      repeaters: const [
        CoverageRepeater(
          key: 'a1b2c3d4',
          name: 'First Hill',
          snr: 4.5,
          remoteSnr: 3.0,
          margin: 4.48,
        ),
      ],
    );
    final back = CoverageSample.fromJson(s.toJson())!;
    expect(back.lat, 47.6);
    expect(back.repeaters.single.name, 'First Hill');
    expect(back.best, closeTo(4.5, 0.05));
    expect(back.reach, MediaMeshReach.marginal);
    final gj = coverageGeoJson([s]);
    expect(gj, contains('"coordinates":[-122.3,47.6]'));
    expect(gj, contains('"reach":"marginal"'));
  });

  test('RSSI, answers on radio2 and the silent ones round trip and export', () {
    final s = CoverageSample(
      lat: 47.6,
      lon: -122.3,
      time: DateTime.fromMillisecondsSinceEpoch(1760000000000),
      repeaters: const [
        CoverageRepeater(
          key: 'a1b2c3d4',
          name: 'First Hill',
          snr: 11.5,
          remoteSnr: 12.0,
          margin: 13.0,
          rssi: -64,
        ),
        CoverageRepeater(
          key: 'b1b2c3d4',
          name: 'SoDo',
          snr: 2.0,
          remoteSnr: 1.0,
          margin: 2.5,
          onRadio2: true,
        ),
      ],
      silent: const ['c1c2c3c4'],
    );
    final back = CoverageSample.fromJson(s.toJson())!;
    expect(back.repeaters[0].rssi, -64);
    expect(back.repeaters[0].onRadio2, isFalse);
    expect(back.repeaters[1].rssi, isNull);
    expect(back.repeaters[1].onRadio2, isTrue);
    expect(back.silent, ['c1c2c3c4']);
    // older samples, with none of these, still read
    final old = CoverageSample.fromJson({
      'a': 47.6,
      'o': -122.3,
      't': 1760000000,
      'p': [
        {'k': 'a1b2c3d4', 'n': 'x', 's': 1, 'r': 1, 'm': 2},
      ],
    })!;
    expect(old.repeaters.single.rssi, isNull);
    expect(old.silent, isEmpty);
    final gj = coverageGeoJson([s]);
    expect(gj, contains('"rssi":-64'));
    expect(gj, contains('"measured_on_radio2":true'));
    expect(gj, contains('"asked_on_radio2_no_answer":["c1c2c3c4"]'));
  });

  test('a repeater\'s answer to a one-hop trace', () {
    Uint8List frame(int tag, {int pathLen = 1, int flags = 0}) {
      final b = BytesBuilder()
        ..add([pushCodeTraceData, 0, pathLen, flags])
        ..add(
          (ByteData(4)..setUint32(0, tag, Endian.little)).buffer.asUint8List(),
        )
        ..add([0, 0, 0, 0]) // auth
        ..add(List.filled(pathLen == 1 ? 1 : 1 << (flags & 3), 0xab)) // path
        ..add([-10 & 0xFF, 22]); // it heard us at -2.5, we heard it at 5.5
      return b.toBytes();
    }

    final p = parseRepeaterPing(frame(77), 77)!;
    expect(p.remoteSnr, -2.5);
    expect(p.snr, 5.5);
    expect(parseRepeaterPing(frame(77), 78), isNull, reason: 'another trace');
    expect(
      parseRepeaterPing(frame(77, pathLen: 4, flags: 2), 77)!.snr,
      5.5,
      reason: '4-byte hashes',
    );
    expect(
      parseRepeaterPing(frame(77, pathLen: 2), 77),
      isNull,
      reason: 'two hops',
    );
    expect(traceHashByteWidthFor(1), 1);
    expect(traceHashByteWidthFor(3), 4);
    expect(traceFlagsForHashWidth(4), 2);
    // radio2 only: a bit of its own, never taken for the hash width
    expect(traceFlagOnRadio2 & 0x03, 0);
    expect(radio2TraceOn('> on'), isTrue);
    expect(radio2TraceOn('on'), isTrue);
    expect(radio2TraceOn('> off'), isFalse);
    expect(radio2TraceOn('Error: unknown command'), isFalse);
    expect(radio2TraceOn(null), isFalse);
  });

  test('which MediaMesh repeaters to ask by name', () {
    Contact rep(String hex, double? lat, {int type = advTypeRepeater}) =>
        Contact(
          publicKey: Uint8List.fromList(
            List.generate(
              32,
              (i) => i < 4
                  ? int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16)
                  : i,
            ),
          ),
          name: hex,
          type: type,
          pathLength: 0,
          path: Uint8List(0),
          latitude: lat,
          longitude: lat == null ? null : -122.3,
          lastSeen: DateTime(2026),
        );
    final mm = {
      'a1000000',
      'a2000000',
      'a3000000',
      'a4000000',
      'a5000000',
      'a6000000',
    };
    final list = mediaMeshAskList(
      [
        rep('a1000000', 47.62), // 2.2 km
        rep('a2000000', 47.601), // nearest
        rep('a3000000', 47.65), // 5.6 km
        rep('a4000000', 47.70), // 11 km: too far
        rep('a5000000', null), // no position
        rep('a6000000', 47.605), // answered the discovery
        rep('b0000000', 47.60), // not MediaMesh
        rep('a2000000', 47.601, type: advTypeChat), // a companion
      ],
      47.6,
      -122.3,
      answered: {'a6000000'},
      isMediaMesh: (hex) => mm.contains(hex.substring(0, 8)),
    );
    expect(list.map((c) => c.name), ['a2000000', 'a1000000', 'a3000000']);
  });
}
