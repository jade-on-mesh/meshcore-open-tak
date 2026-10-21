import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/team/road_directions.dart';
import 'package:meshcore_open/team/road_voice.dart';

// 1 km east, a left turn, 1 km north (as road_directions_test.dart).
const _lat0 = 47.6, _lon0 = -122.33;
final _dLon = 1000 / (111320.0 * 0.6743);
final _dLat = 1000 / 110540.0;

RoadRoute _route(RoadMode mode) => RoadRoute(
  mode: mode,
  shape: [
    for (var i = 0; i <= 10; i++) (_lat0, _lon0 + _dLon * i / 10),
    for (var i = 1; i <= 10; i++) (_lat0 + _dLat * i / 10, _lon0 + _dLon),
  ],
  maneuvers: const [
    RoadManeuver(
      instruction: 'Drive east on Pine Street.',
      type: 1,
      beginIndex: 0,
      verbalPre: 'Drive east on Pine Street.',
      verbalPost: 'Continue for 1 kilometer.',
    ),
    RoadManeuver(
      instruction: 'Turn left onto 5th Avenue.',
      type: 15,
      beginIndex: 10,
      verbalAlert: 'Turn left onto 5th Avenue.',
      verbalPre: 'Turn left onto 5th Avenue.',
      verbalPost: 'Continue for 1 kilometer.',
    ),
    RoadManeuver(
      instruction: 'You have arrived at your destination.',
      type: 4,
      beginIndex: 20,
      verbalAlert: 'You will arrive at your destination.',
      verbalPre: 'You have arrived at your destination.',
    ),
  ],
  lengthM: 2000,
  timeS: 240,
  to: (0, 0),
);

void main() {
  final w = RoadVoiceWords.english;

  test('spoken distances round the way people say them', () {
    expect(spokenDistanceEnglish(47), '50 meters');
    expect(spokenDistanceEnglish(420), '400 meters');
    expect(spokenDistanceEnglish(980), '1.0 kilometers');
    expect(spokenDistanceEnglish(1260), '1.3 kilometers');
    expect(spokenDistanceEnglish(23400), '23 kilometers');
  });

  test('a drive: start, early call, at the turn, the stretch after, arrival', () {
    final r = _route(RoadMode.drive);
    final g = RoadGuide(r);
    final a = RoadAnnouncer();
    final said = <String>[];
    // Driving east 50 m at a time, then north.
    for (var m = 0.0; m <= 2000; m += 25) {
      final (lat, lon) = m <= 1000
          ? (_lat0, _lon0 + _dLon * m / 1000)
          : (_lat0 + _dLat * (m - 1000) / 1000, _lon0 + _dLon);
      final s = a.road(r, g.update(lat, lon), w);
      if (s != null) said.add(s);
    }
    expect(said, [
      'Drive east on Pine Street.',
      'In 500 meters, Turn left onto 5th Avenue.',
      'Turn left onto 5th Avenue.',
      'Continue for 1 kilometer.',
      'In 500 meters, You will arrive at your destination.',
      'You have arrived.',
    ]);
  });

  test('a new route after leaving the old one says so', () {
    final a = RoadAnnouncer();
    final r1 = _route(RoadMode.walk);
    final r2 = _route(RoadMode.walk);
    expect(a.road(r1, RoadGuide(r1).update(_lat0, _lon0), w), 'Drive east on Pine Street.');
    expect(a.road(r2, RoadGuide(r2).update(_lat0, _lon0 + _dLon * 0.2), w), 'Rerouting.');
  });

  test('walking calls come later than driving ones', () {
    final r = _route(RoadMode.walk);
    final g = RoadGuide(r);
    final a = RoadAnnouncer();
    a.road(r, g.update(_lat0, _lon0), w); // the start
    expect(a.road(r, g.update(_lat0, _lon0 + _dLon * 0.6), w), isNull); // 400 m to go
    expect(
      a.road(r, g.update(_lat0, _lon0 + _dLon * 0.92), w),
      'In 80 meters, Turn left onto 5th Avenue.',
    );
    expect(a.road(r, g.update(_lat0, _lon0 + _dLon * 0.99), w), 'Turn left onto 5th Avenue.');
  });

  test('a shared route: its turns from its shape', () {
    const pts = [(47.6, -122.33), (47.6, -122.31523), (47.60905, -122.31523)];
    final a = RoadAnnouncer();
    String? at(double lat, double lon, int next) =>
        a.sharedRoute('r>', routeNextTurn(pts, next, lat, lon), RoadMode.walk, w);
    expect(at(47.6, -122.325, 1), isNull); // 730 m from the corner
    expect(at(47.6, -122.3165, 1), 'In 100 meters, Turn left');
    expect(at(47.6, -122.3153, 1), 'Turn left');
    expect(at(47.6, -122.3152, 1), isNull); // said already
    expect(at(47.6045, -122.31523, 2), isNull); // heading north, 500 m to go
    expect(at(47.60900, -122.31523, 2), 'You have arrived.');
    expect(at(47.60901, -122.31523, 2), isNull);
  });
}
