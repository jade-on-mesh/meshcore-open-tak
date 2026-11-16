import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/theme/chat_look.dart';
import 'package:meshcore_open/widgets/message_bubble_frame.dart';

// Reference values from Wadamesh TAK's own nameHue (NameHue.h, the official
// app's hue) / hsvRgb / lookBubbleTintFor / lookNameColorFor (UITask.cpp), so
// a sender has the same colour on a standalone and in the app.
const _cases = [
  ('Alpha-1', 1, 0x421F1F, 0xF22926, 0xFF6966),
  ('Jade ✨', 247, 0x211F42, 0x3D26F2, 0x7866FF),
  ('JDNA', 114, 0x21421F, 0x3BF226, 0x75FF66),
];

int _rgb(Color c) => c.toARGB32() & 0xFFFFFF;

void main() {
  test('Wadamesh colours match the standalone', () {
    for (final (name, hue, tint, night, day) in _cases) {
      expect(wadameshNameHue(name), hue, reason: name);
      expect(_rgb(wadameshBubbleTint(name)), tint, reason: name);
      expect(_rgb(wadameshNameColor(name, dark: true)), night, reason: name);
      expect(_rgb(wadameshNameColor(name, dark: false)), day, reason: name);
    }
  });

  test('chat style ids round-trip, unknown is standard', () {
    for (final s in ChatStyle.values) {
      expect(ChatStyle.fromId(s.id), s);
    }
    expect(ChatStyle.fromId(null), ChatStyle.standard);
    expect(ChatStyle.fromId('nope'), ChatStyle.standard);
  });

  Future<MessageBubbleColors> colorsIn(
    WidgetTester tester,
    ChatStyle style, {
    required bool outgoing,
    bool failed = false,
    Brightness brightness = Brightness.dark,
  }) async {
    late MessageBubbleColors out;
    // A Theme of its own, not MaterialApp's (which animates between themes,
    // so a second pump would still read the last one).
    await tester.pumpWidget(
      Theme(
        data: MeshChatLook(
          style: style,
        ).applyTo(ThemeData(brightness: brightness)),
        child: Builder(
          builder: (context) {
            out = MessageBubbleColors.of(
              context,
              isOutgoing: outgoing,
              isFailed: failed,
              senderName: 'Alpha-1',
            );
            return const SizedBox();
          },
        ),
      ),
    );
    return out;
  }

  testWidgets('Wadamesh style: glass, sender tint and name colour', (
    tester,
  ) async {
    final recv = await colorsIn(tester, ChatStyle.wadamesh, outgoing: false);
    expect(recv.glass, isTrue);
    expect(_rgb(recv.background), 0x421F1F);
    expect(_rgb(recv.name!), 0xF22926);
    final sent = await colorsIn(tester, ChatStyle.wadamesh, outgoing: true);
    expect(sent.background, wadameshSentNight);
    expect(sent.name, isNull);
    final day = await colorsIn(
      tester,
      ChatStyle.wadamesh,
      outgoing: true,
      brightness: Brightness.light,
    );
    expect(day.background, wadameshSentDay);
  });

  // Hues measured from the official MeshCore app's avatars (a public channel,
  // dark mode): the avatar is HSV(hue, 75%, 80%), the name HSV(hue, 75%, 56%).
  test('every style takes its hue from the official app', () {
    for (final n in ['Dupont C2b', 'Thalestr 🐠', 'Jade ✨']) {
      expect(wadameshNameHue(n), classicNameHue(n), reason: n);
    }
    expect(senderNameColor('Chuck@🏠'), classicAvatarColor('Chuck@🏠'));
  });

  test('MeshCore Open Classic keeps the old six-colour palette', () {
    for (final n in ['Dupont C2b', 'BGMatt', 'Jade ✨']) {
      var h = 0;
      for (final c in n.codeUnits) {
        h = (h * 31 + c) & 0x7fffffff;
      }
      expect(openClassicColor(n), openClassicHues[h % 6], reason: n);
      expect(
        senderNameColor(n, style: ChatStyle.openClassic),
        openClassicColor(n),
      );
    }
  });

  testWidgets('MeshCore Open Classic has the standard bubbles', (tester) async {
    for (final out in [true, false]) {
      final a = await colorsIn(tester, ChatStyle.standard, outgoing: out);
      final b = await colorsIn(tester, ChatStyle.openClassic, outgoing: out);
      expect(b.background, a.background);
      expect(b.text, a.text);
      expect(b.name, isNull);
      expect(b.glass, isFalse);
    }
  });

  test('classic colours match the official app', () {
    const hues = {
      'Dupont C2b': 4,
      'BGMatt': 120,
      'Thalestr 🐠': 227,
      'Chuck@🏠': 249,
      'Mark MC 2b ☕': 199,
      'Csmc Mffn 🔑🧠 ACOS T096': 75,
      '🦀': 347,
    };
    for (final e in hues.entries) {
      expect(classicNameHue(e.key), e.value, reason: e.key);
    }
    expect(_rgb(classicAvatarColor('Dupont C2b')), 0xCC3D33);
    expect(_rgb(classicAvatarColor('Chuck@🏠')), 0x4A33CC);
    expect(_rgb(classicNameColor('Thalestr 🐠')), 0x243B8F);
    expect(classicAvatarText('Dupont C2b'), 'DC');
    expect(classicAvatarText('BGMatt'), 'B');
    expect(classicAvatarText('Chuck@🏠'), '🏠');
    expect(classicAvatarText('Mark MC 2b ☕'), '☕');
  });

  testWidgets('classic style: grey theirs in both modes, coloured names', (
    tester,
  ) async {
    final sent = await colorsIn(tester, ChatStyle.classic, outgoing: true);
    expect(sent.background, classicSent);
    expect(sent.text, Colors.white);
    for (final b in Brightness.values) {
      final recv = await colorsIn(
        tester,
        ChatStyle.classic,
        outgoing: false,
        brightness: b,
      );
      expect(recv.background, classicRecv);
      expect(recv.text, classicRecvInk);
      expect(recv.name, classicNameColor('Alpha-1'));
      expect(recv.glass, isFalse);
    }
    expect(
      messageBubbleRadius(isOutgoing: true, style: ChatStyle.classic),
      messageBubbleRadius(isOutgoing: false, style: ChatStyle.classic),
    );
  });

  testWidgets('a failed send stays an error bubble in every style', (
    tester,
  ) async {
    for (final style in ChatStyle.values) {
      final c = await colorsIn(tester, style, outgoing: true, failed: true);
      expect(c.glass, isFalse, reason: style.id);
      expect(c.name, isNull, reason: style.id);
    }
  });
}
