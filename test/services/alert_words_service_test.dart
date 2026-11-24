import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/alert_words_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

String? first(String text, List<String> words) =>
    matchIn(text, alertPattern(words), words);

void main() {
  group('matching', () {
    test('whole words, any capitals', () {
      expect(first('ICE vehicles near Rainier', ['ice']), 'ice');
      expect(first('Ice, two vans', ['ICE']), 'ICE');
      expect(first('nice weather', ['ice']), isNull);
      expect(first('icecream truck', ['ice']), isNull);
      expect(first('ice2 is a node', ['ice']), isNull);
    });

    test('a phrase matches as written, any spacing between its words', () {
      expect(
        first('two unmarked  vans heading north', ['unmarked vans']),
        'unmarked vans',
      );
      expect(first('vans unmarked', ['unmarked vans']), isNull);
    });

    test('punctuation in a word is literal', () {
      expect(first('meet at 5th & Main', ['5th & main']), '5th & main');
      expect(first('a.b.c', ['a.b']), 'a.b'); // "." after it isn't a letter
      expect(first('a.bc', ['a.b']), isNull); // "c" after it is
      expect(first('price is \$5 now', [r'$5']), r'$5');
    });

    test('non-Latin letters count as word characters', () {
      expect(first('Привет мир', ['мир']), 'мир');
      expect(first('Привет мирный', ['мир']), isNull);
    });

    test('the longest of overlapping words wins, in the list spelling', () {
      expect(first('Checkpoint ahead', ['check', 'Checkpoint']), 'Checkpoint');
    });

    test('nothing to match', () {
      expect(matchIn('anything', null, const []), isNull);
      expect(first('', ['ice']), isNull);
    });
  });

  group('AlertWordsService', () {
    final alerts = AlertWordsService.instance;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      alerts.resetForTest();
      await alerts.load();
    });

    test(
      'a channel gets its own words then the global ones, each once',
      () async {
        await alerts.addGlobal('help');
        await alerts.addGlobal('ICE');
        await alerts.addChannel('#icewatch', 'ice');
        await alerts.addChannel('#icewatch', 'raid');
        expect(alerts.wordsFor('#icewatch'), ['ice', 'raid', 'help']);
        expect(alerts.wordsFor('#other'), ['help', 'ICE']);

        await alerts.setUsesGlobal('#icewatch', false);
        expect(alerts.wordsFor('#icewatch'), ['ice', 'raid']);
        expect(alerts.usesGlobal('#other'), isTrue);
      },
    );

    test(
      'adding trims, ignores repeats and empties, and caps the list',
      () async {
        expect(await alerts.addGlobal('  two   words '), isTrue);
        expect(alerts.globalWords, ['two words']);
        expect(await alerts.addGlobal('TWO WORDS'), isFalse);
        expect(await alerts.addGlobal('   '), isFalse);
        for (var i = 0; i < AlertWordsService.maxWords; i++) {
          await alerts.addGlobal('w$i');
        }
        expect(alerts.globalWords, hasLength(AlertWordsService.maxWords));
        expect(await alerts.addGlobal('one more'), isFalse);
      },
    );

    test('removing and clearing', () async {
      await alerts.addChannel('#a', 'x');
      await alerts.addChannel('#a', 'y');
      await alerts.removeChannel('#a', 'X');
      expect(alerts.channelWords('#a'), ['y']);
      await alerts.clearChannel('#a');
      expect(alerts.channelWords('#a'), isEmpty);
      expect(alerts.any, isFalse);
    });

    test('survives a reload', () async {
      await alerts.addGlobal('help');
      await alerts.addChannel('#a', 'raid');
      await alerts.setUsesGlobal('#a', false);
      await alerts.setNotify(false);
      alerts.resetForTest();
      await alerts.load();
      expect(alerts.globalWords, ['help']);
      expect(alerts.channelWords('#a'), ['raid']);
      expect(alerts.usesGlobal('#a'), isFalse);
      expect(alerts.notify, isFalse);
    });

    test('firstMatch uses the channel list', () async {
      await alerts.addChannel('#a', 'raid');
      final words = alerts.wordsFor('#a');
      expect(alerts.firstMatch('Possible RAID at 3rd', words), 'raid');
      expect(alerts.firstMatch('nothing here', words), isNull);
    });
  });
}
