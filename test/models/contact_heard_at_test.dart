import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/models/contact.dart';

Contact _node({
  required DateTime advertClock,
  DateTime? radioHeard,
  DateTime? phoneHeard,
}) => Contact(
  publicKey: Uint8List.fromList([1, 2, 3, 4]),
  name: 'Node',
  type: advTypeRepeater,
  pathLength: 0,
  path: Uint8List(0),
  lastSeen: advertClock,
  lastModified: radioHeard,
  heardAt: phoneHeard,
);

void main() {
  final now = DateTime.now();

  test('a node clock a day ahead no longer reads as heard now', () {
    final c = _node(
      advertClock: now.add(const Duration(days: 1)),
      radioHeard: now.subtract(const Duration(hours: 2)),
    );
    expect(c.lastHeard, now.subtract(const Duration(hours: 2)));
  });

  test('the later of the phone and radio heard times wins', () {
    final phone = now.subtract(const Duration(minutes: 1));
    final radio = now.subtract(const Duration(minutes: 30));
    expect(
      _node(advertClock: radio, radioHeard: radio, phoneHeard: phone).lastHeard,
      phone,
    );
    // Heard by the radio while the phone was away.
    expect(
      _node(advertClock: radio, radioHeard: phone, phoneHeard: radio).lastHeard,
      phone,
    );
  });

  test('only the node clock: used, but never later than now', () {
    final past = now.subtract(const Duration(days: 3));
    expect(_node(advertClock: past).lastHeard, past);
    final ahead = _node(advertClock: now.add(const Duration(days: 9)));
    expect(ahead.lastHeard, Contact.heardNever);
  });

  test('a clock set ahead is passed over, not taken as heard now', () {
    // The radio's clock ahead, no phone time yet: not "recently".
    final ahead = _node(
      advertClock: now.add(const Duration(days: 2)),
      radioHeard: now.add(const Duration(hours: 3)),
    );
    expect(ahead.lastHeard, Contact.heardNever);
    // So one whose advert just came in sorts above it.
    final fresh = _node(
      advertClock: now.add(const Duration(days: 2)),
      radioHeard: now.add(const Duration(hours: 3)),
      phoneHeard: now.subtract(const Duration(seconds: 5)),
    );
    final list = [ahead, fresh]
      ..sort((a, b) => b.lastHeard.compareTo(a.lastHeard));
    expect(identical(list.first, fresh), isTrue);
  });

  test('sorted by heard time, the most recently heard comes first', () {
    final nodes = [
      _node(
        advertClock: now.add(const Duration(days: 1)),
        radioHeard: now.subtract(const Duration(hours: 5)),
      ),
      _node(
        advertClock: now.subtract(const Duration(days: 2)),
        phoneHeard: now.subtract(const Duration(seconds: 10)),
      ),
    ]..sort((a, b) => b.lastHeard.compareTo(a.lastHeard));
    expect(nodes.first.heardAt, isNotNull);
  });
}
