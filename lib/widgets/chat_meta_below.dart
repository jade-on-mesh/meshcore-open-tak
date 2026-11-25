// MeshCore Open TAK - the MeshCore Classic chat style's line under a bubble,
// as the MeshCore app draws it: `5:38AM • 3 Hops • 1-byte` (an earlier day's
// with its date, `22/Oct 11:07AM • ...`), and `Heard 5 Repeats ✓` under a
// channel message of mine once repeaters have been heard sending it on.

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/l10n.dart';
import 'chat_day_separator.dart' show formatChatTime, isSameChatDay;

/// The MeshCore app's grey for the line, and its darker grey for "Heard N
/// Repeats". By day both are the darker one, to read on the light background.
Color classicMetaInk({required bool dark}) =>
    dark ? const Color(0xFF9E9E9E) : const Color(0xFF616161);
Color classicHeardInk({required bool dark}) =>
    dark ? const Color(0xFF757575) : const Color(0xFF616161);

/// The time, how far the message came and the path hash size, on one quiet
/// line under its bubble (ChatStyle.classic). [hops] null: not known (a
/// message of mine, a flood); 0: direct. [hashBytes] shows with hops only.
class ChatMetaBelow extends StatelessWidget {
  final DateTime time;
  final int? hops;
  final int? hashBytes;
  final String? region;
  final double textScale;
  final EdgeInsetsGeometry padding;

  /// A channel message of mine: how many repeats of it were heard. Above 0
  /// the line is `Heard N Repeats` and a tick instead of the time.
  final int? heardRepeats;

  /// After the text: a message of mine's status icon, say.
  final Widget? trailing;

  /// The message was edited: `(edited)` ends the line.
  final bool edited;

  const ChatMetaBelow({
    super.key,
    required this.time,
    this.hops,
    this.hashBytes,
    this.region,
    this.textScale = 1,
    this.padding = EdgeInsets.zero,
    this.heardRepeats,
    this.trailing,
    this.edited = false,
  });

  /// The line's text.
  static String text(
    BuildContext context, {
    required DateTime time,
    int? hops,
    int? hashBytes,
    String? region,
    int? heardRepeats,
    bool edited = false,
  }) {
    final l10n = context.l10n;
    final r = heardRepeats;
    if (r != null && r > 0) {
      final heard = l10n.chat_metaHeardRepeats(r);
      return edited ? '$heard ${l10n.chat_edited}' : heard;
    }
    final h = hops;
    // "5:38AM", as the MeshCore app writes it; "22/Oct 5:38AM" on an earlier
    // day.
    var clock = formatChatTime(
      context,
      time,
    ).replaceAll(RegExp(r'[\s  ]+(?=[AaPp]\.?[Mm]\.?$)'), '');
    if (!isSameChatDay(time, DateTime.now())) {
      final locale = Localizations.localeOf(context).toString();
      clock = '${DateFormat('dd/MMM', locale).format(time.toLocal())} $clock';
    }
    return [
      clock,
      if (h != null) h == 0 ? l10n.chat_direct : l10n.chat_metaHops(h),
      if (h != null && h > 0 && hashBytes != null && hashBytes > 0)
        l10n.chat_metaHashBytes(hashBytes),
      if (region != null && region.isNotEmpty) region,
    ].join(' • ') +
        (edited ? ' ${l10n.chat_edited}' : '');
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final heard = (heardRepeats ?? 0) > 0;
    final color = heard
        ? classicHeardInk(dark: dark)
        : classicMetaInk(dark: dark);
    return Padding(
      padding: padding,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              text(
                context,
                time: time,
                hops: hops,
                hashBytes: hashBytes,
                region: region,
                heardRepeats: heardRepeats,
                edited: edited,
              ),
              style: TextStyle(
                fontSize: 13 * textScale,
                color: color,
                letterSpacing: 0.3,
              ),
            ),
          ),
          if (heard) ...[
            const SizedBox(width: 6),
            Icon(Icons.check_circle, size: 16 * textScale, color: color),
          ] else if (trailing != null) ...[
            const SizedBox(width: 4),
            trailing!,
          ],
        ],
      ),
    );
  }
}
