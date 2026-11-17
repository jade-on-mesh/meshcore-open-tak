// MeshCore Open TAK - how chats look (Settings > Appearance > Chat style):
// the app's own bubbles, Wadamesh TAK's colours, or the classic MeshCore
// look, and brighter chat icons. Carried as a theme extension so every bubble
// and avatar follows the setting without being told.

import 'dart:convert';

import 'package:flutter/material.dart';

import 'mesh_theme.dart' show MeshPalette;

/// The chat bubble styles to choose from.
enum ChatStyle {
  /// The app's own: dusk-blue bubbles of mine, theme surfaces for others.
  standard('standard'),

  /// As on a Wadamesh TAK standalone: dark teal bubbles of mine, and each
  /// sender's bubbles and name in their own colour (the same colour the
  /// standalone gives them).
  wadamesh('wadamesh'),

  /// The classic MeshCore app look: blue bubbles of mine, grey for others,
  /// rounded the same on every corner.
  classic('classic'),

  /// MeshCore Open as it was: the app's own bubbles, and people's colours
  /// from its six-colour palette rather than the official app's.
  openClassic('open_classic'),

  /// Like the Signal app: Signal-blue bubbles of mine, plain grey for others,
  /// round corners and no borders, names in colour, pastel avatars.
  signal('signal'),

  /// Like iMessage on an iPhone: blue bubbles of mine, light grey (dark grey
  /// at night) for others, grey names, grey initials avatars.
  iphone('iphone'),

  /// Like Google Messages on Android (Material You): soft blue bubbles of
  /// mine, grey for others, names and avatars in their colour.
  android('android'),

  /// Like mIRC: no bubbles, every line on the left as `<nick> message`,
  /// mine too, in a monospace font, nicks in mIRC's colours.
  mirc('mirc'),

  /// Like ICQ's classic message window: no bubbles, each message under a
  /// `Name (time):` line, mine in red and theirs in blue.
  icq('icq'),

  /// Like Discord: no bubbles, an avatar on the left of each message with
  /// the name in colour above the text.
  discord('discord');

  const ChatStyle(this.id);

  /// What the setting stores.
  final String id;

  static ChatStyle fromId(String? id) {
    for (final s in values) {
      if (s.id == id) return s;
    }
    return standard;
  }
}

/// The chat look in force, read by bubbles and avatars.
@immutable
class MeshChatLook extends ThemeExtension<MeshChatLook> {
  final ChatStyle style;

  /// Avatars filled with their colour, with the initials or icon in black or
  /// white on it, in place of a faint tint.
  final bool brightIcons;

  const MeshChatLook({
    this.style = ChatStyle.standard,
    this.brightIcons = false,
  });

  static const standard = MeshChatLook();

  /// A flat chat log (mIRC, ICQ, Discord): every line on the left, no
  /// bubbles, each message's sender named, mine too.
  bool get isLog =>
      style == ChatStyle.mirc ||
      style == ChatStyle.icq ||
      style == ChatStyle.discord;

  /// A log with avatars beside each message (Discord).
  bool get logAvatars => style == ChatStyle.discord;

  /// A log in a monospace font (mIRC).
  bool get logMono => style == ChatStyle.mirc;

  /// Messages from one sender in a row drawn as one run (Signal, Discord):
  /// the name (and Discord's avatar) on the first, Signal's avatar and time
  /// on the last, and the bubbles close together.
  bool get groupsRuns =>
      style == ChatStyle.signal || style == ChatStyle.discord;

  /// Whether a message received at [newer] continues the run of one from the
  /// same sender received at [older]: the same day and within Discord's 7
  /// minutes (Signal's 3).
  bool continuesRun(DateTime older, DateTime newer) {
    if (!groupsRuns) return false;
    final a = older.toLocal();
    final b = newer.toLocal();
    if (a.year != b.year || a.month != b.month || a.day != b.day) return false;
    final gap = b.difference(a);
    final limit = style == ChatStyle.discord
        ? const Duration(minutes: 7)
        : const Duration(minutes: 3);
    return !gap.isNegative && gap <= limit;
  }

  /// How a log names a message's sender: `<nick>` (mIRC), `Name (time):`
  /// (ICQ), or just the name (Discord). [time] is the message's, formatted.
  String logNick(String name, {String? time}) => switch (style) {
    ChatStyle.mirc => '<$name>',
    ChatStyle.icq => time == null ? '$name:' : '$name ($time):',
    _ => name,
  };

