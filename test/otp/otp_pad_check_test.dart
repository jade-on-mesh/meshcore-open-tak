import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/otp_pad_check.dart';

// The same vectors as Wadamesh TAK's test/test_otp_pad_check.cpp: the radio
// and the app must give the same check code for the same pad.
void main() {
  Uint8List seq(int n, int Function(int) f) =>
      Uint8List.fromList(List.generate(n, (i) => f(i) & 255));

  test('matches the radio', () {
    expect(padCheckOfBytes(seq(256, (i) => i)).fingerprint, '73fcdbde9589d5a0');
    final p = padCheckOfBytes(seq(4096, (i) => i * 7 + 3));
    expect(p.fingerprint, 'a027f73305d4958f');
    expect(p.code, 'a027 f733 05d4 958f');
    expect(p.link, 'meshcore://otp/check?fp=a027f73305d4958f&n=4096');
  });

  test('any change gives another code', () {
    final pad = seq(4096, (i) => i * 7 + 3);
    final a = padCheckOfBytes(pad);
    pad[1000] ^= 1;
    expect(padCheckOfBytes(pad).sameAs(a), isFalse);
    pad[1000] ^= 1;
    expect(padCheckOfBytes(Uint8List.sublistView(pad, 0, 4095)).sameAs(a), isFalse);
  });

  test('hex and bytes agree', () {
    expect(padCheckOfHex('000102').fingerprint,
        padCheckOfBytes(Uint8List.fromList([0, 1, 2])).fingerprint);
  });

  test('reads links', () {
    final c = parsePadCheck('MESHCORE://otp/check?n=12&fp=A027F73305D4958F')!;
    expect(c.fingerprint, 'a027f73305d4958f');
    expect(c.length, 12);
    expect(parsePadCheck('meshcore://otp/check?fp=a027'), isNull);
    expect(parsePadCheck('meshcore://channel/add?fp=a027f73305d4958f'), isNull);
    expect(parsePadCheck('U:Jade|hello'), isNull);
  });
}
