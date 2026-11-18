// MeshCore Open TAK - the MeshCore Classic chat style's line under a bubble, as the
// MeshCore app draws it: `5:38AM • 3 Hops • 1-byte`.

import 'package:flutter/material.dart';

import 'chat_day_separator.dart' show formatChatTime;
import '../l10n/l10n.dart';

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

  /// After the text: a message of mine's status icon, say.
  final Widget? trailing;

  const ChatMetaBelow({
    super.key,
    required this.time,
    this.hops,
    this.hashBytes,
    this.region,
    this.textScale = 1,
    this.padding = EdgeInsets.zero,
    this.trailing,
  });

  /// The line's text.
  static String text(
    BuildContext context, {
    required DateTime time,
    int? hops,
    int? hashBytes,
    String? region,
  }) {
    final l10n = context.l10n;
    final h = hops;
    // "5:38AM", as the MeshCore app writes it.
    final clock = formatChatTime(
      context,
      time,
    ).replaceAll(RegExp(r'[\s\u202f\u00a0]+(?=[AaPp]\.?[Mm]\.?$)'), '');
    return [
      clock,
      if (h != null) h == 0 ? l10n.chat_direct : l10n.chat_metaHops(h),
      if (h != null && h > 0 && hashBytes != null && hashBytes > 0)
        l10n.chat_metaHashBytes(hashBytes),
      if (region != null && region.isNotEmpty) region,
    ].join(' • ');
  }

  @override
  Widget build(BuildContext context) {
    // On the chat background, not the bubble: the theme's quiet ink, readable
    // in light and dark.
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
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
              ),
              style: TextStyle(
                fontSize: 13 * textScale,
                color: color,
                letterSpacing: 0.3,
              ),
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 4), trailing!],
        ],
      ),
    );
  }
}
