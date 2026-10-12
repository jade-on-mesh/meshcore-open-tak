import 'dart:convert';
import 'dart:typed_data';

import '../connector/meshcore_protocol.dart'
    show
        hex2Uint8List,
        maxContactMessageBytes,
        maxChannelMessageBytes;

/// Thrown when a message can't be OTP-encrypted because the sender's half
/// of the shared pad doesn't have enough unused bytes left to cover it.
///
/// This must always fail CLOSED: callers must never fall back to sending
/// plaintext when this is thrown. A user who has enabled OTP for a contact
/// or channel is trusting that nothing goes out unencrypted.
class OtpPadExhaustedException implements Exception {
  final int neededBytes;
  final int availableBytes;

  OtpPadExhaustedException({
    required this.neededBytes,
    required this.availableBytes,
  });

  @override
  String toString() =>
      'OtpPadExhaustedException: need $neededBytes bytes, only '
      '$availableBytes left in this pad';
}

/// Thrown when a received OTP payload can't be decrypted — the hex was
/// malformed, or the pad's remaining bytes ran out.
class OtpDecryptException implements Exception {
  final String message;
  OtpDecryptException(this.message);

  @override
  String toString() => 'OtpDecryptException: $message';
}

/// Thrown when a contact's pad is about to be replaced while store-and-
/// forward still has messages queued for them. Importing a new pad resets
/// both offsets to zero (see setContactOtpPad's own doc comment), which
/// would silently corrupt or desync any ciphertext already queued against
/// the OLD pad's byte offsets - mirrors OTP_3_RC1.lua's import_pad_hex
/// refusing while `waiting_queue[id]` is non-empty.
class OtpPadImportBlockedException implements Exception {
  final int queuedCount;
  OtpPadImportBlockedException(this.queuedCount);

  @override
  String toString() =>
      'OtpPadImportBlockedException: $queuedCount message(s) still queued '
      'for store-and-forward - cancel or wait for them to send first';
}

/// Thrown when an OTP pad import is attempted for the Public channel.
///
/// The Public channel is the one channel everyone on the mesh shares by
/// construction (a fixed, well-known PSK - see [Channel.publicChannelPsk]),
/// so it's meant to stay in the clear for anyone listening; "encrypting"
/// it with a pad only two people actually hold would give a false sense of
/// privacy to everyone else still reading it in plain text, and there's no
/// way to agree a shared secret with "everyone on the mesh" in the first
/// place. Refused unconditionally - there's no override.
class OtpPublicChannelBlockedException implements Exception {
  @override
  String toString() =>
      'OtpPublicChannelBlockedException: OTP is not available for the '
      'Public channel';
}

/// Pure one-time-pad encrypt/decrypt for MeshCore Open text messages.
///
/// This is a direct port of the XOR core proved out on real hardware in the
/// WADAMESH Lua OTP messenger (OTP_2_RC15.lua), adapted to this app's
/// transport constraints:
///
/// - The companion BLE text pipe is NOT byte-safe. `BufferWriter.writeString`
///   UTF-8-encodes its input and `BufferReader.readCString` stops dead at the
///   first 0x00 byte. Raw XOR ciphertext is uniformly random — it contains
///   0x00 bytes constantly and is not valid UTF-8 — so ciphertext is always
///   carried as lowercase hex, never as raw bytes, inside a `String`.
/// - Wire compatibility with the Lua app: outgoing OTP payloads are BARE
///   lowercase hex with no marker/prefix of any kind — this matches exactly
///   what `wada.mesh.send_dm`/`wada.mesh.send` puts on the air in the Lua
///   app. There used to be a "OTP1|" marker prefix here; it has been
///   removed because Lua never sends or expects one, and a marker Flutter
///   invented on its own breaks interop with real Lua devices.
///
///   Because there's no marker, incoming-message recognition instead relies
///   on (a) OTP being enabled for the specific contact/channel the message
///   came from, and (b) the message actually looking like ciphertext hex —
///   see [extractCiphertextHex], a direct port of the Lua receiver's own
///   hex-recognition/trailing-hex-tail fallback logic.
class OtpService {
  OtpService._();

