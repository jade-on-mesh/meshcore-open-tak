import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/team/map_highlights.dart';

void main() {
  final hl = MapHighlights.instance;
  final t0 = DateTime(2026, 10, 19, 12);

  setUp(() => hl.resetForTest());

  test('a new point flashes for 10 minutes from when it appeared', () {
    expect(hl.isNew('a', itemTime: t0, now: t0), isTrue);
    expect(
      hl.isNew('a', now: t0.add(const Duration(minutes: 9, seconds: 59))),
      isTrue,
    );
    expect(hl.isNew('a', now: t0.add(const Duration(minutes: 10))), isFalse);
  });

  test('a point already old when it first shows up is not new', () {
    final old = t0.subtract(const Duration(hours: 2));
    expect(hl.isNew('b', itemTime: old, now: t0), isFalse);
    // A few minutes of clock difference is still new.
    final skewed = t0.subtract(const Duration(minutes: 12));
    expect(hl.isNew('c', itemTime: skewed, now: t0), isTrue);
  });

  test('the duration follows the setting; 0 turns it off', () {
    hl.resetForTest(minutes: 1);
    expect(hl.isNew('d', now: t0), isTrue);
    expect(hl.isNew('d', now: t0.add(const Duration(minutes: 2))), isFalse);
    hl.resetForTest(minutes: 0);
    expect(hl.isNew('e', now: t0), isFalse);
  });
}
