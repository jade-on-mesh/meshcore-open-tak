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
}
