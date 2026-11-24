import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/models/contact.dart';
import 'package:meshcore_open/services/live_traffic.dart';
import 'package:meshcore_open/services/mediamesh_heard.dart';
import 'package:shared_preferences/shared_preferences.dart';

Contact _node(int first, int second, {int type = advTypeRepeater}) => Contact(
  publicKey: Uint8List(32)
    ..[0] = first
    ..[1] = second,
  name: 'N$first',
  type: type,
  pathLength: 0,
  path: Uint8List(0),
  latitude: 47.6,
  longitude: -122.3,
  lastSeen: DateTime.utc(2026),
);

LiveTrafficPacket _packet({
  required int type,
  int route = 1,
  List<int> path = const [],
  int width = 1,
  List<int> payload = const [1, 2, 3],
}) => LiveTrafficPacket(
  routeType: route,
  payloadType: type,
  hashWidth: width,
  pathBytes: Uint8List.fromList(path),
  payload: Uint8List.fromList(payload),
  snr: 0,
  rssi: -90,
  mediaMesh: true,
);

Uint8List _advert(int first) {
  final p = Uint8List(32 + 4 + 64 + 1);
  p[0] = first;
  return p;
}

void main() {
  final a = _node(0xAA, 0x01);
  final b = _node(0xBB, 0x01);
  final b2 = _node(0xBB, 0x02);
  final chat = _node(0xCC, 0x01, type: advTypeChat);

  group('mediaMeshSenderKey (CoreScope "heard")', () {
    test('a flood with a path: its last hop, when only one repeater has it',
        () {
      expect(
        mediaMeshSenderKey(
          _packet(type: payloadTypeGRPDATA, path: [0xBB, 0xAA]),
          [a, b, chat],
        ),
        a.publicKeyHex.toLowerCase(),
      );
      // Two repeaters share BB: not evidence.
      expect(
        mediaMeshSenderKey(
          _packet(type: payloadTypeGRPDATA, path: [0xAA, 0xBB]),
          [a, b, b2],
        ),
        isNull,
      );
      // A 2-byte hash tells them apart.
      expect(
        mediaMeshSenderKey(
          _packet(type: payloadTypeGRPDATA, path: [0xBB, 0x02], width: 2),
          [a, b, b2],
        ),
        b2.publicKeyHex.toLowerCase(),
      );
    });

    test('an advert with no path: its sender, companions too', () {
      expect(
        mediaMeshSenderKey(
          _packet(type: payloadTypeADVERT, payload: _advert(0xCC)),
          [a],
        ),
        startsWith('cc'),
      );
      expect(
        mediaMeshSenderKey(
          _packet(type: payloadTypeADVERT, route: 2, payload: _advert(0xCC)),
          [a],
        ),
        startsWith('cc'),
      );
    });

    test('nothing for encrypted senders, direct paths and traces', () {
      expect(mediaMeshSenderKey(_packet(type: payloadTypeGRPDATA), [a]), isNull);
      expect(
        mediaMeshSenderKey(
          _packet(type: payloadTypeTXTMSG, route: 2, path: [0xAA]),
          [a],
        ),
        isNull,
      );
      expect(
        mediaMeshSenderKey(
          _packet(type: payloadTypeTRACE, route: 2, path: [0xAA]),
          [a],
        ),
        isNull,
      );
    });
  });

  test('heard nodes are kept 30 days and survive a reload', () async {
    SharedPreferences.setMockInitialValues({});
    final heard = MediaMeshHeard.instance..resetForTest();
    await heard.load();
    final now = DateTime.now();
    heard.note(chat.publicKeyHex, at: now);
    heard.note(a.publicKeyHex, at: now.subtract(const Duration(days: 31)));
    expect(heard.heard(chat.publicKeyHex), isTrue);
    expect(heard.heard(a.publicKeyHex), isFalse);
    await pumpEventQueue();
    heard.resetForTest();
    await heard.load();
    expect(heard.heard(chat.publicKeyHex.toUpperCase()), isTrue);
    expect(heard.heard(a.publicKeyHex), isFalse);
  });

  test('the map filter draws main-mesh traffic hidden or faint', () {
    const route = LiveTrafficRoute(
      typeName: 'GRP_TXT',
      color: Color(0xFF3B82F6),
      hops: [LiveTrafficHop('self', LatLng(47.6, -122.3))],
    );
    const mm = LiveTrafficRoute(
      typeName: 'GRP_DATA',
      color: Color(0xFF8B5CF6),
      hops: [LiveTrafficHop('self', LatLng(47.6, -122.3))],
      mediaMesh: true,
    );
    expect(LiveTrafficFilter.all.alphaFor(route), 1);
    const only = LiveTrafficFilter(mediaMeshOnly: true);
    expect(only.alphaFor(route), 0);
    expect(only.alphaFor(mm), 1);
    const faint = LiveTrafficFilter(mediaMeshOnly: true, othersOpacity: 0.15);
    expect(faint.alphaFor(route), 0.15);
    expect(faint.alphaFor(mm), 1);
  });
}
