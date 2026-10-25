// The drone detector's Remote ID decoding and channel posts. The broadcasts
// and post strings are the ones Wadamesh TAK's test/test_drone_core.cpp
// checks, so a drone posted by a phone and by a standalone reads the same.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/models/channel.dart';
import 'package:meshcore_open/models/channel_message.dart';
import 'package:meshcore_open/team/remote_id.dart';
import 'package:meshcore_open/team/watch_feed.dart';

const _id = '1581F9DEV26590296G6G';

void _i32(Uint8List m, int o, int v) =>
    ByteData.sublistView(m).setInt32(o, v, Endian.little);
void _u16(Uint8List m, int o, int v) =>
    ByteData.sublistView(m).setUint16(o, v, Endian.little);

Uint8List _basicId(String id) {
  final m = Uint8List(25);
  m[0] = 0x00;
  m[1] = (1 << 4) | 2; // serial number, rotorcraft
  m.setRange(2, 2 + id.length, id.codeUnits);
  return m;
}

Uint8List _location(double lat, double lon, int speedRaw, int dir, int aglM) {
  final m = Uint8List(25);
  m[0] = 0x10;
  m[2] = dir;
  m[3] = speedRaw;
  _i32(m, 5, (lat * 1e7).round());
  _i32(m, 9, (lon * 1e7).round());
  _u16(m, 15, (aglM + 40 + 1000) * 2);
  _u16(m, 17, (aglM + 1000) * 2);
  return m;
}

Uint8List _system(double lat, double lon) {
  final m = Uint8List(25);
  m[0] = 0x40;
  _i32(m, 2, (lat * 1e7).round());
  _i32(m, 6, (lon * 1e7).round());
  return m;
}

List<int> _serviceData(Uint8List msg, int counter) => [0x0D, counter, ...msg];

WatchItem _parse(String text) => parseWatchMessage(
  Channel(index: 3, name: '#dronewatch', psk: Uint8List(16)),
  ChannelMessage(
    senderName: 'T-Deck',
    text: text,
    timestamp: DateTime(2026, 10, 21, 12),
    isOutgoing: false,
  ),
);

