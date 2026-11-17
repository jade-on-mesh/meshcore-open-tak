// MeshCore Open TAK - AI sketch HD's packet log, with Copy and Share, as the
// voice diagnostics sheet has (voice_message_bubble.dart showVoxVoiceLog).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../l10n/l10n.dart';
import '../services/aeic_hd_log.dart';
import '../theme/mesh_theme.dart';

/// Shows the AI sketch HD packet log, newest first, with Copy and Share.
void showAeicHdLog(BuildContext context) {
  final log = AeicHdLog.instance;
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) {
      final l10n = context.l10n;
      return SafeArea(
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.8,
          child: ValueListenableBuilder<int>(
            valueListenable: log.version,
            builder: (context, _, _) {
              final text = log.text();
              final lines = text.isEmpty ? <String>[] : text.split('\n');
              return CustomScrollView(
                slivers: [
                  SliverList.list(
                    children: [
                      ListTile(
                        title: Text(l10n.aeicHd_packetLog),
                        subtitle: Text(l10n.aeicHd_packetLogHint),
                      ),
                      // Buttons, not an icon at the edge: on a phone the
                      // icon was off screen.
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            FilledButton.tonalIcon(
                              icon: const Icon(Icons.copy),
                              label: Text(l10n.debugLog_copyLog),
                              onPressed: text.isEmpty
                                  ? null
                                  : () {
                                      Clipboard.setData(
                                        ClipboardData(text: text),
                                      );
                                      ScaffoldMessenger.maybeOf(
                                        context,
                                      )?.showSnackBar(
                                        SnackBar(
                                          content: Text(
                                            l10n.aeicHd_packetLogCopied,
                                          ),
                                        ),
                                      );
                                    },
                            ),
                            FilledButton.tonalIcon(
                              icon: const Icon(Icons.share),
                              label: Text(l10n.common_share),
                              onPressed: text.isEmpty
                                  ? null
                                  : () => SharePlus.instance.share(
                                      ShareParams(
                                        text: text,
                                        subject:
                                            'MeshCore Open TAK AI sketch HD '
                                            'packet log',
                                      ),
                                    ),
                            ),
                          ],
                        ),
                      ),
                      const Divider(height: 1),
                      if (log.entries.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(l10n.aeicHd_packetLogEmpty),
                        ),
                    ],
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    sliver: SliverList.builder(
                      itemCount: lines.length,
                      itemBuilder: (context, i) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 1),
                        child: SelectableText(
                          lines[i],
                          style: MeshTheme.mono(fontSize: 11.5),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      );
    },
  );
}
