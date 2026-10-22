import 'package:flutter_test/flutter_test.dart';
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
}
