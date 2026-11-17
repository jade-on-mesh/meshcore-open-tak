// MeshCore Open TAK - Settings > Appearance > Chat style: the bubble styles,
// each with a small preview in the current light or dark mode.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../services/app_settings_service.dart';
import '../theme/chat_look.dart';
import '../theme/mesh_theme.dart';
import 'mesh_ui.dart';
import 'message_bubble_frame.dart';

/// The name of [style] as the picker shows it.
String chatStyleLabel(BuildContext context, ChatStyle style) {
  final l10n = context.l10n;
  return switch (style) {
    ChatStyle.standard => l10n.appSettings_chatStyleStandard,
    ChatStyle.wadamesh => l10n.appSettings_chatStyleWadamesh,
    ChatStyle.classic => l10n.appSettings_chatStyleClassic,
    ChatStyle.openClassic => l10n.appSettings_chatStyleOpenClassic,
    ChatStyle.signal => l10n.appSettings_chatStyleSignal,
    ChatStyle.iphone => l10n.appSettings_chatStyleIphone,
    ChatStyle.android => l10n.appSettings_chatStyleAndroid,
    ChatStyle.mirc => l10n.appSettings_chatStyleMirc,
    ChatStyle.icq => l10n.appSettings_chatStyleIcq,
    ChatStyle.discord => l10n.appSettings_chatStyleDiscord,
  };
}

String _chatStyleHelp(BuildContext context, ChatStyle style) {
  final l10n = context.l10n;
  return switch (style) {
    ChatStyle.standard => l10n.appSettings_chatStyleStandardHelp,
    ChatStyle.wadamesh => l10n.appSettings_chatStyleWadameshHelp,
    ChatStyle.classic => l10n.appSettings_chatStyleClassicHelp,
    ChatStyle.openClassic => l10n.appSettings_chatStyleOpenClassicHelp,
    ChatStyle.signal => l10n.appSettings_chatStyleSignalHelp,
    ChatStyle.iphone => l10n.appSettings_chatStyleIphoneHelp,
    ChatStyle.android => l10n.appSettings_chatStyleAndroidHelp,
    ChatStyle.mirc => l10n.appSettings_chatStyleMircHelp,
    ChatStyle.icq => l10n.appSettings_chatStyleIcqHelp,
    ChatStyle.discord => l10n.appSettings_chatStyleDiscordHelp,
  };
}

/// Bottom sheet for choosing the chat style.
void showChatStyleSheet(
  BuildContext context,
  AppSettingsService settingsService,
) {
  final current = ChatStyle.fromId(settingsService.settings.chatStyle);
  showMeshSheet(
    context,
    builder: (ctx) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        BottomSheetHeader(title: ctx.l10n.appSettings_chatStyle),
        ConstrainedBox(
          // Capped so the sheet still fits short screens and landscape.
          constraints: BoxConstraints(
            maxHeight: math.min(560, MediaQuery.sizeOf(ctx).height * 0.75),
          ),
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final style in ChatStyle.values)
                _ChatStyleOption(
                  style: style,
                  selected: style == current,
                  onTap: () {
                    settingsService.setChatStyle(style.id);
                    Navigator.pop(ctx);
                  },
                ),
              SizedBox(height: MediaQuery.paddingOf(ctx).bottom + 8),
            ],
          ),
        ),
      ],
    ),
  );
}

class _ChatStyleOption extends StatelessWidget {
  final ChatStyle style;
  final bool selected;
  final VoidCallback onTap;

  const _ChatStyleOption({
    required this.style,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                selected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                size: 24,
                color: selected ? scheme.primary : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      chatStyleLabel(context, style),
                      style: textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      _chatStyleHelp(context, style),
                      style: textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 8),
                    ExcludeSemantics(child: _ChatStylePreview(style: style)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A received and a sent bubble in [style], with this phone's other
/// settings (light or dark, brighter icons).
class _ChatStylePreview extends StatelessWidget {
  final ChatStyle style;
  const _ChatStylePreview({required this.style});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final look = MeshChatLook.of(context).copyWith(style: style);
    return Theme(
      data: look.applyTo(theme),
      child: Builder(
        builder: (context) {
          const sender = 'Alpha-1';
          final recv = MessageBubbleColors.of(
            context,
            isOutgoing: false,
            senderName: sender,
          );
          final sent = MessageBubbleColors.of(context, isOutgoing: true);
          final l10n = context.l10n;
          if (look.isLog) {
            // A log: mIRC `<nick> text` lines; ICQ `Name (time):` over the
            // text; Discord an avatar, the name, the text.
            const me = 'Me';
            final mine = MessageBubbleColors.of(
              context,
              isOutgoing: true,
              senderName: me,
            );
            const time = '2:03 PM';
            TextStyle font(double size, Color color, {bool bold = false}) =>
                look.logMono
                ? MeshTheme.mono(
                    fontSize: size,
                    fontWeight: bold ? FontWeight.w700 : null,
                    color: color,
                  )
                : TextStyle(
                    fontSize: size,
                    fontWeight: bold ? FontWeight.w700 : null,
                    color: color,
                  );
            Widget entry(
              String nick,
              Color? nickColor,
              String text,
              Color ink,
            ) {
              final label = look.logNick(nick, time: time);
              if (look.style == ChatStyle.mirc) {
                return Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: '$label ',
                        style: font(12, nickColor ?? ink, bold: true),
                      ),
                      TextSpan(text: text, style: font(12, ink)),
                    ],
                  ),
                );
              }
              final body = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (look.style == ChatStyle.discord)
                    // Discord's header: the name, the time beside it in grey.
                    Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: '$label  ',
                            style: font(12, nickColor ?? ink, bold: true),
                          ),
                          TextSpan(text: time, style: font(10, mine.meta)),
                        ],
                      ),
                    )
                  else
                    Text(label, style: font(12, nickColor ?? ink, bold: true)),
                  Text(text, style: font(13, ink)),
                ],
              );
              if (!look.logAvatars) return body;
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AvatarCircle(name: nick, size: 28),
                  const SizedBox(width: 8),
                  Flexible(child: body),
                ],
              );
            }

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                entry(
                  sender,
                  recv.name,
                  l10n.appSettings_chatStylePreviewReceived,
                  recv.text,
                ),
                const SizedBox(height: 6),
                entry(
                  me,
                  mine.name,
                  l10n.appSettings_chatStylePreviewSent,
                  mine.text,
                ),
              ],
            );
          }
          return LayoutBuilder(
            builder: (context, constraints) {
              final w = constraints.maxWidth;
              return Column(
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      const AvatarCircle(name: sender, size: 28),
                      const SizedBox(width: 6),
                      Flexible(
                        child: MessageBubbleFrame(
                          isOutgoing: false,
                          colors: recv,
                          maxWidth: w,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                sender,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color:
                                      recv.name ??
                                      senderNameColor(sender, style: style),
                                ),
                              ),
                              Text(
                                l10n.appSettings_chatStylePreviewReceived,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: recv.text,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Align(
                    alignment: Alignment.centerRight,
                    child: MessageBubbleFrame(
                      isOutgoing: true,
                      colors: sent,
                      maxWidth: w,
                      child: Text(
                        l10n.appSettings_chatStylePreviewSent,
                        style: TextStyle(fontSize: 13, color: sent.text),
                      ),
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}
