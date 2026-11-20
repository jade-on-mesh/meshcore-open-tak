import 'package:flutter_linkify/flutter_linkify.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/models/channel.dart';
import 'package:meshcore_open/widgets/hashtag_channel_join.dart';

List<String> tags(String text) => [
  for (final e in linkify(
    text,
    linkifiers: const [UrlLinkifier(), HashtagLinkifier()],
  ))
    if (e is LinkableElement && e.url.startsWith(hashtagLinkScheme)) e.text,
];

void main() {
  // Every expectation here is what Wadamesh TAK's ChatHashtag::span finds in
  // the same text, so phones and standalones make the same words tappable.
  test('hashtags in a message become links', () {
    expect(tags('I mean #mediamesh'), ['#mediamesh']);
    expect(tags('#icewatch and #FuckNazis!'), ['#icewatch', '#FuckNazis']);
    expect(tags('(#cascadia-mesh)'), ['#cascadia-mesh']);
    expect(tags('#abc123x'), ['#abc123x']);
    expect(tags('#Café time'), ['#Café']);
    expect(tags('end #tag-_ .'), ['#tag']);
    expect(tags('x-#dash'), ['#dash']);
    expect(tags('@[Bob #x] #real'), ['#real']);
    expect(tags('#a'), ['#a']);
    expect(tags('#${'a' * 30}'), ['#${'a' * 30}']);
  });

  test(
    'not a hashtag: numbers, colours, mid-word, URLs, doubles, too long',
    () {
      expect(tags('route #40'), isEmpty);
      expect(tags('color #FF8800 ok'), isEmpty);
      expect(tags('#1a2b3c ok'), isEmpty);
      expect(tags('Face #DEADBE'), isEmpty);
      expect(tags('abc#def'), isEmpty);
      expect(tags('see https://example.com/page#section'), isEmpty);
      expect(tags('##x'), isEmpty);
      expect(tags('#_no #-no'), isEmpty);
      expect(tags('#${'a' * 31}'), isEmpty);
      expect(tags('#tag😀'), isEmpty);
    },
  );

  test('a hashtag names its channel as Wadamesh does', () {
    expect(hashtagChannelName('MediaMesh'), '#mediamesh');
    expect(hashtagChannelName('#IceWatch'), '#icewatch');
    expect(hashtagChannelName('##Café'), '#café');
    expect(hashtagChannelName('#CAFÉ'), '#cafÉ');
    expect(
      Channel.derivePskFromHashtag(hashtagChannelName('#MediaMesh')),
      Channel.derivePskFromHashtag('#mediamesh'),
    );
  });
}
