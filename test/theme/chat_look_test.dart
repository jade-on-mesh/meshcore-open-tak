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

  testWidgets('Signal style: blue for mine, grey for others, names coloured', (
    tester,
  ) async {
    final sent = await colorsIn(tester, ChatStyle.signal, outgoing: true);
    expect(sent.background, signalSent);
    expect(sent.text, signalSentInk);
    expect(sent.name, isNull);
    expect(sent.glass, isFalse);
    final night = await colorsIn(tester, ChatStyle.signal, outgoing: false);
    expect(night.background, signalRecvNight);
    expect(night.text, signalInkNight);
    expect(night.name, signalNameColor('Alpha-1', dark: true));
    final day = await colorsIn(
      tester,
      ChatStyle.signal,
      outgoing: false,
      brightness: Brightness.light,
    );
    expect(day.background, signalRecvDay);
    expect(day.text, signalInkDay);
    // No border: the bubble is one colour.
    expect(day.border, day.background);
    expect(
      messageBubbleRadius(isOutgoing: true, style: ChatStyle.signal),
      BorderRadius.circular(signalRadius),
    );
    // A person keeps their hue: Signal's avatar is a pastel of it.
    expect(
      HSVColor.fromColor(signalAvatarColor('Jade ✨')).hue.round(),
      classicNameHue('Jade ✨'),
    );
  });

  testWidgets('iPhone style: system blue, grey others, grey names', (
    tester,
  ) async {
    final sent = await colorsIn(tester, ChatStyle.iphone, outgoing: true);
    expect(sent.background, iphoneSentNight);
    expect(sent.text, Colors.white);
    final day = await colorsIn(
      tester,
      ChatStyle.iphone,
      outgoing: false,
      brightness: Brightness.light,
    );
    expect(day.background, iphoneRecvDay);
    expect(day.text, Colors.black);
    expect(day.name, iphoneName);
    expect(
      messageBubbleRadius(isOutgoing: false, style: ChatStyle.iphone),
      BorderRadius.circular(iphoneRadius),
    );
  });

  testWidgets('Android style: Material blue, names in colour', (tester) async {
    final day = await colorsIn(
      tester,
      ChatStyle.android,
      outgoing: true,
      brightness: Brightness.light,
    );
    expect(day.background, androidSentDay);
    expect(day.text, androidSentInkDay);
    final recv = await colorsIn(tester, ChatStyle.android, outgoing: false);
    expect(recv.background, androidRecvNight);
    expect(recv.name, androidNameColor('Alpha-1', dark: true));
    expect(
      HSVColor.fromColor(androidAvatarColor('Jade ✨')).hue.round(),
      classicNameHue('Jade ✨'),
    );
  });

  testWidgets('mIRC style: a flat log, every line named, nicks in colour', (
    tester,
  ) async {
    final mine = await colorsIn(tester, ChatStyle.mirc, outgoing: true);
    expect(mine.flat, isTrue);
    expect(mine.background, Colors.transparent);
    // Mine are named too (a log): the colour comes from the name passed.
    expect(mine.name, mircNickColor('Alpha-1', dark: true));
    final recv = await colorsIn(tester, ChatStyle.mirc, outgoing: false);
    expect(recv.flat, isTrue);
    expect(recv.text, mircInkNight);
    expect(const MeshChatLook(style: ChatStyle.mirc).isLog, isTrue);
    expect(const MeshChatLook(style: ChatStyle.iphone).isLog, isFalse);
    // Every nick colour reads: lifted at night, deepened by day.
    for (final n in ['Jade ✨', 'Dupont C2b', 'BGMatt', 'Alpha-1', 'TDeck']) {
      final night = HSVColor.fromColor(mircNickColor(n, dark: true));
      expect(night.value, greaterThanOrEqualTo(0.7), reason: n);
    }
  });

  testWidgets('ICQ style: a log, mine red and theirs blue', (tester) async {
    final mine = await colorsIn(
      tester,
      ChatStyle.icq,
      outgoing: true,
      brightness: Brightness.light,
    );
    expect(mine.flat, isTrue);
    expect(mine.name, icqMineDay);
    final theirs = await colorsIn(
      tester,
      ChatStyle.icq,
      outgoing: false,
      brightness: Brightness.light,
    );
    expect(theirs.name, icqTheirsDay);
    expect(theirs.text, icqInkDay);
    const look = MeshChatLook(style: ChatStyle.icq);
    expect(look.isLog, isTrue);
    expect(look.logAvatars, isFalse);
    expect(look.logMono, isFalse);
    expect(look.logNick('Jade', time: '2:03 PM'), 'Jade (2:03 PM):');
  });

  testWidgets('Discord style: a log with avatars, names in header white', (
    tester,
  ) async {
    final recv = await colorsIn(tester, ChatStyle.discord, outgoing: false);
    expect(recv.flat, isTrue);
    expect(recv.text, discordInkNight);
    expect(recv.name, discordNameColor(dark: true));
    const look = MeshChatLook(style: ChatStyle.discord);
    expect(look.logAvatars, isTrue);
    expect(look.logNick('Jade'), 'Jade');
    expect(const MeshChatLook(style: ChatStyle.mirc).logNick('Jade'), '<Jade>');
    expect(discordAvatarColors, contains(discordAvatarColor('Jade ✨')));
  });

  test('Signal and Discord group runs; others never do', () {
    final t = DateTime(2026, 11, 16, 23, 45);
    const discord = MeshChatLook(style: ChatStyle.discord);
    const signal = MeshChatLook(style: ChatStyle.signal);
    expect(discord.groupsRuns, isTrue);
    expect(signal.groupsRuns, isTrue);
    expect(discord.continuesRun(t, t.add(const Duration(minutes: 6))), isTrue);
    expect(discord.continuesRun(t, t.add(const Duration(minutes: 8))), isFalse);
    expect(signal.continuesRun(t, t.add(const Duration(minutes: 2))), isTrue);
    expect(signal.continuesRun(t, t.add(const Duration(minutes: 4))), isFalse);
    // Not across midnight, nor backwards.
    expect(discord.continuesRun(t, DateTime(2026, 11, 17, 0, 1)), isFalse);
    expect(
      discord.continuesRun(t, t.subtract(const Duration(minutes: 1))),
      isFalse,
    );
    const standard = MeshChatLook();
    expect(standard.groupsRuns, isFalse);
    expect(standard.continuesRun(t, t), isFalse);
  });

  test('iPhone and Android: bubble runs, joined corners, time headers', () {
    final t = DateTime(2026, 11, 17, 9, 0);
    for (final style in [ChatStyle.iphone, ChatStyle.android]) {
      final look = MeshChatLook(style: style);
      expect(look.groupsRuns, isTrue, reason: '$style');
      expect(look.bubbleRuns, isTrue, reason: '$style');
      expect(look.timeHeaders, isTrue, reason: '$style');
      expect(look.continuesRun(t, t.add(const Duration(minutes: 2))), isTrue);
      expect(look.pauseBetween(t, t.add(const Duration(minutes: 59))), isFalse);
      expect(look.pauseBetween(t, t.add(const Duration(hours: 1))), isTrue);
    }
    // iMessage: no avatar in a one-to-one chat and no times under bubbles.
    const ios = MeshChatLook(style: ChatStyle.iphone);
    expect(ios.noOneToOneAvatar, isTrue);
    expect(ios.bubbleTimes, isFalse);
    const android = MeshChatLook(style: ChatStyle.android);
    expect(android.noOneToOneAvatar, isFalse);
    expect(android.bubbleTimes, isTrue);
    // Signal and Discord have no pause headers.
    expect(
      const MeshChatLook(
        style: ChatStyle.signal,
      ).pauseBetween(t, t.add(const Duration(hours: 3))),
      isFalse,
    );
    // A received bubble in the middle of a run: tight on the left only.
    final mid = messageBubbleRadius(
      isOutgoing: false,
      style: ChatStyle.android,
      run: const ChatRun(joinsAbove: true, joinsBelow: true),
    );
    expect(mid.topLeft, const Radius.circular(4));
    expect(mid.bottomLeft, const Radius.circular(4));
    expect(mid.topRight, const Radius.circular(androidRadius));
    // My last bubble of a run: tight at the top right only.
    final last = messageBubbleRadius(
      isOutgoing: true,
      style: ChatStyle.iphone,
      run: const ChatRun(joinsAbove: true),
    );
    expect(last.topRight, const Radius.circular(6));
    expect(last.bottomRight, const Radius.circular(iphoneRadius));
  });

  test('mIRC: 24-hour line times and /me actions', () {
    expect(mircTime(DateTime(2026, 11, 17, 9, 5)), '[09:05]');
    expect(mircTime(DateTime(2026, 11, 17, 23, 45)), '[23:45]');
    expect(mircAction('/me waves'), 'waves');
    expect(mircAction('/me  waves'), 'waves');
    expect(mircAction('hello /me'), isNull);
    expect(mircAction('/meow'), isNull);
  });

  test('App background: only when switched on, only for other apps', () {
    expect(
      const MeshChatLook(style: ChatStyle.discord).background(dark: true),
      isNull,
    );
    const on = MeshChatLook(style: ChatStyle.discord, appBackground: true);
    expect(on.background(dark: true), discordBgNight);
    expect(on.background(dark: false), Colors.white);
    expect(
      on.copyWith(style: ChatStyle.iphone).background(dark: true),
      Colors.black,
    );
    for (final own in [
      ChatStyle.standard,
      ChatStyle.openClassic,
      ChatStyle.wadamesh,
    ]) {
      expect(on.copyWith(style: own).background(dark: true), isNull);
      expect(on.copyWith(style: own).hasAppBackground, isFalse);
    }
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

  testWidgets('MeshCore style: Classic\'s bubbles, the meta line below', (
    tester,
  ) async {
    const look = MeshChatLook(style: ChatStyle.meshcore);
    expect(look.classicBubbles, isTrue);
    expect(look.metaBelow, isTrue);
    expect(const MeshChatLook(style: ChatStyle.classic).metaBelow, isFalse);
    for (final b in Brightness.values) {
      final recv = await colorsIn(
        tester,
        ChatStyle.meshcore,
        outgoing: false,
        brightness: b,
      );
      expect(recv.background, classicRecv);
      expect(recv.name, classicNameColor('Alpha-1'));
    }
    expect(
      messageBubbleRadius(isOutgoing: true, style: ChatStyle.meshcore),
      messageBubbleRadius(isOutgoing: true, style: ChatStyle.classic),
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
