import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/widgets/live_traffic_layer.dart';

void main() {
  test('rings: one every 12 px, capped per hop and per path', () {
    expect(liveTrafficRingFractions(0, 40), isEmpty);
    expect(liveTrafficRingFractions(5, 40), [0.5]);
    expect(liveTrafficRingFractions(48, 40), [0.125, 0.375, 0.625, 0.875]);
    expect(liveTrafficRingFractions(10000, 40), hasLength(40));
    expect(liveTrafficRingCap(1), 40);
    expect(liveTrafficRingCap(10), 20);
    expect(liveTrafficRingCap(300), 1);
  });

  test('sonar rings and label follow the analyzer', () {
    expect(liveTrafficSonarRing(0, 0), isNull);
    final mid = liveTrafficSonarRing(550, 0)!;
    expect(mid.r, closeTo(21, 1e-9));
    expect(mid.a, closeTo(0.95 * 0.3789291416, 1e-6));
    expect(liveTrafficSonarRing(220, 1), isNull);
    expect(liveTrafficSonarRing(1400, 0), isNull);
    expect(liveTrafficSonarLabelAlpha(100), 0.5);
    expect(liveTrafficSonarLabelAlpha(1000), 1);
    expect(liveTrafficSonarLabelAlpha(2500), closeTo(0.5, 1e-9));
    expect(liveTrafficSonarLabelAlpha(3000), 0);
    expect(liveTrafficSnrText(4.5), '+4.5');
    expect(liveTrafficSnrText(-3), '−3.0');
  });
}
