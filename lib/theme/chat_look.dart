// MeshCore Open TAK - how chats look (Settings > Appearance > Chat style):
// the app's own bubbles, Wadamesh TAK's colours, or the classic MeshCore
// look, and brighter chat icons. Carried as a theme extension so every bubble
// and avatar follows the setting without being told.

import 'dart:convert';

import 'package:flutter/material.dart';

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
  classic('classic');

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

  const MeshChatLook({this.style = ChatStyle.standard, this.brightIcons = false});

  static const standard = MeshChatLook();

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

// ---- Wadamesh TAK's colours -------------------------------------------------
// The same arithmetic as Wadamesh TAK's UITask.cpp (nameHue, hsvRgb,
// lookBubbleTintFor, lookNameColorFor), so a teammate's bubbles and name have
// the same colour on a standalone and in the app.

/// FNV-1a of the name's UTF-8 bytes, as a hue 0-359 (Wadamesh's nameHue).
int wadameshNameHue(String name) {
  var h = 2166136261;
  for (final b in utf8.encode(name)) {
    h ^= b;
    // h * 16777619 (2^24 + 403) mod 2^32, without a product past 2^53, which
    // the web build can't hold exactly.
    h = ((((h & 0xFF) << 24) & 0xFFFFFFFF) + h * 403) & 0xFFFFFFFF;
  }
  return h % 360;
}

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

const Color classicSent = Color(0xFF2196F3);
const Color classicRecvLight = Color(0xFFE9E9EB);
const Color classicRecvDark = Color(0xFF3A3A3C);
