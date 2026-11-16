import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/theme/chat_look.dart';
import 'package:meshcore_open/widgets/message_bubble_frame.dart';

// Reference values from Wadamesh TAK's own nameHue / hsvRgb /
// lookBubbleTintFor / lookNameColorFor (UITask.cpp), so a sender has the same
// colour on a standalone and in the app.
const _cases = [
  ('Alpha-1', 1, 0x421F1F, 0xF22926, 0xFF6966),
  ('Jade ✨', 265, 0x2B1F42, 0x7A26F2, 0xA666FF),
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
    await tester.pumpWidget(
      MaterialApp(
        theme: MeshChatLook(
          style: style,
        ).applyTo(ThemeData(brightness: brightness)),
        home: Builder(
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

  testWidgets('classic style: blue mine, grey theirs', (tester) async {
    final sent = await colorsIn(tester, ChatStyle.classic, outgoing: true);
    expect(sent.background, classicSent);
    expect(sent.text, Colors.white);
    final recv = await colorsIn(
      tester,
      ChatStyle.classic,
      outgoing: false,
      brightness: Brightness.light,
    );
    expect(recv.background, classicRecvLight);
    expect(recv.glass, isFalse);
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
