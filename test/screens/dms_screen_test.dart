import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/models/contact.dart';
import 'package:meshcore_open/models/message.dart';
import 'package:meshcore_open/screens/dms_screen.dart';

Contact _contact(int i, {int type = advTypeChat, String? name}) => Contact(
  publicKey: Uint8List.fromList(List<int>.generate(32, (j) => (i + j) & 0xff)),
  name: name ?? 'Person $i',
  type: type,
  pathLength: -1,
  path: Uint8List(0),
  lastSeen: DateTime(2026, 11, 1),
);

Message _msg(Contact c, DateTime at, {bool outgoing = false}) => Message(
  senderKey: c.publicKey,
  text: 'hi',
  timestamp: at,
  receivedAt: at,
  isOutgoing: outgoing,
);

void main() {
  final t0 = DateTime(2026, 11, 24, 5);

  test('unread conversations come first, each group newest first', () {
    final a = _contact(1), b = _contact(2), c = _contact(3), d = _contact(4);
    final groups = groupDmConversations([
      DmConversation(contact: a, unread: 0, last: _msg(a, t0)),
      DmConversation(
        contact: b,
        unread: 2,
        last: _msg(b, t0.subtract(const Duration(hours: 3))),
      ),
      DmConversation(
        contact: c,
        unread: 0,
        last: _msg(c, t0.subtract(const Duration(days: 1))),
      ),
      DmConversation(
        contact: d,
        unread: 1,
        last: _msg(d, t0.subtract(const Duration(minutes: 5))),
      ),
    ]);
    expect(groups.unread.map((x) => x.contact), [d, b]);
    expect(groups.read.map((x) => x.contact), [a, c]);
  });

  test('people only, and only people with a conversation', () {
    final person = _contact(1);
    final quiet = _contact(2);
    final room = _contact(3, type: advTypeRoom);
    final repeater = _contact(4, type: advTypeRepeater);
    final groups = groupDmConversations([
      DmConversation(contact: person, unread: 0, last: _msg(person, t0)),
      DmConversation(contact: quiet, unread: 0),
      DmConversation(contact: room, unread: 3, last: _msg(room, t0)),
      DmConversation(contact: repeater, unread: 0, last: _msg(repeater, t0)),
    ]);
    expect(groups.unread, isEmpty);
    expect(groups.read.map((x) => x.contact), [person]);
  });

  test('an unread count with no loaded message still lists the person', () {
    final p = _contact(1);
    final groups = groupDmConversations([
      DmConversation(contact: p, unread: 2),
    ]);
    expect(groups.unread.map((x) => x.contact), [p]);
  });

  test('search narrows by name, ignoring case', () {
    final jeph = _contact(1, name: 'Jeph Machine');
    final mesh = _contact(2, name: 'MeshOMatic');
    final groups = groupDmConversations([
      DmConversation(contact: jeph, unread: 1, last: _msg(jeph, t0)),
      DmConversation(contact: mesh, unread: 0, last: _msg(mesh, t0)),
    ], query: '  jeph ');
    expect(groups.unread.map((x) => x.contact), [jeph]);
    expect(groups.read, isEmpty);
  });
}