void main() {
  test('decodes a message pack', () {
    final pack = Uint8List.fromList([
      0xF0,
      25,
      3,
      ..._basicId(_id),
      ..._location(47.60378, -122.34052, 28, 90, 120),
      ..._system(47.60531, -122.34016),
    ]);
    final o = parseRemoteIdPayload(pack)!;
    expect(o.uasId, _id);
    expect(o.uaType, 2);
    expect(o.lat, closeTo(47.60378, 1e-7));
    expect(o.heightAglM, 120);
    expect(o.altGeoM, 160);
    expect(o.speedCms, 700);
    expect(o.headingDeg, 90);
    expect(o.opLon, closeTo(-122.34016, 1e-7));
    // Truncated, a wrong message size, too many: nothing.
    expect(parseRemoteIdPayload(pack.sublist(0, 40)), isNull);
    expect(
      parseRemoteIdPayload(Uint8List.fromList([0xF0, 24, 1, ..._basicId(_id)])),
      isNull,
    );
    expect(parseRemoteIdPayload(Uint8List.fromList([0xF0, 25, 11])), isNull);
    expect(parseRemoteIdPayload(Uint8List(10)), isNull);
  });

  test('location details: east/west flag, fast speeds, unknowns', () {
    final m = _location(10, 20, 100, 30, 0);
    m[1] = 0x03; // east/west + speed multiplier
    _u16(m, 15, 0);
    _u16(m, 17, 0);
    final o = parseRemoteIdPayload(m)!;
    expect(o.headingDeg, 210);
    expect(o.speedCms, 100 * 75 + 255 * 25);
    expect(o.heightAglM, 0);
    expect(o.altGeoM, 0);
    final zero = _location(0, 0, 0, 0, 10);
    expect(parseRemoteIdPayload(zero)!.hasPosition, isFalse);
  });

  test('Bluetooth: one message per advert, matched by address', () {
    final tr = RemoteIdTracker();
    final t0 = DateTime(2026, 10, 21, 12);
    RemoteIdObservation o(Uint8List m) =>
        parseRemoteIdServiceData(_serviceData(m, 1))!;
    // Position before the ID: nothing yet.
    expect(
      tr.ingest(o(_location(47.6, -122.3, 20, 10, 50)), 'AA', -70, t0),
      isNull,
    );
    var created = 0;
    final t = tr.ingest(
      o(_basicId(_id)),
      'AA',
      -70,
      t0,
      isNew: (_) => created++,
    )!;
    expect(created, 1);
    tr.ingest(
      o(_location(47.60378, -122.34052, 28, 45, 120)),
      'AA',
      -68,
      t0.add(const Duration(seconds: 1)),
    );
    tr.ingest(
      o(_system(47.60531, -122.34016)),
      'AA',
      -68,
      t0.add(const Duration(seconds: 2)),
    );
    expect(t.hasPosition && t.hasOperator, isTrue);
    expect(t.headingDeg, 45);
    expect(tr.length, 1);
    // Another address knows nothing; a forgotten one lends nothing.
    expect(tr.ingest(o(_location(1, 1, 0, 0, 0)), 'BB', -80, t0), isNull);
    expect(
      tr.ingest(
        o(_location(1, 1, 0, 0, 0)),
        'AA',
        -80,
        t0.add(const Duration(minutes: 3)),
      ),
      isNull,
    );
    // Not Remote ID service data.
    expect(parseRemoteIdServiceData([0x0C, 1, ..._basicId(_id)]), isNull);
    expect(parseRemoteIdServiceData([0x0D, 1, 2, 3]), isNull);
    // Aging.
    expect(tr.age(t0.add(const Duration(minutes: 6))), isTrue);
    expect(tr.length, 0);
  });

  test('the post (same strings as Wadamesh TAK)', () {
    final t = RemoteIdTrack(_id, DateTime(2026));
    expect(remoteIdPost(t), isNull); // no position
    t
      ..lat = 47.60378
      ..lon = -122.34052
      ..heightAglM = 120
      ..speedCms = 700
      ..headingDeg = 90;
    expect(
      remoteIdPost(t),
      'DRONE 1581F9DEV26590296G6G h120m 7.0m/s hdg90\n'
      'https://maps.google.com/?q=47.60378,-122.34052',
    );
    t
      ..opLat = 47.60531
      ..opLon = -122.34016
      ..speedCms = 1240;
    final text = remoteIdPost(t)!;
    expect(
      text,
      'DRONE 1581F9DEV26590296G6G h120m 12m/s hdg90\n'
      'https://maps.google.com/?q=47.60378,-122.34052\n'
      'Op https://maps.google.com/?q=47.60531,-122.34016',
    );

    // Watch reads it back as a tracked drone with its operator.
    final w = _parse(text);
    expect(w.trackId, 'DRONE $_id');
    expect(w.detail, 'h120m 12m/s');
    expect(w.bearing, 90);
    expect(w.lat, closeTo(47.60378, 1e-9));
    expect(w.lat2, closeTo(47.60531, 1e-9));
    expect(w.label2, 'Op');

    t
      ..speedCms = 0
      ..heightAglM = 0
      ..altGeoM = 95
      ..opLat = null
      ..opLon = null;
    expect(
      remoteIdPost(t),
      'DRONE 1581F9DEV26590296G6G alt95m 0.0m/s\n'
      'https://maps.google.com/?q=47.60378,-122.34052',
    );
    expect(_parse(remoteIdPost(t)!).bearing, isNull);

    expect(
      remoteIdPost(
        RemoteIdTrack('ABC', DateTime(2026))
          ..lat = 1
          ..lon = 1,
      ),
      isNull,
    );
    expect(
      remoteIdPost(
        RemoteIdTrack('FIN.87astr dge12k8', DateTime(2026))
          ..lat = 1
          ..lon = 1,
      ),
      startsWith('DRONE FIN87astrdge12k8 '),
    );
    expect(remoteIdSpeed(95), '1.0m/s');
    expect(remoteIdSpeed(949), '9.5m/s');
    expect(remoteIdSpeed(950), '10m/s');
  });

  test('posts once a minute at most, again after 200 m', () {
    final t0 = DateTime(2026, 10, 21, 12);
    final t = RemoteIdTrack(_id, t0)
      ..lat = 47.6
      ..lon = -122.3;
    expect(t.postDue(t0), isTrue);
    t.markPosted(t0);
    expect(t.postDue(t0.add(const Duration(seconds: 30))), isFalse);
    expect(
      t.postDue(t0.add(const Duration(minutes: 2))),
      isFalse,
    ); // hasn't moved
    t.lat = 47.603; // ~330 m north
    expect(t.postDue(t0.add(const Duration(seconds: 59))), isFalse);
    expect(t.postDue(t0.add(const Duration(minutes: 2))), isTrue);
  });
}
