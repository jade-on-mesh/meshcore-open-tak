import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../theme/mesh_theme.dart';
import '../services/alert_words_service.dart' show alertBadgeColor;

/// Unread channel messages holding an alert word: a bell and the count in
/// white on dark blue, beside the red unread count in the channel list.
class AlertWordBadge extends StatelessWidget {
  final int count;

  const AlertWordBadge({super.key, required this.count});

  @override
  Widget build(BuildContext context) {
    final label = count > 99 ? '99+' : '$count';
    return Semantics(
      label: context.l10n.alertWords_badgeLabel(count),
      excludeSemantics: true,
      child: Container(
        constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(
          color: alertBadgeColor,
          borderRadius: BorderRadius.circular(11),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.notifications_active,
              size: 12,
              color: Colors.white,
            ),
            const SizedBox(width: 2),
            Text(
              label,
              style: MeshTheme.mono(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The chip on a message that holds an alert word: a bell and the word.
class AlertWordChip extends StatelessWidget {
  final String word;

  const AlertWordChip({super.key, required this.word});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: context.l10n.alertWords_chipLabel(word),
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: alertBadgeColor,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.notifications_active,
              size: 11,
              color: Colors.white,
            ),
            const SizedBox(width: 3),
            Flexible(
              child: Text(
                word,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
