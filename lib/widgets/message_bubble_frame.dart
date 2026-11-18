import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../theme/chat_look.dart';
import '../theme/mesh_theme.dart';

/// Colours shared by the direct-message and channel chat bubbles.
@immutable
class MessageBubbleColors {
  final Color background;
  final Color border;
  final Color text;
  final Color meta;

  /// The sender's name above a received message, when the chat style gives
  /// it a colour of its own (else the screen picks one).
  final Color? name;

  /// Frosted glass (the Wadamesh TAK style): [background] see-through over a
  /// blur of what's behind, a light sheen at the top and a thin bright edge.
  final bool glass;

  /// A chat log line (mIRC): no bubble at all, the full width.
  final bool flat;

  const MessageBubbleColors({
    required this.background,
    required this.border,
    required this.text,
    required this.meta,
    this.name,
    this.glass = false,
    this.flat = false,
  });

  /// Outgoing bubbles use the theme's [MeshBubbleTheme]; a failed send
  /// switches to the error container. The chat style (Settings > Appearance)
  /// can colour them its own way; [senderName] is who sent a received one.
  factory MessageBubbleColors.of(
    BuildContext context, {
    required bool isOutgoing,
    bool isFailed = false,
    String? senderName,
  }) {
    final scheme = Theme.of(context).colorScheme;
    if (!isFailed) {
      final look = MeshChatLook.of(context).style;
      final dark = Theme.of(context).brightness == Brightness.dark;
      switch (look) {
        case ChatStyle.standard:
        case ChatStyle.openClassic:
          break;
        case ChatStyle.wadamesh:
          final name = senderName?.trim() ?? '';
          final bg = isOutgoing
              ? (dark ? wadameshSentNight : wadameshSentDay)
              : name.isNotEmpty
              ? wadameshBubbleTint(name)
              : (dark ? wadameshRecvNight : wadameshRecvDay);
          return MessageBubbleColors(
            background: bg,
            border: Colors.white.withValues(alpha: 0.22),
            text: wadameshBubbleInk,
            meta: wadameshBubbleMeta,
            name: isOutgoing || name.isEmpty
                ? null
                : wadameshNameColor(name, dark: dark),
            glass: true,
          );
        case ChatStyle.signal:
          final name = senderName?.trim() ?? '';
          final bg = isOutgoing
              ? signalSent
              : (dark ? signalRecvNight : signalRecvDay);
          final ink = isOutgoing
              ? signalSentInk
              : (dark ? signalInkNight : signalInkDay);
          return MessageBubbleColors(
            background: bg,
            border: bg,
            text: ink,
            meta: ink.withValues(alpha: 0.7),
            name: isOutgoing || name.isEmpty
                ? null
                : signalNameColor(name, dark: dark),
          );
        case ChatStyle.iphone:
          final name = senderName?.trim() ?? '';
          final bg = isOutgoing
              ? (dark ? iphoneSentNight : iphoneSentDay)
              : (dark ? iphoneRecvNight : iphoneRecvDay);
          final ink = isOutgoing || dark ? Colors.white : Colors.black;
          return MessageBubbleColors(
            background: bg,
            border: bg,
            text: ink,
            meta: ink.withValues(alpha: 0.6),
            name: isOutgoing || name.isEmpty ? null : iphoneName,
          );
        case ChatStyle.android:
          final name = senderName?.trim() ?? '';
          final bg = isOutgoing
              ? (dark ? androidSentNight : androidSentDay)
              : (dark ? androidRecvNight : androidRecvDay);
          final ink = isOutgoing
              ? (dark ? androidSentInkNight : androidSentInkDay)
              : (dark ? androidRecvInkNight : androidRecvInkDay);
          return MessageBubbleColors(
            background: bg,
            border: bg,
            text: ink,
            meta: ink.withValues(alpha: 0.65),
            name: isOutgoing || name.isEmpty
                ? null
                : androidNameColor(name, dark: dark),
          );
        case ChatStyle.mirc:
          final name = senderName?.trim() ?? '';
          final ink = dark ? mircInkNight : mircInkDay;
          return MessageBubbleColors(
            background: Colors.transparent,
            border: Colors.transparent,
            text: ink,
            meta: ink.withValues(alpha: 0.5),
            // Mine named too, in a log: the screens pass my own name.
            name: name.isEmpty ? null : mircNickColor(name, dark: dark),
            flat: true,
          );
        case ChatStyle.icq:
          final ink = dark ? icqInkNight : icqInkDay;
          return MessageBubbleColors(
            background: Colors.transparent,
            border: Colors.transparent,
            text: ink,
            meta: ink.withValues(alpha: 0.5),
            name: isOutgoing
                ? (dark ? icqMineNight : icqMineDay)
                : (dark ? icqTheirsNight : icqTheirsDay),
            flat: true,
          );
        case ChatStyle.discord:
          final name = senderName?.trim() ?? '';
          return MessageBubbleColors(
            background: Colors.transparent,
            border: Colors.transparent,
            text: dark ? discordInkNight : discordInkDay,
            meta: dark ? discordMetaNight : discordMetaDay,
            name: name.isEmpty ? null : discordNameColor(dark: dark),
            flat: true,
          );
        case ChatStyle.classic:
          final name = senderName?.trim() ?? '';
          final bg = isOutgoing ? classicSent : classicRecv;
          final ink = isOutgoing ? Colors.white : classicRecvInk;
          return MessageBubbleColors(
            background: bg,
            border: bg,
            text: ink,
            meta: ink.withValues(alpha: 0.6),
            name: isOutgoing || name.isEmpty ? null : classicNameColor(name),
          );
      }
    }
    final bubble = MeshBubbleTheme.of(context);
    final text = isFailed
        ? scheme.onErrorContainer
        : isOutgoing
        ? bubble.meInk
        : scheme.onSurface;
    return MessageBubbleColors(
      background: isFailed
          ? scheme.errorContainer
          : isOutgoing
          ? bubble.me
          : scheme.surfaceContainerLow,
      border: isFailed
          ? scheme.error
          : isOutgoing
          ? bubble.meBorder
          : scheme.outlineVariant,
      text: text,
      meta: text.withValues(alpha: 0.65),
    );
  }
}