  static MeshChatLook of(BuildContext context) =>
      Theme.of(context).extension<MeshChatLook>() ?? standard;

  /// [theme] with this look added to its extensions.
  ThemeData applyTo(ThemeData theme) => theme.copyWith(
    extensions: [
      for (final e in theme.extensions.values)
        if (e is! MeshChatLook) e,
      this,
    ],
  );

  @override
  MeshChatLook copyWith({ChatStyle? style, bool? brightIcons}) => MeshChatLook(
    style: style ?? this.style,
    brightIcons: brightIcons ?? this.brightIcons,
  );

  @override
  MeshChatLook lerp(MeshChatLook? other, double t) =>
      t < 0.5 ? this : (other ?? this);
}

/// Where a message sits in a run from one sender ([MeshChatLook.groupsRuns]).
@immutable
class ChatRun {
  /// It continues the older message's run (nothing between them).
  final bool joinsAbove;

  /// The newer message continues this one's run.
  final bool joinsBelow;

  const ChatRun({this.joinsAbove = false, this.joinsBelow = false});

  static const solo = ChatRun();
}

// ---- Wadamesh TAK's colours -------------------------------------------------
// The same arithmetic as Wadamesh TAK's UITask.cpp (nameHue, hsvRgb,
// lookBubbleTintFor, lookNameColorFor), so a teammate's bubbles and name have
// the same colour on a standalone and in the app. The hue is the official
// MeshCore app's, everywhere.

/// A person's hue, 0-359: the official MeshCore app's ([classicNameHue]),
/// which Wadamesh TAK's nameHue (NameHue.h) uses too.
int wadameshNameHue(String name) => classicNameHue(name);

/// Wadamesh's integer HSV to RGB (hue 0-359, saturation and value 0-100).
Color wadameshHsv(int h, int s, int v) {
  h = ((h % 360) + 360) % 360;
  final c = v * s ~/ 100;
  final x = c * (60 - ((h % 120) - 60).abs()) ~/ 60;
  final m = v - c;
  var r = 0, g = 0, b = 0;
  if (h < 60) {
    r = c;
    g = x;
  } else if (h < 120) {
    r = x;
    g = c;
  } else if (h < 180) {
    g = c;
    b = x;
  } else if (h < 240) {
    g = x;
    b = c;
  } else if (h < 300) {
    r = x;
    b = c;
  } else {
    r = c;
    b = x;
  }
  int u8(int p) => (p * 255 + 50) ~/ 100;
  return Color.fromARGB(255, u8(r + m), u8(g + m), u8(b + m));
}

/// A sender's bubble on a standalone with colourful bubbles on.
Color wadameshBubbleTint(String name) =>
    wadameshHsv(wadameshNameHue(name), 55, 26);

/// A sender's name on a standalone: vivid at night, softer by day (Day's
/// bubbles are dark slate too, so the name stays light).
Color wadameshNameColor(String name, {required bool dark}) {
  final h = wadameshNameHue(name);
  return dark ? wadameshHsv(h, 85, 95) : wadameshHsv(h, 60, 100);
}

/// Wadamesh TAK's own bubble colours: Night's dark teal, Day's slate.
const Color wadameshSentNight = Color(0xFF0E3A35);
const Color wadameshSentDay = Color(0xFF28556B);
const Color wadameshRecvDay = Color(0xFF3C4852);
const Color wadameshRecvNight = Color(0xFF0F1417);
const Color wadameshBubbleInk = Color(0xFFE6EBED);
const Color wadameshBubbleMeta = Color(0xFF9AA6AC);

// ---- the classic MeshCore look ----------------------------------------------
// Measured from the official MeshCore app: each person's colour comes from
// their name (FNV-1a over its UTF-16 code units, mod 360, as a hue); their
// avatar is that hue filled (75% saturation, 80% brightness) with white
// initials or the name's first emoji on it, and their name is the same hue
// darker (56%). Received bubbles are light grey with black text, in dark mode
// too, and every corner is rounded the same.

/// The official app's hue for [name], 0-359.
int classicNameHue(String name) {
  var h = 2166136261;
  for (final c in name.codeUnits) {
    h ^= c;
    // h * 16777619 mod 2^32 without a product past 2^53 (the web build).
    h = ((((h & 0xFF) << 24) & 0xFFFFFFFF) + h * 403) & 0xFFFFFFFF;
  }
  return h % 360;
}

/// A person's avatar colour in the official app.
Color classicAvatarColor(String name) =>
    HSVColor.fromAHSV(1, classicNameHue(name).toDouble(), 0.75, 0.80).toColor();

