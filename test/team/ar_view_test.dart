import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/team/ar_view.dart';

// Phone upright, screen towards you, in the northern hemisphere: the field
// points north and down. Device axes: x right, y up, z out of the screen.
void main() {
  // Facing north: north is -z, down is -y.
  const g = [0.0, 9.81, 0.0];
  const fieldNorth = [0.0, -40.0, -20.0];

  test('facing north, level', () {
    final p = arCameraPose(g, fieldNorth)!;
    expect(p.azimuth, closeTo(0, 1e-6));
    expect(p.pitch, closeTo(0, 1e-6));
  });

  test('facing east: north is to the left (-x)', () {
    final p = arCameraPose(g, const [-20.0, -40.0, 0.0])!;
    expect(p.azimuth, closeTo(90, 1e-6));
  });

  test('declination is added', () {
    final p = arCameraPose(g, fieldNorth, declination: 15)!;
    expect(p.azimuth, closeTo(15, 1e-6));
  });

  test('tilted up 30 degrees', () {
    // Rotating the phone back about x: gravity leans into +z.
    const g30 = [0.0, 8.4957, -4.905];
    final p = arCameraPose(g30, fieldNorth)!;
    expect(p.pitch, closeTo(30, 0.1));
  });

  test('angle difference wraps', () {
    expect(arAngleDiff(350, 10), closeTo(20, 1e-9));
    expect(arAngleDiff(10, 350), closeTo(-20, 1e-9));
  });

  test('no usable field', () {
    expect(arCameraPose(g, const [0.0, 0.0, 0.0]), isNull);
  });

  test('chime: on coming into the middle, again after leaving', () {
    final inView = <String>{};
    expect(arChimeStep({'a': 30, 'b': -20}, inView), isEmpty);
    expect(arChimeStep({'a': 5, 'b': -20}, inView), ['a']);
    expect(arChimeStep({'a': 1, 'b': -10}, inView), isEmpty); // still there
    expect(arChimeStep({'a': 10, 'b': -3}, inView), ['b']); // a not out yet
    expect(arChimeStep({'a': 4, 'b': -3}, inView), isEmpty);
    expect(arChimeStep({'a': 20, 'b': -3}, inView), isEmpty); // a left
    expect(arChimeStep({'a': 2, 'b': -3}, inView), ['a']); // and is back
    expect(arChimeStep({'a': 2}, inView), isEmpty); // b gone from the list
    expect(inView, {'a'});
  });
}
