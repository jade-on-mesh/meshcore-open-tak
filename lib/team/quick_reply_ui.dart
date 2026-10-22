// MeshCore Open TAK - quick replies: the one-tap answers under an alert, a
// report or a pin, and who has answered (team_reply_wire.dart).

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import 'team_service.dart' show TeamReplyHeard;
import 'team_wire.dart';
import 'watch_feed.dart' show WatchReplyHeard;

/// The words for [code] in the user's language ("ETA 10 min").
String quickReplyLabel(BuildContext context, TeamReplyCode code, [int arg = 0]) {
  final l = context.l10n;
  return switch (code) {
    TeamReplyCode.copy => l.quickReply_copy,
    TeamReplyCode.onMyWay => l.quickReply_onMyWay,
    TeamReplyCode.eta => arg > 0 ? l.quickReply_etaMin(arg) : l.quickReply_eta,
    TeamReplyCode.cantHelp => l.quickReply_cantHelp,
    TeamReplyCode.seenIt => l.quickReply_seenIt,
    TeamReplyCode.needBackup => l.quickReply_needBackup,
    TeamReplyCode.allClear => l.quickReply_allClear,
  };
}

IconData quickReplyIcon(TeamReplyCode code) => switch (code) {
  TeamReplyCode.copy => Icons.check,
  TeamReplyCode.onMyWay => Icons.directions_run,
  TeamReplyCode.eta => Icons.schedule,
  TeamReplyCode.cantHelp => Icons.block,
  TeamReplyCode.seenIt => Icons.visibility_outlined,
  TeamReplyCode.needBackup => Icons.group_add_outlined,
  TeamReplyCode.allClear => Icons.verified_outlined,
};

/// One answer, as shown under the item.
class QuickReplyEntry {
  final String who;
  final String said;
  final TeamReplyCode? code;
  final DateTime at;
  final bool own;
  const QuickReplyEntry({
    required this.who,
    required this.said,
    required this.code,
    required this.at,
    required this.own,
  });
}

/// The answers to pick from: one tap sends. ETA asks how long first.
class QuickReplyChips extends StatelessWidget {
  final List<TeamReplyCode> codes;
  final void Function(TeamReplyCode code, int arg) onPick;

  /// The answer already given from here, ringed.
  final TeamReplyCode? mine;

  /// White on a coloured background (the alarm screen).
  final bool onColor;

  const QuickReplyChips({
    super.key,
    required this.codes,
    required this.onPick,
    this.mine,
    this.onColor = false,
  });

  Future<void> _eta(BuildContext context) async {
    final min = await showModalBottomSheet<int>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(title: Text(context.l10n.quickReply_etaPick)),
            for (final m in teamReplyEtas)
              ListTile(
                leading: const Icon(Icons.schedule),
                title: Text(context.l10n.quickReply_etaMin(m)),
                onTap: () => Navigator.pop(c, m),
              ),
          ],
        ),
      ),
    );
    if (min != null) onPick(TeamReplyCode.eta, min);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final c in codes)
          ActionChip(
            avatar: Icon(
              quickReplyIcon(c),
              size: 18,
              color: onColor ? Colors.white : scheme.primary,
            ),
            label: Text(quickReplyLabel(context, c)),
            labelStyle: onColor ? const TextStyle(color: Colors.white) : null,
            backgroundColor: onColor ? Colors.white.withValues(alpha: 0.12) : null,
            side: BorderSide(
              color: c == mine
                  ? (onColor ? Colors.white : scheme.primary)
                  : (onColor ? Colors.white54 : scheme.outlineVariant),
              width: c == mine ? 2 : 1,
            ),
            onPressed: () {
              if (c == TeamReplyCode.eta) {
                _eta(context);
              } else {
                onPick(c, 0);
              }
            },
          ),
      ],
    );
  }
}

String _ago(BuildContext context, DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return context.l10n.quickReply_now;
  if (d.inHours < 1) return '${d.inMinutes}m';
  if (d.inDays < 1) return '${d.inHours}h';
  return '${d.inDays}d';
}

/// Who answered and what: "Sam · On my way · 2m", one line each.
class QuickReplyList extends StatelessWidget {
  final List<QuickReplyEntry> entries;
  final bool onColor;
  const QuickReplyList({super.key, required this.entries, this.onColor = false});

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) return const SizedBox.shrink();
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final fg = onColor ? Colors.white : scheme.onSurface;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final e in entries)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                Icon(
                  e.code == null ? Icons.reply : quickReplyIcon(e.code!),
                  size: 16,
                  color: onColor ? Colors.white70 : scheme.primary,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: e.own ? context.l10n.quickReply_you : e.who,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        TextSpan(text: '  ${e.said}'),
                      ],
                    ),
                    style: t.bodyMedium?.copyWith(color: fg),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  _ago(context, e.at),
                  style: t.bodySmall?.copyWith(
                    color: onColor ? Colors.white70 : scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// A short line for a collapsed card: "2 answers: Sam On my way, Lee Seen it".
String quickReplySummary(BuildContext context, List<QuickReplyEntry> entries) {
  final parts = [
    for (final e in entries.reversed.take(2))
      '${e.own ? context.l10n.quickReply_you : e.who} ${e.said}',
  ];
  return context.l10n.quickReply_summary(entries.length, parts.join(', '));
}

/// The answers block under a team alert, report or pin: who answered, then
/// the chips. [onPick] sends.
class QuickReplySection extends StatelessWidget {
  final List<QuickReplyEntry> entries;
  final List<TeamReplyCode> codes;
  final void Function(TeamReplyCode code, int arg) onPick;
  final bool canReply;
  const QuickReplySection({
    super.key,
    required this.entries,
    required this.codes,
    required this.onPick,
    this.canReply = true,
  });

  @override
  Widget build(BuildContext context) {
    TeamReplyCode? mine;
    for (final e in entries) {
      if (e.own) mine = e.code;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (entries.isNotEmpty) ...[
          Text(
            context.l10n.quickReply_answers,
            style: Theme.of(context).textTheme.labelLarge,
          ),
          const SizedBox(height: 4),
          QuickReplyList(entries: entries),
          const SizedBox(height: 8),
        ],
        if (canReply) QuickReplyChips(codes: codes, onPick: onPick, mine: mine),
      ],
    );
  }
}

/// Team replies as entries.
List<QuickReplyEntry> teamReplyEntries(
  BuildContext context,
  List<TeamReplyHeard> r,
) => [
  for (final x in r)
    QuickReplyEntry(
      who: x.callsign,
      said: quickReplyLabel(context, x.code, x.arg),
      code: x.code,
      at: x.at,
      own: x.own,
    ),
];

/// Replies on a watched channel as entries: known answers in the user's
/// language, anything else as written.
List<QuickReplyEntry> watchReplyEntries(
  BuildContext context,
  List<WatchReplyHeard> r,
) => [
  for (final x in r)
    QuickReplyEntry(
      who: x.sender,
      said: x.code == null ? x.said : quickReplyLabel(context, x.code!, x.arg),
      code: x.code,
      at: x.at,
      own: x.own,
    ),
];
