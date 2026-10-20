import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/sound/wavest_format.dart';

void main() {
  // Made with Python's cryptography AESGCM, as Wavest's WebCrypto does it:
  // key SHA-256("mesh"), IV 00..0b, "hello mesh 🌲".
  const vector =
      'E:Jade|AES:AAECAwQFBgcICQoL0F2Mxz3x1NNXhFUv0mL8INKtS7ye7t16eEcjR5p45A==';

  test('plain messages', () async {
    expect(await wavestBuild('Jade|T:Deck', 'hi'), 'U:JadeTDeck|hi');
    final m = await wavestParse('U:Jade|hello | there');
    expect(m.sender, 'Jade');
    expect(m.text, 'hello | there');
    expect(m.encrypted, isFalse);
  });

  test('reads Wavest AES-GCM, and makes the same', () async {
    final m = await wavestParse(vector, passkey: 'mesh');
    expect(m.encrypted, isTrue);
    expect(m.readable, isTrue);
    expect(m.text, 'hello mesh 🌲');
    expect(
      await wavestBuild(
        'Jade',
        'hello mesh 🌲',
        passkey: 'mesh',
        iv: List<int>.generate(12, (i) => i),
      ),
      vector,
    );
  });

  test('wrong or missing key: shown as locked', () async {
    final m = await wavestParse(vector, passkey: 'nope');
    expect(m.readable, isFalse);
    expect((await wavestParse(vector)).readable, isFalse);
  });

  test('anything else is raw', () async {
    final m = await wavestParse('meshcore://channel/add?name=x&secret=00');
    expect(m.raw, isTrue);
    expect(m.text, startsWith('meshcore://'));
  });

  test('size limit', () async {
    expect(await wavestFits('Jade', 'x' * 100), isTrue);
    expect(await wavestFits('Jade', 'x' * 140), isFalse);
    expect(await wavestFits('Jade', 'x' * 60, passkey: 'k'), isTrue);
    expect(await wavestFits('Jade', 'x' * 90, passkey: 'k'), isFalse);
  });
}
