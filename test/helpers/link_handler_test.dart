import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/helpers/link_handler.dart';

bool obvious(String text, [String? url]) =>
    LinkHandler.isObviousWebLink(text, url ?? text);

void main() {
  test('full http/https links to ordinary names are obvious', () {
    expect(obvious('https://analyzer.cascadiamesh.org/#/map'), isTrue);
    expect(obvious('http://example.com/a?b=c'), isTrue);
    expect(obvious('HTTPS://Example.com'), isTrue);
    expect(obvious('https://my-site.co.uk/path'), isTrue);
  });

  test('anything that could hide where it goes still asks', () {
    // No scheme typed: linkify adds one, but the sender didn't write it.
    expect(obvious('example.com', 'http://example.com'), isFalse);
    // A user@ part ("google.com@evil.example" goes to evil.example).
    expect(obvious('https://google.com@evil.example/'), isFalse);
    // Punycode look-alikes and non-ASCII host names.
    expect(obvious('https://xn--pple-43d.com/'), isFalse);
    expect(obvious('https://аpple.com/'), isFalse);
    // No dot (a local name) and other schemes.
    expect(obvious('http://localhost:8080/'), isFalse);
    expect(obvious('mailto:someone@example.com'), isFalse);
    expect(obvious('ftp://example.com/file'), isFalse);
  });
}
