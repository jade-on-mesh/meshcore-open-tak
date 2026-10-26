// MeshCore Open TAK - search a channel's messages (the channel's ⋮ menu >
// Search). The field sits under the app bar; while it holds text the
// transcript gives way to the matching messages, newest first, and tapping one
// closes the search and scrolls the transcript to it.

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/l10n.dart';
import '../models/channel_message.dart';

/// [text] as spans with every case-insensitive occurrence of [query] in
/// [highlight] (all of it in [base] when the query is empty or absent).
List<TextSpan> channelSearchSpans(
  String text,
  String query,
  TextStyle? base,
  TextStyle? highlight,
) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return [TextSpan(text: text, style: base)];
  final lower = text.toLowerCase();
  final spans = <TextSpan>[];
  var at = 0;
  while (true) {
    final i = lower.indexOf(q, at);
    if (i < 0) break;
    if (i > at) spans.add(TextSpan(text: text.substring(at, i), style: base));
    spans.add(
      TextSpan(text: text.substring(i, i + q.length), style: highlight),
    );
    at = i + q.length;
  }
  if (at < text.length)
    spans.add(TextSpan(text: text.substring(at), style: base));
  return spans;
}

/// The search field shown under a channel's app bar.
class ChannelSearchField extends StatelessWidget
    implements PreferredSizeWidget {
  const ChannelSearchField({
    super.key,
    required this.controller,
    required this.onChanged,
    required this.onClose,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onClose;

  @override
  Size get preferredSize => const Size.fromHeight(height);

  static const double height = 60;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SizedBox(
      height: height,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 4, 8),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                autofocus: true,
                textInputAction: TextInputAction.search,
                onChanged: onChanged,
                decoration: InputDecoration(
                  isDense: true,
                  hintText: l10n.channelSearch_hint,
                  prefixIcon: const Icon(Icons.search),
                  border: const OutlineInputBorder(),
                  suffixIcon: ValueListenableBuilder<TextEditingValue>(
                    valueListenable: controller,
                    builder: (context, value, _) => value.text.isEmpty
                        ? const SizedBox.shrink()
                        : IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              controller.clear();
                              onChanged('');
                            },
                          ),
                  ),
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: l10n.channelSearch_close,
              onPressed: onClose,
            ),
          ],
        ),
      ),
    );
  }
}

/// The matching messages, newest first.
class ChannelSearchResults extends StatelessWidget {
  const ChannelSearchResults({
    super.key,
    required this.query,
    required this.results,
    required this.busy,
    required this.onOpen,
  });

  final String query;
  final List<ChannelMessage>? results;
  final bool busy;
  final ValueChanged<ChannelMessage> onOpen;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final list = results;
    if (list == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (list.isEmpty) {
      return Center(
        child: Text(
          l10n.channelSearch_noResults,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      );
    }
    final locale = Localizations.localeOf(context).toString();
    final when = DateFormat.yMMMd(locale).add_jm();
    final base = theme.textTheme.bodyMedium;
    final hit = base?.copyWith(
      backgroundColor: scheme.primaryContainer,
      color: scheme.onPrimaryContainer,
      fontWeight: FontWeight.w600,
    );
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: Row(
            children: [
              Text(
                l10n.channelSearch_count(list.length),
                style: theme.textTheme.labelMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              if (busy) ...[
                const SizedBox(width: 8),
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ],
            ],
          ),
        ),
        Expanded(
          child: ListView.separated(
            itemCount: list.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final m = list[i];
              final text =
                  m.translatedText?.isNotEmpty == true &&
                      !m.displayText.toLowerCase().contains(
                        query.trim().toLowerCase(),
                      )
                  ? m.translatedText!
                  : m.displayText;
              return ListTile(
                title: Row(
                  children: [
                    Expanded(
                      child: RichText(
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        text: TextSpan(
                          children: channelSearchSpans(
                            m.senderName,
                            query,
                            theme.textTheme.titleSmall,
                            theme.textTheme.titleSmall?.merge(hit),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      when.format(m.receivedAt),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                subtitle: RichText(
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  text: TextSpan(
                    children: channelSearchSpans(text, query, base, hit),
                  ),
                ),
                onTap: () => onOpen(m),
              );
            },
          ),
        ),
      ],
    );
  }
}
