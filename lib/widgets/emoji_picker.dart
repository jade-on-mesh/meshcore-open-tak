import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../l10n/l10n.dart';
import '../theme/mesh_theme.dart';
import 'emoji_keywords.dart';

class EmojiPicker extends StatefulWidget {
  final Function(String) onEmojiSelected;

  const EmojiPicker({super.key, required this.onEmojiSelected});

  /// Every emoji the picker offers, once each, in picker order.
  static List<String> get allEmojis => <String>{
    ...quickEmojis,
    ...smileys,
    ...gestures,
    ...hearts,
    ...objects,
  }.toList();

  /// The picker's emoji whose name or keywords match [query]: every word of
  /// it starts a word of theirs. Ones whose name starts with it come first.
  static List<String> search(String query) {
    final words = query
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) return const <String>[];
    final first = <String>[];
    final rest = <String>[];
    for (final emoji in allEmojis) {
      if (emoji == query.trim()) {
        first.add(emoji);
        continue;
      }
      final keywords = emojiKeywords[emoji];
      if (keywords == null) continue;
      final theirs = keywords.split(' ');
      final all = words.every(
        (w) => theirs.any((k) => k.startsWith(w)),
      );
      if (!all) continue;
      (keywords.startsWith(words.first) ? first : rest).add(emoji);
    }
    return [...first, ...rest];
  }

  @override
  State<EmojiPicker> createState() => _EmojiPickerState();

  static const List<String> quickEmojis = ['👍', '❤️', '😂', '🎉', '👏', '🔥'];

  static const List<String> smileys = [
    '😀',
    '😃',
    '😄',
    '😁',
    '😅',
    '😂',
    '🤣',
    '😊',
    '😇',
    '🙂',
    '🙃',
    '😉',
    '😌',
    '😍',
    '🥰',
    '😘',
    '😗',
    '😙',
    '😚',
    '😋',
    '😛',
    '😝',
    '😜',
    '🤪',
    '🤨',
    '🧐',
    '🤓',
    '😎',
    '🥸',
    '🤩',
    '🥳',
    '😏',
    '😒',
    '😞',
    '😔',
    '😟',
    '😕',
    '🙁',
    '😣',
    '😖',
    '😫',
    '😩',
    '🥺',
    '😢',
    '😭',
    '😤',
    '😠',
    '😡',
    '🤬',
    '🤯',
    '😳',
    '🥵',
    '🥶',
    '😱',
    '😨',
    '😰',
    '😥',
    '😓',
    '🤗',
    '🤔',
    '🤭',
    '🤫',
    '🤥',
    '😶',
  ];
  static const List<String> gestures = [
    '👍',
    '👎',
    '👊',
    '✊',
    '🤛',
    '🤜',
    '🤞',
    '✌️',
    '🤟',
    '🤘',
    '👌',
    '🤌',
    '🤏',
    '👈',
    '👉',
    '👆',
    '👇',
    '☝️',
    '👋',
    '🤚',
    '🖐️',
    '✋',
    '🖖',
    '👏',
    '🙌',
    '👐',
    '🤲',
    '🤝',
    '🙏',
    '✍️',
    '💅',
    '🤳',
    '💪',
  ];
  static const List<String> hearts = [
    '❤️',
    '🧡',
    '💛',
    '💚',
    '💙',
    '💜',
    '🖤',
    '🤍',
    '🤎',
    '💔',
    '❤️‍🔥',
    '❤️‍🩹',
    '💕',
    '💞',
    '💓',
    '💗',
    '💖',
    '💘',
    '💝',
    '💟',
    '💌',
    '💢',
    '💥',
    '💫',
    '💦',
    '💨',
    '🕳️',
    '💬',
    '👁️‍🗨️',
    '🗨️',
    '🗯️',
    '💭',
  ];
  static const List<String> objects = [
    '🎉',
    '🎊',
    '🎈',
    '🎁',
    '🎀',
    '🪅',
    '🪆',
    '🏆',
    '🥇',
    '🥈',
    '🥉',
    '⚽',
    '⚾',
    '🥎',
    '🏀',
    '🏐',
    '🏈',
    '🏉',
    '🎾',
    '🥏',
    '🎳',
    '🏏',
    '🏑',
    '🏒',
    '🥍',
    '🏓',
    '🏸',
    '🥊',
    '🥋',
    '🥅',
    '⛳',
    '🔥',
    '⭐',
    '🌟',
    '✨',
    '⚡',
    '💡',
    '🔦',
    '🏮',
    '🪔',
    '📱',
    '💻',
    '⌚',
    '📷',
    '📺',
    '📻',
    '🎵',
    '🎶',
    '🚀',
  ];

}

class _EmojiPickerState extends State<EmojiPicker> {
  final TextEditingController _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Map<String, List<String>> _emojiCategories(AppLocalizations l10n) {
    return {
      l10n.emojiCategorySmileys: EmojiPicker.smileys,
      l10n.emojiCategoryGestures: EmojiPicker.gestures,
      l10n.emojiCategoryHearts: EmojiPicker.hearts,
      l10n.emojiCategoryObjects: EmojiPicker.objects,
    };
  }

  void _pick(String emoji) {
    widget.onEmojiSelected(emoji);
    Navigator.pop(context);
  }

  Widget _grid(List<String> emojis) => GridView.builder(
    padding: const EdgeInsets.all(8),
    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: 8,
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
    ),
    itemCount: emojis.length,
    itemBuilder: (context, index) => InkWell(
      onTap: () => _pick(emojis[index]),
      child: Center(
        child: Text(
          emojis[index],
          style: MeshTheme.emoji(),
          textHeightBehavior: const TextHeightBehavior(
            applyHeightToFirstAscent: false,
            applyHeightToLastDescent: false,
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final emojiCategories = _emojiCategories(l10n);
    final searching = _query.trim().isNotEmpty;
    final results = searching
        ? EmojiPicker.search(_query)
        : const <String>[];
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.5,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  l10n.chat_addReaction,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: l10n.common_close,
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Wrap(
              spacing: 12,
              children: EmojiPicker.quickEmojis
                  .map(
                    (emoji) => InkWell(
                      onTap: () => _pick(emoji),
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Theme.of(
                            context,
                          ).colorScheme.secondaryContainer,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          emoji,
                          style: MeshTheme.emoji(),
                          textHeightBehavior: const TextHeightBehavior(
                            applyHeightToFirstAscent: false,
                            applyHeightToLastDescent: false,
                          ),
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: TextField(
              controller: _search,
              onChanged: (v) => setState(() => _query = v),
              textInputAction: TextInputAction.search,
              onSubmitted: (_) {
                if (results.isNotEmpty) _pick(results.first);
              },
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search),
                hintText: l10n.emojiSearch_hint,
                border: const OutlineInputBorder(),
                suffixIcon: searching
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        tooltip: l10n.common_close,
                        onPressed: () {
                          _search.clear();
                          setState(() => _query = '');
                        },
                      )
                    : null,
              ),
            ),
          ),
          const Divider(),
          if (searching)
            Expanded(
              child: results.isEmpty
                  ? Center(child: Text(l10n.emojiSearch_none))
                  : _grid(results),
            )
          else
          Expanded(
            child: DefaultTabController(
              length: emojiCategories.length,
              child: Column(
                children: [
                  TabBar(
                    isScrollable: true,
                    tabs: emojiCategories.keys
                        .map((cat) => Tab(text: cat))
                        .toList(),
                  ),
                  Expanded(
                    child: TabBarView(
                      children: emojiCategories.values.map(_grid).toList(),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
