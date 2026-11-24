import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/models/contact.dart';
import 'package:meshcore_open/services/live_traffic.dart';
import 'package:shared_preferences/shared_preferences.dart';

Contact _repeater(int firstByte, double lat, double lon) {
  final key = Uint8List(32)..first = firstByte;
  return Contact(
    publicKey: key,
    name: 'R$firstByte',
    type: advTypeRepeater,
    pathLength: 0,
    path: Uint8List(0),
    latitude: lat,
    longitude: lon,
    lastSeen: DateTime.utc(2026),
  );
}

/// An RX log frame: [0x88][snr×4][rssi][header][path len][path][payload].
Uint8List _frame({
  required int payloadType,
  int routeType = 1,
  List<int> path = const [],
  int pathLenRaw = -1,
  List<int> payload = const [1, 2, 3],
}) => Uint8List.fromList([
  pushCodeLogRxData,
  22, // SNR 5.5
  -90 & 0xFF,
  (payloadType << 2) | routeType,
  if (routeType == 0 || routeType == 3) ...[9, 9, 9, 9],
  pathLenRaw >= 0 ? pathLenRaw : path.length,
  ...path,
  ...payload,
]);

Uint8List _advertPayload(int firstByte, double lat, double lon) {
  final p = ByteData(32 + 4 + 64 + 9);
  p.setUint8(0, firstByte);
  p.setUint8(100, 0x10 | advTypeChat);
  p.setInt32(101, (lat * 1e6).round(), Endian.little);
  p.setInt32(105, (lon * 1e6).round(), Endian.little);
  return p.buffer.asUint8List();
}

