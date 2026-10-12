import 'package:flutter/painting.dart';

/// One named color palette for OTP-active chats, ported byte-for-byte from
/// OTP_3_RC1.lua's `THEME_DATA` table (see `PALETTE_FIELDS`/`apply_theme`)
/// so the same named themes look the same on both platforms. There is
/// exactly one global theme choice for the whole app, same as Lua - no
/// per-contact/channel override - stored as `AppSettings.otpThemeIndex`
/// and picked from the OTP Pad screen.
///
/// Field names match Lua's semantic roles, not literal meanings - e.g.
/// [channel] colors a sent/pending bubble, not "channel chat" specifically;
/// [resultOk] colors a delivered (acked) bubble; [encrypt] colors a failed/
/// lost one. See `otp_bubble_colors.dart` for how these map onto an actual
/// message's state.
class OtpTheme {
  final String name;
  final Color encrypt;
  final Color decrypt;
  final Color ciphertext;
  final Color plaintext;
  final Color newpad;
  final Color channel;
  final Color resultOk;
  final Color keyphrase;
  final Color padinfo;
  final Color ready;
  final Color bg;

  const OtpTheme({
    required this.name,
    required this.encrypt,
    required this.decrypt,
    required this.ciphertext,
    required this.plaintext,
    required this.newpad,
    required this.channel,
    required this.resultOk,
    required this.keyphrase,
    required this.padinfo,
    required this.ready,
    required this.bg,
  });

  /// Round-robin bucket order for [OtpSenderColors] - a received message's
  /// bubble color is picked from this list by sender, matching Lua's
  /// `SENDER_COLOR_FIELDS = { "decrypt", "ciphertext", "newpad",
  /// "keyphrase", "result_ok" }`. Keep this order in sync with that list,
  /// not with [all]'s field order above (`channel`, `encrypt`, `padinfo`
  /// and [bg] are deliberately excluded - Lua reserves those for sent/
  /// failed bubbles, the chat background tint, and captions respectively,
  /// and never hands them out as a sender's bubble color).
  List<Color> get senderColorFields => [
    decrypt,
    ciphertext,
    newpad,
    keyphrase,
    resultOk,
  ];

