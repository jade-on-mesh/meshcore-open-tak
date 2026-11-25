import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/helpers/edit_helper.dart';

MessageEdit _edit(String before, String after) =>
    MessageEdit.between(targetHash: '3fa1', before: before, after: after)!;

void main() {
  group('between', () {
    test('sends the changed word with a word of context each side', () {
      final e = _edit(
        'ok see you at 5 tonight bye',
        'ok see you at 6 tonight bye',
      );
      expect(e.offset, 11);
      expect(e.deleteLength, 12);
      expect(e.replacement, 'at 6 tonight');
      expect(
        e.encode(27),
        '✎ …at 6 tonight…\ne:3fa1:${MessageEdit.checkOf('ok see you at 5 tonight bye')}:11:12',
      );
    });

    test('marks only the side where text is left out', () {
      expect(
        _edit('see you at 5 tonight', 'see you at 6 tonight').encode(20),
        startsWith('✎ …at 6 tonight\n'),
      );
      expect(_edit('teh cat', 'the cat').encode(7), startsWith('✎ the cat\n'));
    });

    test('nothing to send when unchanged or emptied', () {
      expect(
        MessageEdit.between(targetHash: '3fa1', before: 'hi', after: 'hi'),
        isNull,
      );
      expect(
        MessageEdit.between(targetHash: '3fa1', before: 'hi', after: '  '),
        isNull,
      );
    });
  });

  group('round trip', () {
    const cases = [
      ('see you at 5 tonight', 'see you at 6 tonight'),
      ('hello', 'hello there'),
      ('a b', 'a x b'),
      ('meet at the park', 'meet at the old park'),
      ('one two three', 'one three'),
      ('ok see you at 5 tonight bye', 'ok see you at 6 tonight bye'),
      ('line one\nline two', 'line one\nline 2'),
      ('héllo 👋 wörld', 'héllo 👋 world'),
      ('trailing  spaces ', 'trailing spaces'),
    ];
    for (final (before, after) in cases) {
      test('"$before" → "$after"', () {
        final wire = _edit(before, after).encode(before.length);
        final parsed = MessageEdit.parse(wire)!;
        expect(parsed.targetHash, '3fa1');
        expect(parsed.applyTo(before), after);
      });
    }
  });

  test('a second edit applies on top of the first', () {
    const v1 = 'see you at 5 tonight';
    const v2 = 'see you at 6 tonight';
    const v3 = 'see you at 6 tomorrow';
    final first = MessageEdit.parse(_edit(v1, v2).encode(v1.length))!;
    final second = MessageEdit.parse(_edit(v2, v3).encode(v2.length))!;
    expect(second.applyTo(first.applyTo(v1)!), v3);
    // Missing the first, the second refuses rather than garbling the text.
    expect(second.applyTo(v1), isNull);
  });

  test('a repeat of an applied edit is recognised', () {
    const before = 'see you at 5 tonight';
    const after = 'see you at 6 tonight';
    final e = MessageEdit.parse(_edit(before, after).encode(before.length))!;
    expect(e.applyTo(after), isNull);
    expect(e.alreadyIn(after), isTrue);
    expect(e.alreadyIn('something else entirely'), isFalse);
  });

  test('ordinary text is not an edit', () {
    for (final text in [
      'hello',
      '✎ just a pencil',
      '✎ two lines\nbut no tag',
      'e:3fa1:7c:1:2',
      '✎ x\ne:3fa1:7c:1',
      '✎ x\ne:XYZW:7c:1:2',
    ]) {
      expect(MessageEdit.parse(text), isNull, reason: text);
    }
  });

  test('an edit past the end of the text is refused', () {
    const e = MessageEdit(
      targetHash: '3fa1',
      baseCheck: '00',
      offset: 50,
      deleteLength: 3,
      replacement: '…x',
    );
    expect(e.applyTo('short'), isNull);
    expect(e.alreadyIn('short'), isFalse);
  });

  test('the window allows 15 minutes, receivers a little more', () {
    expect(messageEditWindow, const Duration(minutes: 15));
    expect(messageEditAcceptWindow > messageEditWindow, isTrue);
  });
}
