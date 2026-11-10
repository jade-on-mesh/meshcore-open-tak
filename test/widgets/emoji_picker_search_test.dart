import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/helpers/reaction_helper.dart';
import 'package:meshcore_open/widgets/emoji_keywords.dart';
import 'package:meshcore_open/widgets/emoji_picker.dart';

void main() {
  test('every picker emoji has search words', () {
    for (final e in EmojiPicker.allEmojis) {
      expect(emojiKeywords[e], isNotNull, reason: e);
    }
  });

  test('search finds by name and keyword', () {
    expect(EmojiPicker.search('thumb').first, '👍');
    expect(EmojiPicker.search('fire'), contains('🔥'));
    expect(EmojiPicker.search('red heart'), contains('❤️'));
    expect(EmojiPicker.search('lol'), contains('😂'));
    expect(EmojiPicker.search('  '), isEmpty);
    expect(EmojiPicker.search('zzqx'), isEmpty);
  });

  test('every result can be sent as a reaction', () {
    for (final q in ['face', 'hand', 'heart', 'ball']) {
      for (final e in EmojiPicker.search(q)) {
        expect(ReactionHelper.emojiToIndex(e), isNotNull, reason: e);
      }
    }
  });
}
