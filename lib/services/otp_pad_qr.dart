// MeshCore Open TAK - a one-time pad as a series of QR codes.
//
// A pad of a few KB is too dense for one QR code (and far too dense for a
// T-Deck's small screen), so it is shown as parts, one after another:
//
//   OTPQR1:<i>:<n>:<CRC>:<HEX>
//
//   i     part number, 1..n
//   n     number of parts
//   CRC   CRC-32 (IEEE, as zlib) of the whole pad's bytes, 8 hex digits:
//         ties the parts to one pad and checks the reassembled result
//   HEX   this part's slice of the pad as uppercase hex
//
// Only digits, uppercase letters and ':' — QR alphanumeric mode. Wadamesh-tak
// writes the same format (src/ui-touch/PadQr.h, test/test_pad_qr.cpp; both
// tests check the same golden text). A plain hex QR — the older single-code
// form — is still read as a whole pad.

import 'dart:typed_data';

const String otpPadQrPrefix = 'OTPQR1';

/// Pad bytes per part when this app shows a large pad (phone screens carry
/// denser codes than a T-Deck can).
const int otpPadQrChunkBytes = 400;

final _hexRe = RegExp(r'^[0-9a-fA-F]+$');

int _crcByte(int crc, int b) {
  crc ^= b;
  for (var k = 0; k < 8; k++) {
    crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
  }
  return crc;
}

/// CRC-32 (IEEE) of the bytes a hex string spells.
int otpPadCrc32Hex(String hex) {
  var crc = 0xFFFFFFFF;
  for (var i = 0; i + 1 < hex.length; i += 2) {
    crc = _crcByte(crc, int.parse(hex.substring(i, i + 2), radix: 16));
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

int otpPadCrc32(Uint8List bytes) {
  var crc = 0xFFFFFFFF;
  for (final b in bytes) {
    crc = _crcByte(crc, b);
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

/// The QR texts that carry [padHex], [chunkBytes] pad bytes each.
List<String> otpPadQrParts(
  String padHex, {
  int chunkBytes = otpPadQrChunkBytes,
}) {
  final hex = padHex.toUpperCase();
  final crc = otpPadCrc32Hex(hex).toRadixString(16).toUpperCase().padLeft(8, '0');
  final step = chunkBytes * 2;
  final n = (hex.length + step - 1) ~/ step;
  return [
    for (var i = 0; i < n; i++)
      '$otpPadQrPrefix:${i + 1}:$n:$crc:'
          '${hex.substring(i * step, (i + 1) * step > hex.length ? hex.length : (i + 1) * step)}',
  ];
}

class OtpPadQrPart {
  final int index; // 1-based
  final int count;
  final int crc;
  final String hex;
  const OtpPadQrPart(this.index, this.count, this.crc, this.hex);

  static final _re = RegExp(
    '^$otpPadQrPrefix:(\\d{1,4}):(\\d{1,4}):([0-9A-Fa-f]{8}):([0-9A-Fa-f]+)\$',
  );

  static OtpPadQrPart? parse(String s) {
    final m = _re.firstMatch(s.trim());
    if (m == null) return null;
    final i = int.parse(m.group(1)!), n = int.parse(m.group(2)!);
    final hex = m.group(4)!;
    if (i < 1 || n < 1 || i > n || hex.length.isOdd) return null;
    return OtpPadQrPart(i, n, int.parse(m.group(3)!, radix: 16), hex);
  }
}

enum OtpPadQrScan {
  /// A new part (or the first of a new pad).
  added,

  /// A part already collected.
  repeat,

  /// The whole pad is in: see [OtpPadQrAssembler.result].
  complete,

  /// Not pad data.
  invalid,

  /// The parts didn't add up to their checksum; collecting starts over.
  corrupt,
}

/// Collects scanned parts until the pad is whole.
class OtpPadQrAssembler {
  int? _crc;
  int _count = 0;
  final Map<int, String> _parts = {};
  String? _result;

  int get have => _parts.length;
  int get count => _count;

  /// The pad as lowercase hex, once [add] has said [OtpPadQrScan.complete].
  String? get result => _result;

  /// Parts not yet seen, 1-based.
  List<int> get missing => [
    for (var i = 1; i <= _count; i++)
      if (!_parts.containsKey(i)) i,
  ];

  void reset() {
    _crc = null;
    _count = 0;
    _parts.clear();
    _result = null;
  }

  OtpPadQrScan add(String scanned) {
    final s = scanned.trim();
    if (_result != null) return OtpPadQrScan.complete;
    final part = OtpPadQrPart.parse(s);
    if (part == null) {
      // The older form: the whole pad as one plain hex code.
      final cleaned = s.replaceAll(RegExp(r'\s+'), '');
      if (cleaned.length >= 8 && cleaned.length.isEven && _hexRe.hasMatch(cleaned)) {
        _result = cleaned.toLowerCase();
        return OtpPadQrScan.complete;
      }
      return OtpPadQrScan.invalid;
    }
    // A part of another pad than the one being collected: start over with it.
    if (_crc != part.crc || _count != part.count) {
      reset();
      _crc = part.crc;
      _count = part.count;
    }
    if (_parts.containsKey(part.index)) return OtpPadQrScan.repeat;
    _parts[part.index] = part.hex.toUpperCase();
    if (_parts.length < _count) return OtpPadQrScan.added;
    final hex = [for (var i = 1; i <= _count; i++) _parts[i]!].join();
    if (otpPadCrc32Hex(hex) != _crc) {
      reset();
      return OtpPadQrScan.corrupt;
    }
    _result = hex.toLowerCase();
    return OtpPadQrScan.complete;
  }
}