void main() {
  const self = LatLng(47.60, -122.30);

  group('parseLiveTrafficFrame', () {
    test('reads the header, SNR, RSSI, path and payload', () {
      final p = parseLiveTrafficFrame(
        _frame(payloadType: payloadTypeGRPTXT, path: [0xAA, 0xBB]),
      )!;
      expect(p.payloadType, payloadTypeGRPTXT);
      expect(p.isFlood, isTrue);
      expect(p.snr, 5.5);
      expect(p.rssi, -90);
      expect(p.pathBytes, [0xAA, 0xBB]);
      expect(p.payload, [1, 2, 3]);
      expect(p.typeName, 'GRP_TXT');
    });

    test('skips transport codes and reads 2-byte hashes', () {
      final p = parseLiveTrafficFrame(
        _frame(
          payloadType: payloadTypeTXTMSG,
          routeType: 0,
          path: [1, 2, 3, 4],
          pathLenRaw: 0x40 | 2,
        ),
      )!;
      expect(p.hashWidth, 2);
      expect(p.pathBytes, [1, 2, 3, 4]);
      expect(p.payload, [1, 2, 3]);
    });

    test('ignores other frames and short ones', () {
      expect(parseLiveTrafficFrame(Uint8List.fromList([0x80, 1, 2])), isNull);
      expect(parseLiveTrafficFrame(Uint8List.fromList([0x88, 1])), isNull);
      expect(
        parseLiveTrafficFrame(
          _frame(payloadType: payloadTypeACK, pathLenRaw: 40, payload: []),
        ),
        isNull,
      );
    });
  });

  test('colours match CoreScope', () {
    expect(liveTrafficTypeColor(payloadTypeADVERT), const Color(0xFF22C55E));
    expect(liveTrafficTypeColor(payloadTypeGRPTXT), const Color(0xFF3B82F6));
    expect(liveTrafficTypeColor(payloadTypeTXTMSG), const Color(0xFFF59E0B));
    expect(liveTrafficTypeColor(payloadTypeTRACE), const Color(0xFFEC4899));
    expect(liveTrafficTypeColor(0x0E), const Color(0xFF6B7280));
    expect(liveTrafficTypeName(0x0E), 'UNKNOWN');
  });

  group('liveTrafficRoute', () {
    final a = _repeater(0xAA, 47.70, -122.40);
    final b = _repeater(0xBB, 47.65, -122.35);

    test('a flood runs through its repeaters to the companion', () {
      final route = liveTrafficRoute(
        parseLiveTrafficFrame(
          _frame(payloadType: payloadTypeGRPTXT, path: [0xAA, 0xBB]),
        )!,
        contacts: [a, b],
        self: self,
      )!;
      expect(route.hops.map((h) => h.key), [
        a.publicKeyHex,
        b.publicKeyHex,
        'self',
      ]);
      expect(route.hops.any((h) => h.ghost), isFalse);
      expect(route.color, const Color(0xFF3B82F6));
    });

    test('an unknown repeater between known ones is a ghost', () {
      final route = liveTrafficRoute(
        parseLiveTrafficFrame(
          _frame(payloadType: payloadTypeGRPTXT, path: [0xAA, 0x77, 0xBB]),
        )!,
        contacts: [a, b],
        self: self,
      )!;
      expect(route.hops, hasLength(4));
      final ghost = route.hops[1];
      expect(ghost.ghost, isTrue);
      expect(ghost.key, 'hop-77');
      expect(ghost.position.latitude, closeTo(47.675, 1e-9));
      expect(ghost.dashedFrom(route.hops[0]), isTrue);
      expect(route.hops[3].dashedFrom(route.hops[2]), isFalse);
    });

    test('unknown repeaters outside known points are left out', () {
      final route = liveTrafficRoute(
        parseLiveTrafficFrame(
          _frame(payloadType: payloadTypeGRPTXT, path: [0x11, 0xBB]),
        )!,
        contacts: [a, b],
        self: self,
      )!;
      expect(route.hops.map((h) => h.key), [b.publicKeyHex, 'self']);
    });

    test('an advert starts at its sender', () {
      final route = liveTrafficRoute(
        parseLiveTrafficFrame(
          _frame(
            payloadType: payloadTypeADVERT,
            path: [0xBB],
            payload: _advertPayload(0x42, 47.80, -122.50),
          ),
        )!,
        contacts: [a, b],
        self: self,
      )!;
      expect(route.hops, hasLength(3));
      expect(route.hops.first.position.latitude, closeTo(47.80, 1e-6));
      expect(route.hops.first.key, startsWith('42'));
    });

    test('a direct packet only pulses at the companion', () {
      final route = liveTrafficRoute(
        parseLiveTrafficFrame(
          _frame(
            payloadType: payloadTypeTXTMSG,
            routeType: 2,
            path: [0xAA, 0xBB],
          ),
        )!,
        contacts: [a, b],
        self: self,
      )!;
      expect(route.hops.map((h) => h.key), ['self']);
    });

    test('nothing to place without a location', () {
      expect(
        liveTrafficRoute(
          parseLiveTrafficFrame(_frame(payloadType: payloadTypeACK))!,
          contacts: const [],
        ),
        isNull,
      );
    });

    test('a trace splits at its first unreached hop, with each SNR', () {
      final c = _repeater(0xCC, 47.62, -122.32);
      // tag, auth code, flags (1-byte hashes), then the route A, B, C.
      final payload = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0xAA, 0xBB, 0xCC];
      final route = liveTrafficRoute(
        parseLiveTrafficFrame(
          _frame(
            payloadType: payloadTypeTRACE,
            routeType: 2,
            path: [20, -12 & 0xFF], // two SNRs: A and B passed it on
            payload: payload,
          ),
        )!,
        contacts: [a, b, c],
        self: self,
      )!;
      expect(route.hops.map((h) => h.key), [
        a.publicKeyHex,
        b.publicKeyHex,
        c.publicKeyHex,
      ]);
      expect(route.isTrace, isTrue);
      expect(route.firstUnreached, 2);
      expect(route.hops.map((h) => h.snr), [5.0, -3.0, null]);
      expect(route.hops[2].dashedFrom(route.hops[1]), isFalse);
    });
  });

  group('radio2 (MediaMesh)', () {
    test('the marker tags the next RX log frame only', () {
      final reader = LiveTrafficFrameReader();
      final frame = _frame(payloadType: payloadTypeGRPDATA, path: [0xAA]);
      expect(reader.read(Uint8List.fromList([0x92, 0xA1])), isNull);
      expect(reader.read(frame)!.mediaMesh, isTrue);
      expect(reader.read(frame)!.mediaMesh, isFalse);
      // Something else between them clears it.
      reader.read(Uint8List.fromList([0x92, 0xA1]));
      reader.read(Uint8List.fromList([0x80, 0, 0, 0, 0]));
      expect(reader.read(frame)!.mediaMesh, isFalse);
      // Another radio's marker doesn't count.
      reader.read(Uint8List.fromList([0x92, 0xA0]));
      expect(reader.read(frame)!.mediaMesh, isFalse);
    });

    test('a radio2 packet is drawn as MediaMesh', () {
      final a = _repeater(0xAA, 47.70, -122.40);
      final reader = LiveTrafficFrameReader()
        ..read(Uint8List.fromList([0x92, 0xA1]));
      final route = liveTrafficRoute(
        reader.read(_frame(payloadType: payloadTypeGRPDATA, path: [0xAA]))!,
        contacts: [a],
        self: self,
      )!;
      expect(route.mediaMesh, isTrue);
      expect(route.hops, hasLength(2));
    });

    test('ring colour follows the analyzer in light and dark', () {
      expect(
        liveTrafficMediaMeshColor(Brightness.light),
        const Color(0xFFD946EF),
      );
      expect(
        liveTrafficMediaMeshColor(Brightness.dark),
        const Color(0xFFE879F9),
      );
    });
  });

  test('trace hash sizes follow the firmware', () {
    List<int> sizes(int flags, int routeLen) => [
      for (final h in liveTrafficTraceRoute(
        Uint8List.fromList([
          ...List.filled(8, 0),
          flags,
          ...List.filled(routeLen, 1),
        ]),
      ))
        h.length,
    ];
    expect(sizes(0, 3), [1, 1, 1]);
    expect(sizes(1, 4), [2, 2]);
    expect(sizes(2, 6), [3, 3]); // 6 isn't a multiple of 4: packed size 3
    expect(sizes(2, 8), [4, 4]);
  });

  test('the setting survives a reload', () async {
    SharedPreferences.setMockInitialValues({});
    final live = LiveTrafficSettings.instance..resetForTest();
    await live.load();
    expect(live.enabled, isFalse);
    await live.toggle();
    expect(live.enabled, isTrue);
    live.resetForTest();
    await live.load();
    expect(live.enabled, isTrue);
  });
}