  /// Overall safety cap on how much pad this app will hold for one contact
  /// or channel, matching Lua's `MAX_TOTAL_PAD_BYTES` (`OTP_3_RC1.lua`) —
  /// raised from 1700 to 8200 bytes so a full-capacity pad can be imported
  /// (via paste or file) in one operation rather than needing several
  /// top-ups. This is a safety/UX guard, not a wire-format limit — nothing
  /// stops two devices from agreeing on a bigger pad by other means, but
  /// this app won't generate, import, or warn-free-ly hold more than this
  /// per target.
  static const int maxTotalPadBytes = 8200;

  /// The largest pad this app will render as a single QR code, rather than
  /// producing a code too dense to reliably encode or scan. A standard QR
  /// symbol (version 40, the largest defined size) in alphanumeric mode at
  /// error-correction level M holds 3391 characters — hex text uppercased
  /// before encoding (see otp_pad_screen.dart's `_showPadQr`) qualifies for
  /// alphanumeric mode (QR's alphanumeric charset is digits, uppercase
  /// A-F, and a few symbols — exactly what uppercased hex is), roughly
  /// doubling capacity versus the byte-mode encoding a mixed-case string
  /// would force. 3391 characters is 1695 pad bytes; this is rounded down
  /// to a slightly more conservative 1700 bytes both as headroom against
  /// real-world scan reliability at that density (a version-40 symbol is
  /// very fine-grained for a phone camera) and because it matches this
  /// project's own pre-existing 1700-byte pad size from before the cap was
  /// raised — a size already known to work as a single QR code in
  /// practice. A pad larger than this should be shared by pasting the hex
  /// or transferring the file directly instead of via QR.
  static const int maxQrShareablePadBytes = 1700;

  /// Encrypts [plaintext] against [keyBytes] (a slice already carved out of
  /// the sender's pad, exactly [utf8.encode(plaintext).length] bytes long)
  /// and returns the bare lowercase-hex wire payload (no marker).
  ///
  /// Throws [OtpPadExhaustedException] if [keyBytes] is shorter than the
  /// plaintext requires — callers should check [plaintextByteLength] against
  /// remaining pad bytes *before* calling this, but this is the final,
  /// authoritative guard.
  static String encrypt(String plaintext, Uint8List keyBytes) {
    final plainBytes = Uint8List.fromList(utf8.encode(plaintext));
    final cipherBytes = encryptBytes(plainBytes, keyBytes);
    return bytesToHex(cipherBytes);
  }

  /// Byte-level XOR encrypt. Used directly by the single-shot [encrypt]
  /// above and by the chunk-framing code in otp_chunk_service.dart, which
  /// needs to encrypt a raw framed byte buffer (marker + header + chunk
  /// data) rather than a UTF-8 Dart [String] — chunk data is a byte slice
  /// that may not be valid UTF-8 on its own if a multi-byte codepoint was
  /// split across a chunk boundary, so it must never round-trip through
  /// `String`/`utf8.encode` again.
  static Uint8List encryptBytes(Uint8List plainBytes, Uint8List keyBytes) {
    if (keyBytes.length < plainBytes.length) {
      throw OtpPadExhaustedException(
        neededBytes: plainBytes.length,
        availableBytes: keyBytes.length,
      );
    }
    final cipherBytes = Uint8List(plainBytes.length);
    for (var i = 0; i < plainBytes.length; i++) {
      cipherBytes[i] = plainBytes[i] ^ keyBytes[i];
    }
    return cipherBytes;
  }

  /// Decrypts a bare hex ciphertext payload against [keyBytes] and returns
  /// the plaintext as a `String` (UTF-8 decoded, malformed sequences
  /// replaced rather than thrown). For single-shot messages only — chunk
  /// reassembly must stay at the byte level until all chunks are joined,
  /// so it uses [decryptBytesFromHex] directly instead of this.
  ///
  /// Throws [OtpDecryptException] if the hex is malformed or there isn't
  /// enough pad left (the latter usually means the two sides' pad offsets
  /// have drifted out of sync, e.g. from a dropped message).
  static String decrypt(String hex, Uint8List keyBytes) {
    final plainBytes = decryptBytesFromHex(hex, keyBytes);
    return utf8.decode(plainBytes, allowMalformed: true);
  }