/// Asymmetric bubble radius: the corner nearest the sender is tight. The
/// classic MeshCore style rounds every corner the same.
BorderRadius messageBubbleRadius({
  required bool isOutgoing,
  ChatStyle style = ChatStyle.standard,
  ChatRun run = ChatRun.solo,
}) {
  if (style == ChatStyle.classic) {
    return BorderRadius.circular(classicRadius);
  }
  final look = MeshChatLook(style: style);
  if (look.bubbleRuns) {
    // Signal, iMessage, Google Messages: round all over, but tighter on the
    // sender's side where a bubble joins the one above or below it in a run.
    final round = Radius.circular(switch (style) {
      ChatStyle.iphone => iphoneRadius,
      ChatStyle.android => androidRadius,
      _ => signalRadius,
    });
    final join = Radius.circular(look.runJoinRadius);
    final top = run.joinsAbove ? join : round;
    final bottom = run.joinsBelow ? join : round;
    return isOutgoing
        ? BorderRadius.only(
            topLeft: round,
            bottomLeft: round,
            topRight: top,
            bottomRight: bottom,
          )
        : BorderRadius.only(
            topRight: round,
            bottomRight: round,
            topLeft: top,
            bottomLeft: bottom,
          );
  }
  if (style == ChatStyle.mirc ||
      style == ChatStyle.icq ||
      style == ChatStyle.discord) {
    return BorderRadius.zero;
  }
  return isOutgoing
      ? const BorderRadius.only(
          topLeft: Radius.circular(MeshRadii.lg),
          topRight: Radius.circular(MeshRadii.lg),
          bottomLeft: Radius.circular(MeshRadii.lg),
          bottomRight: Radius.circular(MeshRadii.xs),
        )
      : const BorderRadius.only(
          topLeft: Radius.circular(MeshRadii.xs),
          topRight: Radius.circular(MeshRadii.lg),
          bottomLeft: Radius.circular(MeshRadii.lg),
          bottomRight: Radius.circular(MeshRadii.lg),
        );
}

