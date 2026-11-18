// MeshCore Open TAK - a chat screen's header and composer drawn the way the
// chat style's app draws them (Settings > Appearance > Chat style), so the
// whole screen follows the style, not only the bubbles:
//
// - MeshCore Classic: the MeshCore app's slate bar with a round avatar, a
//   big title and "Channel Messages" under it; a pill-shaped field with ⊕
//   and the send arrow inside it and the character count under it.
// - Signal: the bar on the chat's background, avatar and name; a pill field,
//   "+" on the left, Signal's blue round send button.
// - iPhone: a centred avatar with the name small under it; a round grey "+",
//   an outlined field with the blue ↑ inside it.
// - Android (Google Messages): avatar and name on the chat's background; a
//   filled pill field, the send button a tonal circle.
// - Discord: "# name" in bold; a grey "+" circle, a filled field saying
//   "Message #name", the blurple send button.
// - mIRC: a monospace title and a square monospace input line.
// - ICQ: a square field and a "Send" button.
// The app's own styles (MeshCore Open TAK, Wadamesh TAK, MeshCore Open
// Classic) keep the app's header and composer.

import 'package:flutter/material.dart';

import '../theme/chat_look.dart';
import '../theme/mesh_theme.dart';

/// The MeshCore app's header colours (dark), and its channel avatar.
const Color classicHeaderNight = Color(0xFF1F2937);
const Color classicChannelAvatar = Color(0xFF607D8B);
const Color classicFieldNight = Color(0xFF2E3034);
const Color classicFieldDay = Color(0xFFECEFF1);
const Color classicHintNight = Color(0xFFC3C6CF);
const Color classicHintDay = Color(0xFF5F6368);

/// Discord's blurple and its composer greys.
const Color discordBlurple = Color(0xFF5865F2);
const Color discordFieldNight = Color(0xFF2B2D31);
const Color discordFieldDay = Color(0xFFEBEDEF);

/// How the chat style's app draws a chat's header.
@immutable
class ChatHeaderLook {
  /// The bar's colour and ink; null: the theme's.
  final Color? background;
  final Color? foreground;

  /// A round avatar before the title (0: none).
  final double avatar;

  /// iMessage: the avatar centred with the name small under it.
  final bool centered;
  final double? toolbarHeight;
  final TextStyle? title;
  final TextStyle? subtitle;

  /// Discord: "#" before a channel's name, in the bar's grey.
  final bool hashPrefix;

  /// The MeshCore app: "Channel Messages" under a channel's name when there
  /// is nothing else to say there.
  final bool channelSubtitle;

  const ChatHeaderLook({
    this.background,
    this.foreground,
    this.avatar = 0,
    this.centered = false,
    this.toolbarHeight,
    this.title,
    this.subtitle,
    this.hashPrefix = false,
    this.channelSubtitle = false,
  });

  /// The app's own header.
  static const plain = ChatHeaderLook();

  bool get isPlain => identical(this, plain);

  static ChatHeaderLook of(BuildContext context) {
    final look = MeshChatLook.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    // The style's app background, when the chats use it; else the theme's.
    final chatBg = look.background(dark: dark);
    final ink = chatBg == null
        ? null
        : (dark ? Colors.white : const Color(0xFF1B1B1D));
    switch (look.style) {
      case ChatStyle.classic:
        return ChatHeaderLook(
          background: dark ? classicHeaderNight : null,
          foreground: dark ? Colors.white : null,
          avatar: 36,
          toolbarHeight: 64,
          title: const TextStyle(fontSize: 22, fontWeight: FontWeight.w400),
          subtitle: const TextStyle(fontSize: 14),
          channelSubtitle: true,
        );
      case ChatStyle.signal:
        return ChatHeaderLook(
          background: chatBg,
          foreground: ink,
          avatar: 32,
          title: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          subtitle: const TextStyle(fontSize: 12),
        );
      case ChatStyle.iphone:
        return ChatHeaderLook(
          background: chatBg == null
              ? null
              : (dark ? const Color(0xFF1C1C1E) : const Color(0xFFF6F6F6)),
          foreground: ink,
          avatar: 40,
          centered: true,
          toolbarHeight: 82,
          title: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500),
          subtitle: const TextStyle(fontSize: 10),
        );
      case ChatStyle.android:
        return ChatHeaderLook(
          background: chatBg,
          foreground: ink,
          avatar: 36,
          title: const TextStyle(fontSize: 18, fontWeight: FontWeight.w400),
          subtitle: const TextStyle(fontSize: 12),
        );
      case ChatStyle.discord:
        return ChatHeaderLook(
          background: chatBg,
          foreground: ink,
          hashPrefix: true,
          title: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
          subtitle: const TextStyle(fontSize: 12),
        );
      case ChatStyle.mirc:
        return ChatHeaderLook(
          background: chatBg,
          foreground: ink,
          title: MeshTheme.mono(fontSize: 15, fontWeight: FontWeight.w700),
          subtitle: MeshTheme.mono(fontSize: 11),
        );
      case ChatStyle.icq:
        return ChatHeaderLook(
          background: chatBg,
          foreground: ink,
          title: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
          subtitle: const TextStyle(fontSize: 11),
        );
      case ChatStyle.standard:
      case ChatStyle.wadamesh:
      case ChatStyle.openClassic:
        return plain;
    }
  }
}

