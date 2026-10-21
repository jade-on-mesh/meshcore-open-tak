import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/models/radio_settings.dart';
import 'package:meshcore_open/services/media_mesh.dart';
import 'package:meshcore_open/services/media_mesh_find.dart';

void main() {
  // The same cases as Wadamesh TAK's testFind (test/test_mediamesh_core.cpp).
  test('picks the preset radio2 heard on', () {
    expect(mediaMeshFindPick(0, 0), isNull);
    expect(mediaMeshFindPick(3, 0), LoRaBandwidth.bw250);
    expect(mediaMeshFindPick(0, 2), LoRaBandwidth.bw125);
    expect(mediaMeshFindPick(1, 5), LoRaBandwidth.bw125);
    expect(mediaMeshFindPick(4, 4), LoRaBandwidth.bw250); // a tie: fast
  });

  test('result reports the packets heard on its pick', () {
    const r = MediaMeshFindResult(
      heard: [1, 6],
      repeatersAnswered: 3,
      frequencyMHz: 911.15,
    );
    expect(r.pick, LoRaBandwidth.bw125);
    expect(r.heardOnPick, 6);
  });

  test('listens with a listen-only temporary radio2', () {
    final s = MediaMeshSettings.defaults.copyWith(
      bandwidth: LoRaBandwidth.bw125,
    );
    expect(
      buildTempRadio2Command(s, 2, mode: Radio2Mode.rx),
      'set tempradio2 911.150,125,7,5,rx,2',
    );
    expect(
      buildTempRadio2Command(s, 15),
      'set tempradio2 911.150,125,7,5,rxtx,15',
    );
  });
}