/// A person's colour from their name: the one the official MeshCore app (and
/// Wadamesh TAK) gives them, the same as their [AvatarCircle] (MeshCore Open
/// Classic: its own palette). On a light surface pass it through
/// `readableAccent`.
Color senderNameColor(String name, {ChatStyle style = ChatStyle.standard}) =>
    switch (style) {
      ChatStyle.openClassic => openClassicColor(name),
      ChatStyle.mirc => mircNickColor(name, dark: true),
      _ => classicAvatarColor(name),
    };

/// The bubble container shared by both chat screens: colour, border,
/// asymmetric radius, padding and the 72% max width.
class MessageBubbleFrame extends StatelessWidget {
  final bool isOutgoing;
  final bool isFailed;

  /// Tighter padding for media (GIF) content.
  final bool compact;
  final double maxWidth;
  final Widget child;

  const MessageBubbleFrame({
    super.key,
    required this.isOutgoing,
    required this.maxWidth,
    required this.child,
    this.isFailed = false,
    this.compact = false,
    this.colors,
    this.run = ChatRun.solo,
    this.leading,
  });

  /// On a chat log line (mIRC): what starts the line, `[time] <nick>`, with
  /// the message beside it so a long one wraps under its own start.
  final Widget? leading;

  /// Its place in a run from one sender (Signal's joined corners).
  final ChatRun run;

  /// Colours of their own (MeshCore Open TAK: an OTP theme's bubble colours),
  /// instead of the outgoing/received defaults.
  final MessageBubbleColors? colors;

  @override
  Widget build(BuildContext context) {
    final colors =
        this.colors ??
        MessageBubbleColors.of(
          context,
          isOutgoing: isOutgoing,
          isFailed: isFailed,
        );
    final radius = messageBubbleRadius(
      isOutgoing: isOutgoing,
      style: MeshChatLook.of(context).style,
      run: run,
    );
    final padding = compact
        ? const EdgeInsets.all(4)
        : const EdgeInsets.symmetric(horizontal: 12, vertical: 8);
    if (colors.flat) {
      // a chat log line: no bubble, the full width
      final lead = leading;
      return Container(
        padding: compact
            ? EdgeInsets.zero
            : const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: lead == null
            ? child
            : Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // a long nick wraps rather than pushing the text off
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: maxWidth * 0.5),
                    child: lead,
                  ),
                  Flexible(child: child),
                ],
              ),
      );
    }
    final constraints = BoxConstraints(maxWidth: maxWidth * 0.72);
    if (colors.glass) {
      return _GlassBubble(
        colors: colors,
        radius: radius,
        padding: padding,
        constraints: constraints,
        child: child,
      );
    }
    return Container(
      padding: padding,
      constraints: constraints,
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: radius,
        border: Border.all(color: colors.border, width: 1),
      ),
      child: child,
    );
  }
}

/// A frosted-glass bubble, iOS style: what's behind (the chat background) is
/// blurred and shows through the bubble's colour, with a light sheen across
/// the top, a thin bright edge and a soft shadow under it.
class _GlassBubble extends StatelessWidget {
  final MessageBubbleColors colors;
  final BorderRadius radius;
  final EdgeInsets padding;
  final BoxConstraints constraints;
  final Widget child;

  const _GlassBubble({
    required this.colors,
    required this.radius,
    required this.padding,
    required this.constraints,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final bg = colors.background;
    final sheen = Color.lerp(bg, Colors.white, 0.18)!;
    return Container(
      constraints: constraints,
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.22),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              borderRadius: radius,
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  sheen.withValues(alpha: 0.78),
                  bg.withValues(alpha: 0.66),
                  bg.withValues(alpha: 0.74),
                ],
                stops: const [0, 0.45, 1],
              ),
              border: Border.all(color: colors.border, width: 1),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}