/// A person's name colour above their message in the official app.
Color classicNameColor(String name) =>
    HSVColor.fromAHSV(1, classicNameHue(name).toDouble(), 0.75, 0.56).toColor();

/// What the official app puts on an avatar: the name's first emoji, else the
/// first letters of its first two words (one letter for a one-word name).
String classicAvatarText(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return '?';
  for (final ch in trimmed.characters) {
    final r = ch.runes.first;
    if (r >= 0x2190 && !(r >= 0x3000 && r <= 0x9FFF)) return ch;
  }
  final words = trimmed.split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
  final out = words.take(2).map((w) => w.characters.first).join();
  return out.toUpperCase();
}

const Color classicSent = Color(0xFF2196F3);
const Color classicRecv = Color(0xFFE0E0E0);
const Color classicRecvInk = Color(0xFF000000);
const double classicRadius = 20;

// ---- MeshCore Open Classic ----------------------------------------------------
// The six colours people's avatars and names were drawn from before the app
// took the official app's colours, picked by the name's 31-hash.

const List<Color> openClassicHues = [
  MeshPalette.blue,
  MeshPalette.magenta,
  MeshPalette.signal,
  MeshPalette.warn,
  Color(0xFF8FA8F0),
  Color(0xFF6FD9CE),
];

/// A person's colour in MeshCore Open Classic.
Color openClassicColor(String name) {
  var h = 0;
  for (final c in name.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return openClassicHues[h % openClassicHues.length];
}

// ---- Signal ---------------------------------------------------------------------
// After the Signal app's chat: my bubbles its Ultramarine blue with white text,
// others' plain grey (light grey by day, dark grey at night) with no border,
// every corner rounded the same, a sender's name in their colour, and avatars a
// pastel circle with the initials in a deeper shade of the same colour. The
// hue is the official MeshCore app's ([classicNameHue]), so a person keeps
// their colour across styles.

const Color signalSent = Color(0xFF2C6BED);
const Color signalSentInk = Color(0xFFFFFFFF);
const Color signalRecvDay = Color(0xFFE9E9E9);
const Color signalRecvNight = Color(0xFF3B3B3B);
const Color signalInkDay = Color(0xFF1B1B1D);
const Color signalInkNight = Color(0xFFE9E9E9);
const double signalRadius = 18;

/// A bubble corner where it joins the next one in a run, on the sender's side.
const double signalJoinRadius = 5;

/// A sender's name above their message: deep by day, light at night.
Color signalNameColor(String name, {required bool dark}) {
  final h = classicNameHue(name).toDouble();
  return dark
      ? HSVColor.fromAHSV(1, h, 0.45, 0.95).toColor()
      : HSVColor.fromAHSV(1, h, 0.80, 0.55).toColor();
}

/// A person's avatar: a pastel circle ...
Color signalAvatarColor(String name) =>
    HSVColor.fromAHSV(1, classicNameHue(name).toDouble(), 0.22, 0.96).toColor();

/// ... with the initials in a deeper shade of the same colour.
Color signalAvatarInk(String name) =>
    HSVColor.fromAHSV(1, classicNameHue(name).toDouble(), 0.85, 0.55).toColor();

// ---- iPhone (iMessage) -------------------------------------------------------
// Blue bubbles of mine (iOS system blue, a touch brighter at night), others'
// light grey by day and dark grey at night, every corner 18, a sender's name
// small and grey above, and avatars grey circles with white initials as in
// Contacts.

const Color iphoneSentDay = Color(0xFF007AFF);
const Color iphoneSentNight = Color(0xFF0A84FF);
const Color iphoneRecvDay = Color(0xFFE9E9EB);
const Color iphoneRecvNight = Color(0xFF262629);
const Color iphoneName = Color(0xFF8E8E93);
const Color iphoneAvatarDay = Color(0xFFA0A6B1);
const Color iphoneAvatarNight = Color(0xFF6C6C70);
const double iphoneRadius = 18;

// ---- Android (Google Messages, Material You) -----------------------------------
// Mine soft blue with dark blue ink by day (deep blue with light ink at
// night), others' grey, every corner 20, a sender's name and avatar in their
// colour with a white initial.

const Color androidSentDay = Color(0xFFD3E3FD);
const Color androidSentInkDay = Color(0xFF041E49);
const Color androidSentNight = Color(0xFF004A77);
const Color androidSentInkNight = Color(0xFFC2E7FF);
const Color androidRecvDay = Color(0xFFE9EEF6);
const Color androidRecvInkDay = Color(0xFF1F1F1F);
const Color androidRecvNight = Color(0xFF2A2A2D);
const Color androidRecvInkNight = Color(0xFFE3E3E3);
const double androidRadius = 20;

/// A sender's name in the Android style.
Color androidNameColor(String name, {required bool dark}) {
  final h = classicNameHue(name).toDouble();
  return dark
      ? HSVColor.fromAHSV(1, h, 0.40, 0.92).toColor()
      : HSVColor.fromAHSV(1, h, 0.65, 0.62).toColor();
}

/// A person's avatar in the Android style: their colour, a white initial.
Color androidAvatarColor(String name) =>
    HSVColor.fromAHSV(1, classicNameHue(name).toDouble(), 0.55, 0.75).toColor();

// ---- mIRC ------------------------------------------------------------------------
// A chat log, not bubbles: `<nick> message` lines on the left, a monospace
// font, and each nick in one of mIRC's colours (its 16, less white, black and
// the greys, which wouldn't read), picked by the official app's hue so a
// person keeps it.

const List<Color> mircNickColors = [
  Color(0xFF00007F), // 2 navy
  Color(0xFF009300), // 3 green
  Color(0xFFFF0000), // 4 red
  Color(0xFF7F0000), // 5 brown
  Color(0xFF9C009C), // 6 purple
  Color(0xFFFC7F00), // 7 orange
  Color(0xFFFFFF00), // 8 yellow
  Color(0xFF00FC00), // 9 light green
  Color(0xFF009393), // 10 teal
  Color(0xFF00FFFF), // 11 cyan
  Color(0xFF0000FC), // 12 blue
  Color(0xFFFF00FF), // 13 pink
];

/// A nick's mIRC colour. At night the dark ones (navy, brown, blue) are
/// lifted so they read on a dark background; by day the light ones (yellow,
/// light green, cyan) are deepened.
Color mircNickColor(String name, {required bool dark}) {
  final c = mircNickColors[classicNameHue(name) % mircNickColors.length];
  final hsv = HSVColor.fromColor(c);
  if (dark && hsv.value < 0.7)
    return hsv.withValue(0.95).withSaturation(0.6).toColor();
  if (!dark && hsv.value > 0.9 && hsv.hue >= 55 && hsv.hue <= 185) {
    return hsv.withValue(0.6).toColor();
  }
  return c;
}

const Color mircInkDay = Color(0xFF000000);
const Color mircInkNight = Color(0xFFE0E0E0);

// ---- ICQ -----------------------------------------------------------------------
// The classic ICQ message window: no bubbles, each message under its sender's
// `Name (time):` line, mine in red and the other person's in blue, plain text.

const Color icqMineDay = Color(0xFFCC0000);
const Color icqMineNight = Color(0xFFFF6B6B);
const Color icqTheirsDay = Color(0xFF0000CC);
const Color icqTheirsNight = Color(0xFF7FA8FF);
const Color icqInkDay = Color(0xFF000000);
const Color icqInkNight = Color(0xFFE0E0E0);

// ---- Discord -------------------------------------------------------------------
// As in the Discord app: no bubbles, a run of messages under one 40 px avatar
// and one header line, the name in bold (white at night, near-black by day, as
// with no role colour) and the time beside it in grey. Default avatars are one
// of Discord's own colours with a white initial.

const Color discordInkDay = Color(0xFF313338);
const Color discordInkNight = Color(0xFFDBDEE1);
const Color discordMetaDay = Color(0xFF5C5E66);
const Color discordMetaNight = Color(0xFF949BA4);

/// Discord's default avatar colours: blurple, grey, green, yellow, red, pink.
const List<Color> discordAvatarColors = [
  Color(0xFF5865F2),
  Color(0xFF757E8A),
  Color(0xFF3BA55C),
  Color(0xFFFAA61A),
  Color(0xFFED4245),
  Color(0xFFEB459F),
];

/// A person's default avatar colour, picked by their hue so it stays theirs.
Color discordAvatarColor(String name) =>
    discordAvatarColors[classicNameHue(name) % discordAvatarColors.length];

/// A name in a message's header: Discord's header text, as for someone with
/// no role colour.
Color discordNameColor({required bool dark}) =>
    dark ? const Color(0xFFF2F3F5) : const Color(0xFF060607);

const double discordAvatarSize = 40;
const double discordAvatarGap = 12;
const double discordBodySize = 15;
