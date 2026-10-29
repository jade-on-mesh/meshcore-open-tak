import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/services/mediamesh_repeaters.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  const key = '20DECEA36E81AABBCCDD';

  test('a discover answer with radio2 on marks the repeater', () {
    final s = MediaMeshRepeaters.forTest();
    expect(s.isMediaMesh(key), isFalse);
    s.noteDiscover(
      key,
      const DiscoverRadio2(
        configured: true,
        mode: 2,
        frequencyKHz: 916000,
        bandwidthHz: 250000,
        spreadingFactor: 7,
        codingRate: 5,
      ),
    );
    expect(s.isMediaMesh(key), isTrue);
    expect(s.isMediaMesh(key.toLowerCase()), isTrue);
    expect(s.isMediaMesh('20decea3'), isTrue);
    final i = s.infoFor(key)!;
    expect(i.sends, isTrue);
    expect(i.profileLabel, '250 kHz SF7');
    expect(s.count, 1);
  });

  test('radio2 off clears the mark', () {
    final s = MediaMeshRepeaters.forTest();
    s.noteDiscover(
      key,
      const DiscoverRadio2(
        configured: true,
        mode: 1,
        bandwidthHz: 125000,
        spreadingFactor: 8,
      ),
    );
    expect(s.infoFor(key)!.sends, isFalse);
    s.noteDiscover(key, const DiscoverRadio2(configured: false));
    expect(s.isMediaMesh(key), isFalse);
    expect(s.count, 0);
  });

  test('an old answer no longer counts', () {
    final s = MediaMeshRepeaters.forTest();
    s.note(
      key,
      MediaMeshRepeaterInfo(
        active: true,
        mode: 2,
        bandwidthHz: 62500,
        heardAt: DateTime.now().subtract(const Duration(days: 31)),
      ),
    );
    expect(s.isMediaMesh(key), isFalse);
  });

  test('round-trips through json', () {
    final i = MediaMeshRepeaterInfo(
      active: true,
      mode: 1,
      frequencyKHz: 911150,
      bandwidthHz: 62500,
      spreadingFactor: 9,
      heardAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
    );
    final back = MediaMeshRepeaterInfo.fromJson(i.toJson())!;
    expect(back.active, isTrue);
    expect(back.mode, 1);
    expect(back.profileLabel, '62.5 kHz SF9');
    expect(back.heardAt, i.heardAt);
  });
}
