import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/widgets/channel_search.dart';

void main() {
  const base = TextStyle(fontSize: 14);
  const hit = TextStyle(fontWeight: FontWeight.bold);

  String marked(List<TextSpan> spans) =>
      spans.map((s) => identical(s.style, hit) ? '[${s.text}]' : s.text).join();

  test('every match is marked, ignoring case', () {
    expect(
      marked(
        channelSearchSpans(
          'Repeater on the ridge; REPEATER down',
          'repeater',
          base,
          hit,
        ),
      ),
      '[Repeater] on the ridge; [REPEATER] down',
    );
  });

  test('a match at the very start and end', () {
    expect(marked(channelSearchSpans('abcab', 'ab', base, hit)), '[ab]c[ab]');
  });

  test('no match, or an empty query: the text as it is', () {
    expect(marked(channelSearchSpans('hello', 'xyz', base, hit)), 'hello');
    expect(marked(channelSearchSpans('hello', '  ', base, hit)), 'hello');
  });

  test('the query is trimmed', () {
    expect(
      marked(channelSearchSpans('net check', ' check ', base, hit)),
      'net [check]',
    );
  });
}
