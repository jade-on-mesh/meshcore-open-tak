import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/l10n.dart';
import '../theme/chat_look.dart';
import '../theme/mesh_theme.dart';

bool isSameChatDay(DateTime a, DateTime b) {
  final la = a.toLocal();
  final lb = b.toLocal();
  return la.year == lb.year && la.month == lb.month && la.day == lb.day;
}

final Map<(String, bool), DateFormat> _timeFormats = {};

String formatChatTime(BuildContext context, DateTime time) {
  final locale = Localizations.localeOf(context).toString();
  final use24h = MediaQuery.alwaysUse24HourFormatOf(context);
  final format = _timeFormats.putIfAbsent((
    locale,
    use24h,
  ), () => use24h ? DateFormat.Hm(locale) : DateFormat.jm(locale));
  return format.format(time.toLocal());
}

String formatChatDayLabel(BuildContext context, DateTime time) {
  final now = DateTime.now();
  if (isSameChatDay(time, now)) return context.l10n.chat_today;
  final yesterday = DateTime(now.year, now.month, now.day - 1);
  if (isSameChatDay(time, yesterday)) return context.l10n.chat_yesterday;
  final locale = Localizations.localeOf(context).toString();
  return DateFormat.yMMMd(locale).format(time.toLocal());
}

/// The line above a day's first message, drawn the way the chat style's app
/// draws it (Settings > Appearance > Chat style). With iMessage and Google
/// Messages it also goes above a message after an hour's pause, and carries
/// the time ([MeshChatLook.timeHeaders]).
class ChatDaySeparator extends StatelessWidget {
  /// When: the first message's arrival after the day starts or the pause.
  final DateTime day;

  const ChatDaySeparator({super.key, required this.day});

  @override
  Widget build(BuildContext context) {
    final look = MeshChatLook.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final grey = Theme.of(context).colorScheme.onSurfaceVariant;
    final locale = Localizations.localeOf(context).toString();
    switch (look.style) {
      case ChatStyle.discord:
        // A thin line with the full date in the middle.
        final meta = dark ? discordMetaNight : discordMetaDay;
        final line = Expanded(
          child: Container(height: 1, color: meta.withValues(alpha: 0.3)),
        );
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            children: [
              line,
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  DateFormat.yMMMMd(locale).format(day.toLocal()),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: meta,
                  ),
                ),
              ),
              line,
            ],
          ),
        );
      case ChatStyle.signal:
        // A small grey "Today" in the middle, no lines.
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Center(
            child: Text(
              formatChatDayLabel(context, day),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: grey,
              ),
            ),
          ),
        );
      case ChatStyle.iphone:
      case ChatStyle.android:
        // iMessage: "Today 9:41 AM", the day in bold; Google Messages:
        // "Today · 9:41 AM".
        final ios = look.style == ChatStyle.iphone;
        final style = TextStyle(fontSize: 11.5, color: ios ? iphoneName : grey);
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Center(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: formatChatDayLabel(context, day),
                    style: style.copyWith(
                      fontWeight: ios ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                  TextSpan(
                    text: '${ios ? ' ' : ' · '}${formatChatTime(context, day)}',
                    style: style,
                  ),
                ],
              ),
            ),
          ),
        );
      case ChatStyle.mirc:
        // A status line, as IRC clients print when the date turns over.
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
          child: Text(
            '* ${context.l10n.chat_dayChanged(DateFormat.yMMMEd(locale).format(day.toLocal()))}',
            style: MeshTheme.mono(
              fontSize: 13,
              color: dark ? const Color(0xFF5FC9C9) : const Color(0xFF009393),
            ),
          ),
        );
      case ChatStyle.standard:
      case ChatStyle.wadamesh:
      case ChatStyle.classic:
      case ChatStyle.meshcore:
      case ChatStyle.openClassic:
      case ChatStyle.icq:
        return _plain(context, grey);
    }
  }

  Widget _plain(BuildContext context, Color color) {
    final line = Expanded(
      child: Container(height: 1, color: color.withValues(alpha: 0.2)),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          line,
          const SizedBox(width: 10),
          Text(
            formatChatDayLabel(context, day),
            style: MeshTheme.mono(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
          const SizedBox(width: 10),
          line,
        ],
      ),
    );
  }
}
