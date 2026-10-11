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
}
