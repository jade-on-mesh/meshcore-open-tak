import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:meshcore_open/team/photo_mosaic.dart';
import 'package:meshcore_open/team/photo_mosaic_prefs.dart';
import 'package:meshcore_open/vox/voice_wire.dart';

MosaicPhoto _p(String sid, double lat, double lon, int min) => MosaicPhoto(
  envelope: VoxVoiceEnvelope(
    sessionId: sid,
    mode: VoxVoiceMode.av1Image,
    totalPackets: 3,
    durationSeconds: 133,
  ),
  lat: lat,
  lon: lon,
  time: DateTime(2026, 10, 22, 12, min),
  from: 'Sam',
  where: '#ops',
  approximate: false,
);

void main() {
  test('a place in the caption', () {
    expect(mosaicCaptionPosition('Bridge 📍47.60378,-122.34052'), (
      47.60378,
      -122.34052,
    ));
    expect(mosaicCaptionPosition('at 45.5625, -122.6108 now'), (
      45.5625,
      -122.6108,
    ));
    expect(mosaicCaptionPosition('no place'), isNull);
  });

  test('nearest point in time', () {
    final t = DateTime(2026, 10, 22, 12);
    final track = [
      (1.0, 1.0, t.subtract(const Duration(minutes: 20))),
      (2.0, 2.0, t.add(const Duration(minutes: 3))),
    ];
    expect(mosaicNearestInTime(track, t), (2.0, 2.0));
    expect(mosaicNearestInTime(track, t.add(const Duration(hours: 2))), isNull);
  });

  test('photos close on screen group together', () {
    final a = _p('00000001', 0, 0, 0), b = _p('00000002', 0, 0.0001, 1);
    final c = _p('00000003', 1, 1, 2);
    Offset at(LatLng p) => Offset(p.longitude * 10000, p.latitude * 10000);
    final g = clusterMosaic([a, b, c], at);
    expect(g.length, 2);
    expect(g.first.length, 2);
  });

  test('tagging my photos', () {
    PhotoMosaicPrefs.ownPosition = () => (47.6, -122.3);
    PhotoMosaicPrefs.tagOwn.value = false;
    expect(PhotoMosaicPrefs.tagged('Bridge'), 'Bridge');
    PhotoMosaicPrefs.tagOwn.value = true;
    expect(PhotoMosaicPrefs.tagged('Bridge'), 'Bridge 📍47.60000,-122.30000');
    expect(PhotoMosaicPrefs.tagged(''), '📍47.60000,-122.30000');
    expect(_p('00000001', 0, 0, 0).caption, '');
  });
}
