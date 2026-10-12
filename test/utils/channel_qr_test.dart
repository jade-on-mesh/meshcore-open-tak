import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/utils/channel_qr.dart';

void main() {
  const secret = '0123456789abcdef0123456789ABCDEF';

  test('link round-trips name and secret', () {
    final link = channelShareLink('Ops team #2 & co', secret)!;
    expect(link, startsWith('meshcore://channel/add?'));
    final ch = parseChannelQr(link)!;
    expect(ch.name, 'Ops team #2 & co');
    expect(ch.secretHex, secret.toLowerCase());
  });

  test('accepts spaced hex when building', () {
    expect(
      channelShareLink('a', '0123 4567 89ab cdef 0123 4567 89ab cdef'),
      isNotNull,
    );
  });

  test('rejects bad secrets and other links', () {
    expect(channelShareLink('a', 'abcd'), isNull);
    expect(parseChannelQr('meshcore://channel/add?name=a&secret=abcd'), isNull);
    expect(parseChannelQr('meshcore://contact/add?public_key=$secret'), isNull);
    expect(parseChannelQr('https://example.com'), isNull);
    expect(parseChannelQr(''), isNull);
  });
}
