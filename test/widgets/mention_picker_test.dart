import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/widgets/mention_picker.dart';

TextEditingValue typed(String text) => TextEditingValue(
  text: text,
  selection: TextSelection.collapsed(offset: text.length),
);

void main() {
  test('an @ being typed is found, with what follows it', () {
    expect(activeMentionQuery(typed('@')), (start: 0, query: ''));
    expect(activeMentionQuery(typed('@tae')), (start: 0, query: 'tae'));
    expect(activeMentionQuery(typed('hi @Tae\'s t1')), (
      start: 3,
      query: 'Tae\'s t1',
    ));
  });

  test('not a mention: mid-word, a finished @[name], or none', () {
    expect(activeMentionQuery(typed('mail@host')), isNull);
    expect(activeMentionQuery(typed('@[Bob] ')), isNull);
    expect(activeMentionQuery(typed('@[Bob')), isNull);
    expect(activeMentionQuery(typed('hello')), isNull);
    expect(activeMentionQuery(typed('')), isNull);
  });

  test('matches: names starting with it first, then anywhere, in order', () {
    final names = ['Bob', "Tae's Tag", 'Mittens', "tae's t-deck", 'Stae'];
    expect(mentionMatches(names, 'tae'), ["Tae's Tag", "tae's t-deck", 'Stae']);
    expect(mentionMatches(names, ''), names);
    expect(mentionMatches(names, 'zzz'), isEmpty);
  });

  test('picking a name puts @[name] and a space in, cursor after', () {
    final v = typed('hey @ta');
    final m = activeMentionQuery(v)!;
    final out = applyMention(v, m, "Tae's T114 v5");
    expect(out.text, "hey @[Tae's T114 v5] ");
    expect(out.selection.baseOffset, out.text.length);

    // Mid-text: the rest stays, without a doubled space.
    const text = 'yo @b how are you';
    final mid = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: 5),
    );
    final out2 = applyMention(mid, activeMentionQuery(mid)!, 'Bob');
    expect(out2.text, 'yo @[Bob] how are you');
  });
}
