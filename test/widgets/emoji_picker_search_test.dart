import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/helpers/reaction_helper.dart';
import 'package:meshcore_open/widgets/emoji_keywords.dart';
import 'package:meshcore_open/widgets/emoji_picker.dart';

void main() {
  test('every picker emoji has search words', () {
    for (final e in EmojiPicker.classicEmojis) {
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

  test('the full set has bananas and pride flags', () {
    expect(EmojiPicker.search('banana'), contains('🍌'));
    expect(EmojiPicker.search('rainbow flag'), contains('🏳️‍🌈'));
    expect(EmojiPicker.search('transgender flag'), contains('🏳️‍⚧️'));
    // The classic set (images) has neither.
    expect(EmojiPicker.search('banana', classicOnly: true), isEmpty);
  });

  test('any emoji goes as a MeshCore One reaction and reads back', () {
    for (final emoji in ['🍌', '🏳️‍🌈', '🏳️‍⚧️', '🇺🇸', '#️⃣']) {
      final channel = ReactionHelper.parseReaction(
        ReactionHelper.encodeReactionMC1(
          emoji: emoji,
          timestampSecs: 1700000000,
          text: 'hello there',
          senderName: 'Jade',
        ),
      )!;
      expect(channel.emoji, emoji);
      expect(channel.hashType, HashType.mc1);
      final hash = ReactionHelper.computeReactionHashMC1(
        1700000000,
        'Jade',
        'hello there',
      );
      expect(channel.targetHash, '$hash:Jade');
      final dm = ReactionHelper.parseReaction(
        ReactionHelper.encodeReactionMC1(
          emoji: emoji,
          timestampSecs: 1700000000,
          text: 'hello there',
        ),
      )!;
      expect(dm.emoji, emoji);
      expect(dm.targetHash, '$hash:');
    }
  });

  test('every classic result can be sent as an indexed reaction', () {
    for (final q in ['face', 'hand', 'heart', 'ball']) {
      for (final e in EmojiPicker.search(q, classicOnly: true)) {
        expect(ReactionHelper.emojiToIndex(e), isNotNull, reason: e);
      }
    }
  });
}
