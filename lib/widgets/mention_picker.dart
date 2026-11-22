// MeshCore Open TAK - the composer's @ picker: type "@" in a channel and
// everyone who has written there comes up, narrowed as you type; tap one to
// put "@[name] " in the message, the mention format MeshCore apps and
// Wadamesh TAK standalones read.

import 'package:flutter/material.dart';

/// The "@" being typed at the cursor: [start] is the "@"'s offset, [query]
/// what follows it up to the cursor.
typedef MentionQuery = ({int start, String query});

/// The mention being typed in [value], or null. An "@" at the start or after
/// a space, not one that opens a finished "@[name]", with no more than 32
/// characters after it and none of "@", "[", "]" or a line break. Spaces are
/// allowed, as names have them ("@tae's t1"); the picker hides when nothing
/// matches.
MentionQuery? activeMentionQuery(TextEditingValue value) {
  final sel = value.selection;
  if (!sel.isValid || !sel.isCollapsed) return null;
  final text = value.text;
  final cursor = sel.baseOffset.clamp(0, text.length);
  if (cursor == 0) return null;
  final at = text.lastIndexOf('@', cursor - 1);
  if (at < 0) return null;
  if (at > 0 && !RegExp(r'\s').hasMatch(text[at - 1])) return null;
  final query = text.substring(at + 1, cursor);
  if (query.length > 32 || RegExp(r'[@\[\]\n]').hasMatch(query)) return null;
  return (start: at, query: query);
}

/// [names] (newest writer first) that match [query], ignoring case: those
/// whose name starts with it first, then those with it anywhere, each in the
/// order given. Every name for an empty query.
List<String> mentionMatches(List<String> names, String query) {
  final q = query.toLowerCase();
  if (q.isEmpty) return names;
  final starts = <String>[];
  final contains = <String>[];
  for (final name in names) {
    final n = name.toLowerCase();
    if (n.startsWith(q)) {
      starts.add(name);
    } else if (n.contains(q)) {
      contains.add(name);
    }
  }
  return [...starts, ...contains];
}

/// [value] with the mention at [mention] replaced by "@[name] ", the cursor
/// after it.
TextEditingValue applyMention(
  TextEditingValue value,
  MentionQuery mention,
  String name,
) {
  final text = value.text;
  final cursor = value.selection.baseOffset.clamp(0, text.length);
  final inserted = '@[$name] ';
  final rest = text.substring(cursor);
  final next =
      text.substring(0, mention.start) +
      inserted +
      (rest.startsWith(' ') ? rest.substring(1) : rest);
  return TextEditingValue(
    text: next,
    selection: TextSelection.collapsed(
      offset: mention.start + inserted.length,
    ),
  );
}

/// The list of matching names above the composer while an "@" is being
/// typed; nothing otherwise.
class MentionPicker extends StatelessWidget {
  final TextEditingController controller;

  /// Everyone who has written in the chat, newest first; asked each time the
  /// text changes, so someone who just wrote is there.
  final List<String> Function() names;

  /// The avatar for a name, as the chat draws it.
  final Widget Function(String name) avatarBuilder;

  const MentionPicker({
    super.key,
    required this.controller,
    required this.names,
    required this.avatarBuilder,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        final mention = activeMentionQuery(value);
        if (mention == null) return const SizedBox.shrink();
        final matches = mentionMatches(names(), mention.query);
        if (matches.isEmpty) return const SizedBox.shrink();
        final scheme = Theme.of(context).colorScheme;
        return Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
          child: Material(
            color: scheme.surfaceContainer,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: scheme.outlineVariant),
            ),
            clipBehavior: Clip.antiAlias,
            child: ConstrainedBox(
              // About eight names, then it scrolls.
              constraints: const BoxConstraints(maxHeight: 8 * 52.0),
              child: ListView.builder(
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                itemCount: matches.length,
                itemBuilder: (context, i) {
                  final name = matches[i];
                  return ListTile(
                    dense: true,
                    minVerticalPadding: 6,
                    leading: avatarBuilder(name),
                    title: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: scheme.onSurface, fontSize: 16),
                    ),
                    onTap: () =>
                        controller.value = applyMention(value, mention, name),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }
}
