import 'package:flutter/painting.dart';
import '../models/otp_theme.dart';

/// Ports OTP_3_RC1.lua's `darken_color`: scales r/g/b down by [factor]
/// (every palette color is already fully opaque, so alpha is untouched),
/// floor-rounded per channel exactly like the Lua integer math.
Color otpDarken(Color color, double factor) {
  final argb = color.toARGB32();
  int scale(int shift) {
    final c = (((argb >> shift) & 0xFF) * factor).floor();
    if (c < 0) return 0;
    if (c > 255) return 255;
    return c;
  }

  return Color(0xFF000000 | (scale(16) << 16) | (scale(8) << 8) | scale(0));
}

double _contrastRatio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

/// Bubble text color: near-white if it reads clearly (WCAG ratio >= 4.5)
/// against [color]; otherwise a deep shade of the bubble's own hue, and
/// plain near-black only if even that is too close.
Color otpContrastOf(Color color) {
  const light = Color(0xFFF5F5F5);
  if (_contrastRatio(color, light) >= 4.5) return light;
  final shade = otpDarken(color, 0.2);
  if (_contrastRatio(color, shade) >= 4.5) return shade;
  return const Color(0xFF14171C);
}

/// Ports OTP_3_RC1.lua's `color_for_sender`: assigns each distinct sender
/// name a round-robin palette bucket the first time it's seen, remembers
/// it thereafter, and evicts the oldest once more than [maxTracked]
/// senders are tracked (same 200-sender cap as Lua's `SENDER_COLORS_MAX`).
/// One global instance, matching Lua's single app-wide table - not scoped
/// per chat, so the same sender keeps the same color everywhere.
class OtpSenderColors {
  OtpSenderColors._();
  static final OtpSenderColors instance = OtpSenderColors._();

  static const int maxTracked = 200;
  final Map<String, int> _bucketBySender = {};
  final List<String> _order = [];
  int _nextBucket = 0;

  Color colorFor(String who, OtpTheme theme) {
    final fields = theme.senderColorFields;
    var bucket = _bucketBySender[who];
    if (bucket == null) {
      bucket = _nextBucket % fields.length;
      _nextBucket = bucket + 1;
      _bucketBySender[who] = bucket;
      _order.add(who);
      if (_order.length > maxTracked) {
        final oldest = _order.removeAt(0);
        _bucketBySender.remove(oldest);
      }
    }
    return fields[bucket % fields.length];
  }

  /// Test/debug only - how many distinct senders are currently tracked.
  int get trackedCount => _order.length;
}

/// Bubble fill is the theme's own palette color, unmodified (an in-flight
/// send is blended 40% toward the theme background so it reads as pending).
/// The outline is the same color lightened toward white so the edge shows.
/// Lua darkens every fill to ~35% for its small LCD; on a phone that turned
/// every theme into muddy near-black versions of its palette.
Color _otpFill(OtpTheme theme, Color base, {bool dim = false}) =>
    dim ? Color.lerp(theme.bg, base, 0.6)! : base;

Color _otpEdge(Color base) => Color.lerp(base, const Color(0xFFFFFFFF), 0.35)!;

Color _otpText(Color fill, int textMode) => textMode == 1
    ? const Color(0xFFFFFFFF)
    : textMode == 2
    ? const Color(0xFF000000)
    : otpContrastOf(fill);

/// The three colors one bubble needs, resolved for a single message's
/// state - mirrors `refresh_chat_view`'s per-bubble `outline_color`/
/// `fill_color`/`text_color` math in OTP_3_RC1.lua exactly, including the
/// 0.32-vs-0.35 darken factor for a still-in-flight send.
class OtpBubbleColors {
  final Color outline;
  final Color fill;
  final Color text;
  const OtpBubbleColors({
    required this.outline,
    required this.fill,
    required this.text,
  });
}

/// For a message THIS device sent. Exactly one of [failed]/[delivered]/
/// [waiting]/[retrying] should be true at once (checked in that priority
/// order, matching Lua's `kind` being a single state) - [pending] only
/// changes the darken factor, matching Lua's `(kind == "pending" or kind
/// == "retrying") and 0.32 or 0.35`.
OtpBubbleColors otpOutgoingBubbleColors({
  required OtpTheme theme,
  bool failed = false,
  bool delivered = false,
  bool waiting = false,
  bool retrying = false,
  bool pending = false,
  int textMode = 0,
}) {
  final Color outline;
  if (failed) {
    outline = theme.encrypt;
  } else if (delivered) {
    outline = theme.resultOk;
  } else if (retrying) {
    outline = theme.keyphrase;
  } else if (waiting) {
    outline = theme.ready;
  } else {
    outline = theme.channel; // sent or plain pending
  }
  final fill = _otpFill(theme, outline, dim: pending || retrying);
  return OtpBubbleColors(
    outline: _otpEdge(outline),
    fill: fill,
    text: _otpText(fill, textMode),
  );
}

/// For a message from someone else - colored by sender, round-robin, same
/// as Lua. [failed] is for a message that came through corrupted/
/// undecodable (Lua's "warn" bubble can be centered garbage from a peer,
/// not just a lost outgoing send); otherwise every received message gets
/// [senderName]'s assigned color.
OtpBubbleColors otpReceivedBubbleColors({
  required OtpTheme theme,
  required String senderName,
  bool failed = false,
  int textMode = 0,
}) {
  final outline = failed
      ? theme.encrypt
      : OtpSenderColors.instance.colorFor(senderName, theme);
  final fill = _otpFill(theme, outline);
  return OtpBubbleColors(
    outline: _otpEdge(outline),
    fill: fill,
    text: _otpText(fill, textMode),
  );
}
