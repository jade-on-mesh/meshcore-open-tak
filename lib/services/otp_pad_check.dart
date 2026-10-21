// MeshCore Open TAK - a one-time pad's check code. Two devices whose codes
// match hold the same pad, so a QR transfer can be confirmed (and a missing or
// garbled part caught) before the pad is used. The code is the first 8 bytes
// of SHA-256 over a fixed label and the WHOLE pad: it holds after the pad is
// in use, and reveals nothing usable about it, so it can be read out or played
// by sound:
//
//   meshcore://otp/check?fp=<16 hex>&n=<pad bytes>
//
// Wadamesh TAK computes the same (src/ui-touch/OtpCore.cpp, padFingerprint;
// test/test_otp_pad_check.cpp has the same vectors as the tests here). The pad
// itself is never sent by sound: anyone in earshot could record it.

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../connector/meshcore_protocol.dart' show hex2Uint8List;

const String _label = 'MeshCore OTP pad check v1\n';

class PadCheck {
  /// 16 lowercase hex characters.
  final String fingerprint;

  /// Pad length in bytes (0 when the code didn't say).
  final int length;

  const PadCheck(this.fingerprint, this.length);

  /// "a027 f733 05d4 958f", to read out.
  String get code => [
    for (var i = 0; i < 16; i += 4) fingerprint.substring(i, i + 4),
  ].join(' ');

  String get link => 'meshcore://otp/check?fp=$fingerprint&n=$length';

  bool sameAs(PadCheck other) => fingerprint == other.fingerprint;
}

PadCheck padCheckOfBytes(Uint8List pad) {
  final digest = sha256.convert([...utf8.encode(_label), ...pad]);
  final hex = digest.bytes
      .take(8)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  return PadCheck(hex, pad.length);
}

PadCheck padCheckOfHex(String padHex) => padCheckOfBytes(hex2Uint8List(padHex));

final RegExp _fp = RegExp(r'^[0-9a-fA-F]{16}$');

/// The check code in a heard or pasted link, or null.
PadCheck? parsePadCheck(String text) {
  final uri = Uri.tryParse(text.trim());
  if (uri == null || uri.scheme.toLowerCase() != 'meshcore') return null;
  final path = '${uri.host}${uri.path}'.toLowerCase().replaceAll(
    RegExp(r'^/+|/+$'),
    '',
  );
  if (path != 'otp/check') return null;
  final fp = uri.queryParameters['fp'] ?? '';
  if (!_fp.hasMatch(fp)) return null;
  return PadCheck(fp.toLowerCase(), int.tryParse(uri.queryParameters['n'] ?? '') ?? 0);
}
