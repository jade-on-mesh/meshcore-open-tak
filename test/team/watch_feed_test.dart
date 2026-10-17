import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/models/channel.dart';
import 'package:meshcore_open/models/channel_message.dart';
import 'package:meshcore_open/team/watch_feed.dart';

final _ch = Channel(index: 3, name: '#icewatch', psk: Uint8List(16));

WatchItem _parse(String text) => parseWatchMessage(
  _ch,
  ChannelMessage(
    senderName: 'IceBot',
    text: text,
    timestamp: DateTime(2026, 10, 3, 12, 16),
    isOutgoing: false,
  ),
);

void main() {
  test('parses a condensed report', () {
    final it = _parse(
      '🔴 CRITICAL\n10-03 11:30\n🧊 @Auburn E Main St\n3-🚗 5-🥾\n'
      'https://iceout.org/reportInfo/151189/',
    );
    expect(it.level, WatchLevel.critical);
    expect(it.statusWord, 'CRITICAL');
    expect(it.when, '10-03 11:30');
    expect(it.place, 'Auburn E Main St');
    expect(it.counts, [(3, '🚗'), (5, '🥾')]);
    expect(it.url, 'https://iceout.org/reportInfo/151189/');
    expect(it.isStructured, isTrue);
    expect(it.hasPosition, isFalse);
  });

  test('reads every status colour', () {
    expect(_parse('🟡 ACTIVE\n@Tacoma Pacific Ave S').level, WatchLevel.active);
    expect(_parse('🟢 OBSERVED\n@Kent').level, WatchLevel.observed);
    expect(_parse('🔵 OTHER\n@Bellevue').level, WatchLevel.other);
  });

  test('a single count line still parses', () {
    final it = _parse(
      '🟢 OBSERVED\n10-01 14:44\n🧊 @Federal Way S 320th St\n1-🥾',
    );
    expect(it.counts, [(1, '🥾')]);
  });

  test('plain messages fall back to text', () {
    final it = _parse('Drone heard over the ridge, heading north');
    expect(it.isStructured, isFalse);
    expect(it.headline, 'Drone heard over the ridge, heading north');
    expect(it.level, WatchLevel.none);
  });

  test('coordinates and shared markers become positions', () {
    final a = _parse('Drone at 47.30731, -122.22850 low and slow');
    expect(a.lat, closeTo(47.30731, 1e-6));
    expect(a.lon, closeTo(-122.2285, 1e-6));
    final b = _parse('m:47.5,-122.1|Drone|poi');
    expect(b.hasPosition, isTrue);
  });

  test('IceBot report with a pinned position (as posted on #ibtest)', () {
    final it = _parse(
      '🟢 OBSERVED\n10-12 15:00\n@Portland NE Killingsworth St\n1-🥾\n'
      '📍 45.5625,-122.6108',
    );
    expect(it.level, WatchLevel.observed);
    expect(it.place, 'Portland NE Killingsworth St');
    expect(it.lat, 45.5625);
    expect(it.lon, -122.6108);
    expect(it.otherLines, isEmpty); // the pin line is the map point, not text
    expect(_parse('https://iceout.org/reportInfo/154321/').isBareLink, isTrue);
  });

  test('a drone detector report: drone, operator, height and speed', () {
    for (final text in [
      'DRONE 1581F9DEV26590296G6G h251m 1m/s '
          'https://maps.google.com/?q=47.60378,-122.34052 '
          'Op https://maps.google.com/?q=47.60531,-122.34016',
      'DRONE\n1581F9DEV26590296G6G\nh251m 1m/s\n'
          'https://maps.google.com/?q=47.60378,-122.34052\nOp\n'
          'https://maps.google.com/?q=47.60531,-122.34016',
    ]) {
      final it = _parse(text);
      expect(it.isDrone, isTrue);
      expect(it.trackId, 'DRONE 1581F9DEV26590296G6G');
      expect(it.detail, 'h251m 1m/s');
      expect((it.lat, it.lon), (47.60378, -122.34052));
      expect((it.lat2, it.lon2), (47.60531, -122.34016));
      expect(it.label2, 'Op');
      expect(it.droneLabel(), 'DRONE 1581F9DE h251m 1m/s');
      expect(it.bearing, isNull);
    }
  });

  test('a drone is found after a prefix, and chat about drones is not', () {
    final it = _parse(
      '🚁 Detector: DRONE: 1581F9DEV26590296G6G '
      'https://maps.google.com/?q=47.60378,-122.34052',
    );
    expect(it.isDrone, isTrue);
    expect(it.droneLabel(), 'DRONE 1581F9DE');
    expect(it.droneLabel(44), 'DRONE 1581F9DE 044° NE');
    final hdg = _parse(
      'DRONE 1581F9DEV26590296G6G h120m 4m/s hdg 270 '
      'https://maps.google.com/?q=47.60378,-122.34052',
    );
    expect(hdg.bearing, 270);
    expect(hdg.droneLabel(10), 'DRONE 1581F9DE h120m 4m/s 270° W');
    expect(
      _parse('saw a drone overhead at 47.60378,-122.34052').isDrone,
      isFalse,
    );
  });

  test('a sender clock stuck at 1970 uses the given time', () {
    final t = DateTime(2026, 10, 12, 19, 20);
    final it = parseWatchMessage(
      _ch,
      ChannelMessage(
        senderName: 'DARS-C6L',
        text: 'DRONE ABCDEF123 https://maps.google.com/?q=47.6,-122.3',
        timestamp: DateTime.fromMillisecondsSinceEpoch(0),
        isOutgoing: false,
      ),
      time: t,
    );
    expect(it.time, t);
  });

  test('ICE watch reports are tagged ICE on the map', () {
    expect(watchMapTag('#icewatch', 'Somebody'), 'ICE');
    expect(watchMapTag('#ibtest', 'IceBot'), 'ICE');
    expect(watchMapTag('#dronewatch', 'DARS-C6L'), '#dronewatch');
  });

  test('SeaBot earthquakes: magnitude, place, depth, position', () {
    final it = _parse(
      'Earthquake M3.9 mw | 24 km ESE of Castle Rock, Washington | '
      '11:09:28 UTC | depth 9 km | 46.22N 122.60W',
    );
    expect(it.isQuake, isTrue);
    expect(it.magnitude, 3.9);
    expect(it.lat, closeTo(46.22, 1e-9));
    expect(it.lon, closeTo(-122.60, 1e-9));
    expect(it.place, '24 km ESE of Castle Rock, Washington');
    expect(it.detail, 'depth 9 km');
    expect(it.when, '11:09:28 UTC');
    expect(it.level, WatchLevel.other);
    expect(it.mapLabel, 'QUAKE M3.9 Castle Rock');
    final big = _parse(
      'Earthquake M5.2 ml | 5 km WNW of Wauna, Washington | 21:05:56 UTC | '
      'depth 26 km | 47.40N 122.71W',
    );
    expect(big.level, WatchLevel.critical);
    expect(big.mapLabel, 'QUAKE M5.2 Wauna');
  });

  test('other ways of writing a position', () {
    LatLngPair p(String t) {
      final it = _parse(t);
      return (it.lat, it.lon);
    }

    expect(p('seen at 46.22N 122.60W'), (46.22, -122.60));
    expect(p('fire 33.9° S, 18.4° E'), (-33.9, 18.4));
    expect(p('N47.6 W122.3 smoke'), (47.6, -122.3));
    expect(p('lat: 45.52 lon: -122.68'), (45.52, -122.68));
    expect(p('Latitude=45.5 Longitude=-122.6'), (45.5, -122.6));
    expect(p('pos 45.5625 -122.6108'), (45.5625, -122.6108));
    (double, double) near(LatLngPair v) => (
      (v.$1! * 1e4).roundToDouble() / 1e4,
      (v.$2! * 1e4).roundToDouble() / 1e4,
    );
    expect(near(p('45°31\'30"N 122°40\'30"W')), (45.525, -122.675));
    expect(near(p("45° 31.5' N, 122° 40.5' W")), (45.525, -122.675));
    expect(near(p('net control CN85pm')), (45.5208, -122.7083));
    expect(near(p('cn85pm42')), (45.5104, -122.7125));
    expect(near(p('grid CN85')), (45.5, -123.0));
    expect(p('the AB12 bus').$1, isNull); // a 4-character square needs a cue
    // Not positions.
    expect(p('M3.9 at 11:09 UTC, 5 km away').$1, isNull);
    expect(p('Room 5 Steps north').$1, isNull);
    expect(p('version 1.2.3 build 45').$1, isNull);
  });

  test('search matches every word across the report', () {
    final it = _parse(
      '🔴 CRITICAL\n10-03 11:30\n🧊 @Auburn E Main St\n3-🚗 5-🥾',
    );
    expect(it.matches(const []), isTrue);
    expect(it.matches(['auburn']), isTrue);
    expect(it.matches(['main', 'critical']), isTrue);
    expect(it.matches(['icebot']), isTrue); // the sender
    expect(it.matches(['#icewatch']), isTrue); // the channel
    expect(it.matches(['auburn', 'tacoma']), isFalse);
  });
}