  /// All named themes, in the same order as Lua's `THNAMES`/`THEME_DATA` -
  /// index order matters, since `AppSettings.otpThemeIndex` is a plain
  /// index into this list.
  static const List<OtpTheme> all = [
    OtpTheme(
      name: 'Default',
      encrypt: Color(0xFFFF6B4A),
      decrypt: Color(0xFF2DD4BF),
      ciphertext: Color(0xFFF97316),
      plaintext: Color(0xFF38BDF8),
      newpad: Color(0xFFA78BFA),
      channel: Color(0xFFEC4899),
      resultOk: Color(0xFF4ADE80),
      keyphrase: Color(0xFFFBBF24),
      padinfo: Color(0xFF22D3EE),
      ready: Color(0xFF94A3B8),
      bg: Color(0xFF000000),
    ),
    OtpTheme(
      name: 'Cyberpunk',
      encrypt: Color(0xFFFF1493),
      decrypt: Color(0xFF39FF14),
      ciphertext: Color(0xFFBC13FE),
      plaintext: Color(0xFF00F5FF),
      newpad: Color(0xFFFF00FF),
      channel: Color(0xFFF5FF00),
      resultOk: Color(0xFF39FF14),
      keyphrase: Color(0xFFFFAA00),
      padinfo: Color(0xFF00FFEF),
      ready: Color(0xFF6B7280),
      bg: Color(0xFF000000),
    ),
    OtpTheme(
      name: 'Trans',
      // Repalette (2026-10-04): the original pastel set (F9A8D4/FF8FAB/
      // FBCFE8 "pinks", BAE6FD/7DD3FC "blues") looked washed out even
      // before darkening, and the 0.32-0.35 darken factor every bubble
      // fill goes through (see otp_bubble_colors.dart/refresh_chat_view)
      // turned them nearly unrecognizable - a muddy maroon-brown instead
      // of pink, near-black instead of blue. Now built from exactly 4
      // colors: light blue, light pink, hot pink, lighter blue - hot pink
      // is reserved for `channel` (the everyday sent-message color) and
      // deliberately excluded from the sender round-robin pool
      // (senderColorFields = decrypt/ciphertext/newpad/keyphrase/
      // resultOk), so a sent bubble's color is never also a received
      // sender's color.
      encrypt: Color(0xFFF5A9B8), // light pink
      decrypt: Color(0xFF5BCEFA), // light blue
      ciphertext: Color(0xFFF5A9B8), // light pink
      plaintext: Color(0xFFFFFFFF),
      newpad: Color(0xFFA6E8FF), // lighter blue
      channel: Color(0xFFFF69B4), // hot pink
      resultOk: Color(0xFF5BCEFA), // light blue
      keyphrase: Color(0xFFF5A9B8), // light pink
      padinfo: Color(0xFF38BDF8),
      ready: Color(0xFFE5E7EB),
      bg: Color(0xFF000000),
    ),
    OtpTheme(
      name: 'Cascadia',
      // Repalette (2026-10-04, full 9-theme audit prompted by the Trans
      // fix above): the original set put 3 of the 5 sender-pool colors
      // within 13 degrees of each other in hue (all blue) and gave
      // `ciphertext` the exact same hue as `channel` (both forest green,
      // only saturation/lightness differed) - after the 0.35 darken step,
      // several received senders and even a received-vs-sent bubble could
      // read as the same color. Rebuilt around 5 clearly separated PNW
      // hues - glacier blue, mountain-dusk purple, sunset amber,
      // white, moss green - verified by hue distance, not by
      // eye, so it's not guesswork.
      encrypt: Color(0xFF60A5FA), // sky blue (unchanged)
      decrypt: Color(0xFF38BDF8), // glacier blue
      ciphertext: Color(0xFFA78BFA), // mountain-dusk purple
      plaintext: Color(0xFFFFFFFF),
      newpad: Color(0xFFFBBF24), // sunset amber
      channel: Color(0xFF15803D), // forest green (unchanged - "mine")
      resultOk: Color(0xFF84CC16), // moss/lime green - distinct shade from channel
      keyphrase: Color(0xFFFFFFFF), // white (replaces huckleberry pink)
      padinfo: Color(0xFF22C55E),
      ready: Color(0xFFCBD5E1),
      bg: Color(0xFF000000),
    ),
    OtpTheme(
      name: 'B&W',
      encrypt: Color(0xFFFFFFFF),
      decrypt: Color(0xFFE6E6E6),
      ciphertext: Color(0xFFCCCCCC),
      plaintext: Color(0xFFFFFFFF),
      newpad: Color(0xFFB3B3B3),
      channel: Color(0xFFD9D9D9),
      resultOk: Color(0xFFFFFFFF),
      keyphrase: Color(0xFF999999),
      padinfo: Color(0xFF808080),
      ready: Color(0xFF4D4D4D),
      bg: Color(0xFF000000),
    ),
    OtpTheme(
      name: 'Acid',
      // Repalette (2026-10-04, full theme audit): `ciphertext` (crimson)
      // and `newpad` (tomato) both sat within 12 degrees of `channel`'s
      // pure red - a received sender could land on a near-identical red
      // to your own sent bubble. Moved them to a smoke/ash slate and a
      // midnight steel-blue - a deliberate "fire vs. ash/night" contrast
      // that keeps the theme's intensity while fixing the collision.
      // `decrypt`/`resultOk` (orange/gold, 12 degrees apart) are a minor
      // pre-existing closeness left as-is - tightening it further would
      // mean giving up either color's own identity for a difference
      // nobody flagged, within a theme whose whole palette is deliberately
      // narrow (fire tones).
      encrypt: Color(0xFFFF4500),
      decrypt: Color(0xFFFFA500),
      ciphertext: Color(0xFF2F4F4F), // ash/smoke slate
      plaintext: Color(0xFFFFFFFF),
      newpad: Color(0xFF4682B4), // midnight steel blue
      channel: Color(0xFFFF0000),
      resultOk: Color(0xFFFFD700),
      keyphrase: Color(0xFFFFDAB9),
      padinfo: Color(0xFF8B0000),
      ready: Color(0xFF696969),
      bg: Color(0xFF000000),
    ),
  ];
}