/// A channel's round avatar in the header: its icon in white on the style's
/// colour.
class ChatChannelAvatar extends StatelessWidget {
  final IconData icon;
  final double size;
  const ChatChannelAvatar({super.key, required this.icon, required this.size});

  @override
  Widget build(BuildContext context) {
    final style = MeshChatLook.of(context).style;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final color = switch (style) {
      ChatStyle.classic => classicChannelAvatar,
      ChatStyle.iphone => dark ? iphoneAvatarNight : iphoneAvatarDay,
      ChatStyle.signal => dark ? signalRecvNight : signalRecvDay,
      ChatStyle.android => dark ? androidSentNight : androidSentDay,
      _ => Theme.of(context).colorScheme.surfaceContainerHighest,
    };
    final ink = switch (style) {
      ChatStyle.signal => dark ? signalInkNight : signalInkDay,
      ChatStyle.android => dark ? androidSentInkNight : androidSentInkDay,
      ChatStyle.classic || ChatStyle.iphone => Colors.white,
      _ => Theme.of(context).colorScheme.onSurfaceVariant,
    };
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      alignment: Alignment.center,
      child: Icon(icon, size: size * 0.55, color: ink),
    );
  }
}

/// A chat header's title in the style's layout: [avatar] (built at the
/// look's size) beside or above [title], with [subtitle] under it.
class ChatHeaderTitle extends StatelessWidget {
  final ChatHeaderLook look;
  final Widget Function(double size)? avatar;
  final String title;
  final Widget? subtitle;

  /// The subtitle's text when [subtitle] is null and the look puts a line
  /// there ("Channel Messages").
  final String? fallbackSubtitle;

  const ChatHeaderTitle({
    super.key,
    required this.look,
    required this.title,
    this.avatar,
    this.subtitle,
    this.fallbackSubtitle,
  });

  @override
  Widget build(BuildContext context) {
    final fg =
        look.foreground ??
        Theme.of(context).appBarTheme.foregroundColor ??
        Theme.of(context).colorScheme.onSurface;
    final titleStyle = (look.title ?? const TextStyle(fontSize: 16)).copyWith(
      color: fg,
    );
    final subStyle = (look.subtitle ?? const TextStyle(fontSize: 12)).copyWith(
      color: fg.withValues(alpha: look.centered ? 0.6 : 0.85),
    );
    final sub =
        subtitle ??
        (fallbackSubtitle == null
            ? null
            : Text(
                fallbackSubtitle!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ));
    final name = Text.rich(
      TextSpan(
        children: [
          if (look.hashPrefix && !title.startsWith('#'))
            TextSpan(
              text: '# ',
              style: TextStyle(color: fg.withValues(alpha: 0.55)),
            ),
          TextSpan(text: title),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: titleStyle,
    );
    final av = look.avatar > 0 ? avatar?.call(look.avatar) : null;
    if (look.centered) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ?av,
          const SizedBox(height: 4),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(child: name),
              Icon(
                Icons.chevron_right,
                size: 14,
                color: fg.withValues(alpha: 0.5),
              ),
            ],
          ),
          if (sub != null) DefaultTextStyle.merge(style: subStyle, child: sub),
        ],
      );
    }
    return Row(
      children: [
        if (av != null) ...[av, const SizedBox(width: 12)],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              name,
              if (sub != null)
                DefaultTextStyle.merge(style: subStyle, child: sub),
            ],
          ),
        ),
      ],
    );
  }
}

