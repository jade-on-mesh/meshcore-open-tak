import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/team/team_coords.dart';
import 'package:meshcore_open/team/team_wire.dart';

void main() {
  group('MGRS', () {
    test('the origin', () {
      expect(toMgrs(0, 0), '31N AA 66021 00000');
    });

    test('Washington Monument', () {
      expect(toMgrs(38.8895, -77.0352), startsWith('18S UJ 2348'));
    });

    test('round-trips within a metre across the world', () {
      final rng = Random(7);
      for (var i = 0; i < 400; i++) {
        final lat = -79.5 + rng.nextDouble() * 163;
        final lon = -179.9 + rng.nextDouble() * 359.8;
        final s = toMgrs(lat, lon)!;
        final p = parseMgrs(s)!;
        final d = teamDistanceMeters(lat, lon, p.$1, p.$2);
        expect(d, lessThan(2.5), reason: '$lat,$lon -> $s -> $p');
      }
    });

    test('accepts compact and coarse forms', () {
      final full = parseMgrs('18SUJ2348706483')!;
      expect(full.$1, closeTo(38.8895, 0.0002));
      final coarse = parseMgrs('18S UJ 234 064')!; // 100 m cell centre
      expect(
        teamDistanceMeters(full.$1, full.$2, coarse.$1, coarse.$2),
        lessThan(150),
      );
    });

    test('Norway zone exception', () {
      expect(toMgrs(60, 5), startsWith('32V'));
    });

    test('poles are not MGRS', () {
      expect(toMgrs(86, 10), isNull);
    });
  });

  group('parsing', () {
    test('decimal with signs or hemispheres', () {
      expect(parseTeamCoord('47.6062, -122.3321'), (47.6062, -122.3321));
      expect(parseTeamCoord('47.6062N 122.3321W'), (47.6062, -122.3321));
      expect(parseTeamCoord('-33.9 151.2'), (-33.9, 151.2));
    });

    test('DMS', () {
      final p = parseTeamCoord('47°36\'22.3"N 122°19\'55.6"W')!;
      expect(p.$1, closeTo(47.60619, 1e-4));
      expect(p.$2, closeTo(-122.33211, 1e-4));
    });

    test('formatting DMS', () {
      expect(
        teamFormatCoord(47.60619, -122.33211, CoordFormat.dms),
        '47°36\'22.3"N 122°19\'55.6"W',
      );
    });

    test('rejects nonsense', () {
      expect(parseTeamCoord('hello'), isNull);
      expect(parseTeamCoord('95, 10'), isNull);
    });
  });
}
