import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
import '../services/received_image_store.dart';
import '../vox/aeic_hd_repair.dart';

/// Under an incomplete AI sketch HD: "Ask for the rest", or, while the app
/// asks for it by itself, how far that has got and a Stop button
/// (aeic_hd_repair.dart).
class AeicHdResumeControls extends StatelessWidget {
  final ReceivedImageEntry entry;
  final VoidCallback onAskForRest;
  final Color? color;

  const AeicHdResumeControls({
    super.key,
    required this.entry,
    required this.onAskForRest,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final repair = context.watch<AeicHdRepairService?>();
    final auto = repair?.autoResumeFor(entry.streamId);
    final l10n = context.l10n;
    if (repair != null && auto != null) {
      final theme = Theme.of(context);
      final style = theme.textTheme.bodySmall?.copyWith(color: color);
      return Padding(
        padding: const EdgeInsets.only(left: 8, top: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox.square(
              dimension: 14,
              child: auto.active
                  ? CircularProgressIndicator(strokeWidth: 2, color: color)
                  : Icon(Icons.schedule, size: 14, color: color),
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                auto.attempts == 0
                    ? l10n.aeicHd_autoResuming
                    : l10n.aeicHd_autoResumingTry(auto.attempts),
                style: style,
              ),
            ),
            TextButton(
              onPressed: () => repair.stopAutoResume(entry.streamId),
              child: Text(l10n.aeicHd_autoStop),
            ),
          ],
        ),
      );
    }
    if (!aeicHdResumable(entry)) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(left: 4, top: 2),
      child: TextButton.icon(
        onPressed: onAskForRest,
        icon: const Icon(Icons.download_outlined, size: 18),
        label: Text(l10n.aeicHd_askForRest),
      ),
    );
  }
}