/// How the chat style's app draws its message field and send button.
@immutable
class ChatComposerLook {
  final ChatStyle style;
  final bool dark;
  const ChatComposerLook(this.style, {required this.dark});

  static ChatComposerLook of(BuildContext context) => ChatComposerLook(
    MeshChatLook.of(context).style,
    dark: Theme.of(context).brightness == Brightness.dark,
  );

  /// The app's own composer.
  bool get isPlain =>
      style == ChatStyle.standard ||
      style == ChatStyle.wadamesh ||
      style == ChatStyle.openClassic;

  /// The MeshCore app: ⊕ and the send arrow inside the field, the count
  /// always under it.
  bool get buttonsInside => style == ChatStyle.classic;

  /// iMessage: the send button inside the field, at its end.
  bool get sendInside =>
      style == ChatStyle.classic || style == ChatStyle.iphone;

  bool get alwaysCount => style == ChatStyle.classic;

  double get radius => switch (style) {
    ChatStyle.mirc => 0,
    ChatStyle.icq => 2,
    ChatStyle.discord => 22,
    _ => 28,
  };

  Color? get fill => switch (style) {
    ChatStyle.classic => dark ? classicFieldNight : classicFieldDay,
    ChatStyle.signal =>
      dark ? const Color(0xFF2A2A2A) : const Color(0xFFF0F0F0),
    ChatStyle.iphone => Colors.transparent,
    ChatStyle.android => dark ? androidRecvNight : androidRecvDay,
    ChatStyle.discord => dark ? discordFieldNight : discordFieldDay,
    ChatStyle.mirc => dark ? mircBgNight : Colors.white,
    ChatStyle.icq => dark ? const Color(0xFF2A2A2A) : Colors.white,
    _ => null,
  };

  /// A border round the field (iMessage, mIRC, ICQ), else none.
  Color? get border => switch (style) {
    ChatStyle.iphone =>
      dark ? const Color(0xFF3A3A3C) : const Color(0xFFC6C6C8),
    ChatStyle.mirc => const Color(0xFF808080),
    ChatStyle.icq => dark ? const Color(0xFF6A6A6A) : const Color(0xFF7F9DB9),
    _ => null,
  };

  Color get hint => switch (style) {
    ChatStyle.classic => dark ? classicHintNight : classicHintDay,
    ChatStyle.discord => dark ? discordMetaNight : discordMetaDay,
    ChatStyle.iphone => iphoneName,
    _ => dark ? const Color(0xFF9E9E9E) : const Color(0xFF757575),
  };

  /// The send button's colour (a filled circle) and its arrow; null for a
  /// plain arrow (MeshCore) or a text button (ICQ).
  Color? get sendFill => switch (style) {
    ChatStyle.signal => signalSent,
    ChatStyle.iphone => dark ? iphoneSentNight : iphoneSentDay,
    ChatStyle.android => dark ? androidSentNight : androidSentDay,
    ChatStyle.discord => discordBlurple,
    _ => null,
  };

  Color get sendInk => switch (style) {
    ChatStyle.android => dark ? androidSentInkNight : androidSentInkDay,
    ChatStyle.classic => dark ? classicHintNight : classicHintDay,
    ChatStyle.mirc => dark ? mircInkNight : mircInkDay,
    _ => Colors.white,
  };

  IconData get sendIcon => switch (style) {
    ChatStyle.iphone => Icons.arrow_upward,
    _ => Icons.send,
  };

  /// The "+" on the left: a grey circle behind it (iMessage, Discord).
  Color? get plusFill => switch (style) {
    ChatStyle.iphone =>
      dark ? const Color(0xFF3A3A3C) : const Color(0xFFE9E9EB),
    ChatStyle.discord => dark ? discordFieldNight : discordFieldDay,
    _ => null,
  };

  IconData get plusIcon => switch (style) {
    ChatStyle.iphone || ChatStyle.discord || ChatStyle.signal => Icons.add,
    _ => Icons.add_circle_outline,
  };

  TextStyle? get textStyle => style == ChatStyle.mirc
      ? MeshTheme.mono(fontSize: 14, color: dark ? mircInkNight : mircInkDay)
      : null;
}
