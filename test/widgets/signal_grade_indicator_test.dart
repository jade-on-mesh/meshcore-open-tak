import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/models/companion_radio_stats.dart';
import 'package:meshcore_open/widgets/signal_grade_indicator.dart';

CompanionRadioStats _stats(int rssi, int noise) {
  return CompanionRadioStats(
    noiseFloorDbm: noise,
    lastRssiDbm: rssi,
    lastSnrDb: 0,
    txAirSecs: 0,
    rxAirSecs: 0,
    receivedAt: DateTime.now(),
  );
}

void main() {
  group('marginForStats / gradeForMargin (instantaneous, unchanged thresholds)', () {
    test('null stats is no data', () {
      expect(marginForStats(null), isNull);
      expect(signalGradeForStats(null).label, 'no data');
    });

    test('margin thresholds match both Lua builds exactly', () {
      expect(gradeForMargin(20).label, 'excellent');
      expect(gradeForMargin(19.9).label, 'good');
      expect(gradeForMargin(12).label, 'good');
      expect(gradeForMargin(11.9).label, 'fair');
      expect(gradeForMargin(6).label, 'fair');
      expect(gradeForMargin(5.9).label, 'poor');
      expect(gradeForMargin(0).label, 'poor');
      expect(gradeForMargin(-0.1).label, 'very poor');
    });

    test('a single sample grades on its own margin, no averaging', () {
      // rssi -70, noise -90 -> margin 20 -> excellent, in isolation.
      expect(signalGradeForStats(_stats(-70, -90)).label, 'excellent');
    });
  });

  group('SignalMarginAverager (the actual fix)', () {
    test('starts at no data with nothing fed yet', () {
      final avg = SignalMarginAverager();
      expect(avg.update(null).label, 'no data');
    });

    test('a single strong sample alone still grades excellent (matches Lua for a lone reading)', () {
      final avg = SignalMarginAverager();
      expect(avg.update(_stats(-70, -90)).label, 'excellent'); // margin 20
    });

    test(
      'one lucky excellent reading among a run of poor ones is smoothed down, not shown as-is - '
      'this is the actual bug: the un-averaged version would have shown "excellent" here',
      () {
        final avg = SignalMarginAverager();
        // Six genuinely poor readings (margin 2 each) ...
        for (var i = 0; i < 6; i++) {
          avg.update(_stats(-98, -100));
        }
        expect(avg.update(_stats(-98, -100)).label, 'poor');
        // ... then one lucky excellent packet (margin 40) arrives.
        final grade = avg.update(_stats(-60, -100));
        expect(
          grade.label,
          isNot('excellent'),
          reason: 'a single strong packet must not override a sustained run of poor readings',
        );
        // Average of seven 2s and one 40 over 8 samples = 54/8 = 6.75 -> fair, not poor or excellent.
        expect(grade.label, 'fair');
      },
    );

    test('the rolling window is capped at 8 samples, matching Lua\'s SIGNAL_HISTORY_LEN', () {
      final avg = SignalMarginAverager();
      // Eight very poor readings (margin -10) ...
      for (var i = 0; i < 8; i++) {
        avg.update(_stats(-110, -100));
      }
      expect(avg.update(_stats(-110, -100)).label, 'very poor');
      // ... then one excellent reading (margin 40) should only ever be
      // 1-of-8 in the window, never diluted by more than 8 total samples.
      final afterOneGood = avg.update(_stats(-60, -100));
      // 7 * -10 + 1 * 40 = -30, / 8 = -3.75 -> still very poor.
      expect(afterOneGood.label, 'very poor');
    });

    test('feeding the exact same stats object twice does not double-count it', () {
      final avg = SignalMarginAverager();
      final s = _stats(-70, -90); // margin 20
      avg.update(s);
      final grade = avg.update(s);
      expect(grade.label, 'excellent');
      // If this were double-counted the average would still be 20 anyway
      // (same value twice), so also check via a second, different-margin
      // sample that the window only grew by one real entry.
      final grade2 = avg.update(_stats(-100, -100)); // margin 0 -> poor
      // (20 + 0) / 2 = 10 -> fair, not (20*2 + 0)/3 which would also
      // happen to be fair here by coincidence, so use a sharper case:
      expect(grade2.label, 'fair');
    });

    test('null stats clears the window - a lost connection cannot leave a stale good/bad average behind', () {
      final avg = SignalMarginAverager();
      avg.update(_stats(-70, -90)); // excellent
      expect(avg.update(null).label, 'no data');
      // A single poor reading right after reconnecting should grade on
      // its own, not be softened by the pre-disconnect excellent sample.
      expect(avg.update(_stats(-100, -95)).label, 'very poor'); // margin -5
    });

    test('reset() explicitly clears the window (used on disconnect/reconnect in the widget)', () {
      final avg = SignalMarginAverager();
      avg.update(_stats(-70, -90));
      avg.reset();
      expect(avg.update(_stats(-100, -95)).label, 'very poor');
    });
  });
}