  /// Byte-level decrypt from a hex ciphertext string. Returns the raw
  /// plaintext bytes without any UTF-8 interpretation, so callers can check
  /// for the binary chunk/ack markers (see otp_chunk_service.dart) before
  /// deciding whether this is even meant to be decoded as text at all.
  static Uint8List decryptBytesFromHex(String hex, Uint8List keyBytes) {
    Uint8List cipherBytes;
    try {
      cipherBytes = hex2Uint8List(hex);
    } catch (e) {
      throw OtpDecryptException('malformed ciphertext hex: $e');
    }
    if (keyBytes.length < cipherBytes.length) {
      throw OtpDecryptException(
        'not enough pad left to decrypt (need ${cipherBytes.length} '
        'bytes, have ${keyBytes.length}) — pad offsets may be out of sync',
      );
    }
    final plainBytes = Uint8List(cipherBytes.length);
    for (var i = 0; i < cipherBytes.length; i++) {
      plainBytes[i] = cipherBytes[i] ^ keyBytes[i];
    }
    return plainBytes;
  }

  /// Lua-compatible ciphertext recognition (OTP_2_RC15.lua's receive-side
  /// hex detection). [text] here is whatever this app has already extracted
  /// as "the message body" for the contact/channel in question — this app,
  /// unlike Lua, already splits a firmware "SenderName: text" combined
  /// string into separate sender/text fields upstream of OTP handling (see
  /// ChannelMessage.fromFrame / _splitSenderText in meshcore_connector.dart),
  /// so that part of Lua's logic doesn't need porting here — only the hex
  /// recognition itself does:
  ///
  ///   - If [text] is itself pure lowercase-or-uppercase hex of even
  ///     length, it's returned as-is.
  ///   - Otherwise, Lua falls back to the longest trailing run of hex
  ///     characters at the end of the string (covering cases like firmware
  ///     or intermediate transforms prepending non-hex noise). If that
  ///     trailing run is empty or odd-length, this isn't OTP at all.
  ///
  /// Returns null if [text] doesn't look like ciphertext by either rule —
  /// callers should leave the message exactly as received in that case.
  static String? extractCiphertextHex(String text) {
    if (_isPureHex(text)) return text;
    final match = RegExp(r'[0-9a-fA-F]+$').firstMatch(text);
    final tail = match?.group(0);
    if (tail == null || tail.isEmpty || tail.length % 2 != 0) return null;
    return tail;
  }

  /// True if [text] is non-empty, entirely hex digits, and an even length —
  /// i.e. could be interpreted as N encoded bytes. Used both for incoming
  /// ciphertext recognition ([extractCiphertextHex]) and, in the connector,
  /// to decide whether an outgoing payload IS already-computed ciphertext
  /// (so Smaz/Cyr2Lat must not touch it) versus real plaintext that simply
  /// happens to look hex-ish.
  static bool looksLikeCiphertextHex(String text) => _isPureHex(text);

  static bool _isPureHex(String text) =>
      text.isNotEmpty &&
      text.length % 2 == 0 &&
      RegExp(r'^[0-9a-fA-F]+$').hasMatch(text);

  /// How many plaintext UTF-8 bytes a message to [text] would need, i.e.
  /// how many pad bytes encrypting it will consume.
  static int plaintextByteLength(String text) => utf8.encode(text).length;

  /// Max plaintext bytes that fit in one single-packet OTP-encrypted
  /// contact message, after doubling for hex encoding. Longer messages are
  /// sent as multiple chunks — see otp_chunk_service.dart.
  static int maxPlaintextBytesForContact() {
    final budget = maxContactMessageBytes();
    if (budget <= 0) return 0;
    return budget ~/ 2;
  }

  /// Max plaintext bytes that fit in one single-packet OTP-encrypted
  /// channel message, after reserving space for the "<name>: " prefix the
  /// firmware adds and doubling for hex encoding.
  static int maxPlaintextBytesForChannel(String? senderName) {
    final budget = maxChannelMessageBytes(senderName);
    if (budget <= 0) return 0;
    return budget ~/ 2;
  }

  static String bytesToHex(Uint8List bytes) {
    final buffer = StringBuffer();
    for (final b in bytes) {
      buffer.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }
}
