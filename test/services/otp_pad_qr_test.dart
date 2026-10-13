import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/otp_pad_qr.dart';

void main() {
  // The same golden text Wadamesh-tak's test/test_pad_qr.cpp checks: bytes
  // 00..13 in parts of 8 bytes.
  const hex = '000102030405060708090a0b0c0d0e0f10111213';
  const golden = [
    'OTPQR1:1:3:3BDDFFA4:0001020304050607',
    'OTPQR1:2:3:3BDDFFA4:08090A0B0C0D0E0F',
    'OTPQR1:3:3:3BDDFFA4:10111213',
  ];

  test('crc32 matches zlib', () {
    expect(otpPadCrc32Hex(hex), 0x3BDDFFA4);
    expect(otpPadCrc32(Uint8List.fromList(List.generate(20, (i) => i))), 0x3BDDFFA4);
  });

  test('writes the golden parts', () {
    expect(otpPadQrParts(hex, chunkBytes: 8), golden);
  });

  test('reads parts in any order, with repeats', () {
    final a = OtpPadQrAssembler();
    expect(a.add(golden[2]), OtpPadQrScan.added);
    expect(a.add(golden[2]), OtpPadQrScan.repeat);
    expect(a.have, 1);
    expect(a.count, 3);
    expect(a.missing, [1, 2]);
    expect(a.add(golden[0]), OtpPadQrScan.added);
    expect(a.add(golden[1]), OtpPadQrScan.complete);
    expect(a.result, hex);
  });

  test('takes a plain hex code as the whole pad', () {
    final a = OtpPadQrAssembler();
    expect(a.add('00010203ABCD'), OtpPadQrScan.complete);
    expect(a.result, '00010203abcd');
    expect(OtpPadQrAssembler().add('hello'), OtpPadQrScan.invalid);
    expect(OtpPadQrAssembler().add('OTPQR1:4:3:3BDDFFA4:10'), OtpPadQrScan.invalid);
  });

  test('a part of another pad starts over', () {
    final a = OtpPadQrAssembler();
    a.add(golden[0]);
    expect(a.add('OTPQR1:1:2:00000001:AABB'), OtpPadQrScan.added);
    expect(a.count, 2);
    expect(a.have, 1);
  });

  test('a bad checksum starts over', () {
    final a = OtpPadQrAssembler();
    a.add('OTPQR1:1:2:3BDDFFA4:0001020304050607');
    expect(a.add('OTPQR1:2:2:3BDDFFA4:08090A0B0C0D0E0F'), OtpPadQrScan.corrupt);
    expect(a.have, 0);
  });

  test('round trip of a large pad', () {
    final sb = StringBuffer();
    for (var k = 0; k < 8200; k++) {
      sb.write(((k * 37 + 11) & 0xFF).toRadixString(16).padLeft(2, '0'));
    }
    final pad = sb.toString();
    final parts = otpPadQrParts(pad);
    expect(parts.length, 21);
    expect(parts.every((p) => RegExp(r'^[0-9A-Z:]+$').hasMatch(p)), isTrue);
    final a = OtpPadQrAssembler();
    var last = OtpPadQrScan.invalid;
    for (final p in parts.reversed) {
      last = a.add(p);
    }
    expect(last, OtpPadQrScan.complete);
    expect(a.result, pad);
  });
}
