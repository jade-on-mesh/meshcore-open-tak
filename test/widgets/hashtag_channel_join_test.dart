import 'package:flutter_linkify/flutter_linkify.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/widgets/hashtag_channel_join.dart';

List<String> tags(String text) => [
  for (final e in linkify(text, linkifiers: const [
    UrlLinkifier(),
    HashtagLinkifier(),
  ]))
    if (e is LinkableElement && e.url.startsWith(hashtagLinkScheme)) e.text,
];

void main() {
  test('hashtags in a message become links', () {
    expect(tags('I mean #mediamesh'), ['#mediamesh']);
    expect(tags('#icewatch and #FuckNazis!'), ['#icewatch', '#FuckNazis']);
    expect(tags('(#cascadia-mesh)'), ['#cascadia-mesh']);
  });

  test('not a hashtag: numbers, mid-word, URL fragments, doubles', () {
    expect(tags('route #40'), isEmpty);
    expect(tags('abc#def'), isEmpty);
    expect(tags('see https://example.com/page#section'), isEmpty);
    expect(tags('##x'), isEmpty);
  });

  test('a hashtag names its channel in lowercase', () {
    expect(hashtagChannelName('MediaMesh'), '#mediamesh');
    expect(hashtagChannelName('#IceWatch'), '#icewatch');
  });
}
