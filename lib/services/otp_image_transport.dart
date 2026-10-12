import 'dart:convert';
import 'dart:typed_data';

import 'image_chunk_transport.dart' show ImageStreamMetadata;

/// Wire framing that lets an OTP-encrypted direct message carry a
/// neural-codec image bitstream (see `image_codec_service.dart`) instead of
/// chat text.
///
/// This deliberately rides over the EXISTING OTP DM chunk-send pipeline
/// (`OtpChunkService` / `MeshCoreConnector._sendChunkedContactMessage`-style
/// machinery), not the channel-only, unencrypted `CMD_SEND_CHANNEL_DATA`
/// transport (`image_chunk_transport.dart`'s `ImageChunkTransport`/GRP_DATA):
/// that transport is channel-index-addressed at the protocol level and
/// structurally cannot be pointed at a single contact. The OTP DM chunk
/// pipeline, by contrast, is already byte-generic — it chunks/encrypts/acks
/// whatever `Uint8List` it is handed — so this file only has to say how an
/// image's bytes are told apart from ordinary chat text once decrypted and
/// reassembled.
///
/// Both this marker and `OtpChunkService`'s own MSGCHNK/MSGACK markers are
/// prepended to the PLAINTEXT before OTP-encrypting each chunk, so (exactly
/// like a chunked text message) the ciphertext actually on the air is
/// indistinguishable from any other OTP traffic to anyone without the pad.
///
/// Wire layout of the plaintext this marker frames, before OTP chunking:
///   [marker : 8 bytes] [metadata : 1 byte] [codec bitstream : N bytes]
///
/// The metadata byte is exactly `ImageStreamMetadata.encode()` /
/// `ImageStreamMetadata.decode()` — deliberately reused rather than
/// reinvented, so a DM image and a channel image describe their rate point,
/// resolution and source aspect ratio identically on the wire.
class OtpImageTransport {
  OtpImageTransport._();

  /// `"\1OTPIMG\2"` — 0x01, "OTPIMG", 0x02 — 8 bytes, the same
  /// length/shape as `OtpChunkService.msgAckMarker`.
  static final Uint8List marker = Uint8List.fromList([
    1,
    ...utf8.encode('OTPIMG'),
    2,
  ]);

  /// Builds the plaintext byte buffer to hand to the OTP DM chunk-send
  /// pipeline in place of UTF-8 chat text.
  ///
  /// Throws [ArgumentError] (via [ImageStreamMetadata.encode]) if
  /// [metadata].squareSize is not one of the codec's known resolutions.
  static Uint8List buildPlaintext({
    required ImageStreamMetadata metadata,
    required Uint8List bitstream,
  }) {
    final metaByte = metadata.encode();
    final out = Uint8List(marker.length + 1 + bitstream.length);
    out.setRange(0, marker.length, marker);
    out[marker.length] = metaByte & 0xFF;
    out.setRange(marker.length + 1, out.length, bitstream);
    return out;
  }

  /// Parses already-decrypted, already-reassembled plaintext bytes (the
  /// output of the OTP DM chunk pipeline, never a single still-encrypted
  /// chunk). Returns null when [plainBytes] does not start with [marker] at
  /// all — an ordinary chat message, which the caller should
  /// `utf8.decode` and display as text exactly as before this feature
  /// existed.
  static OtpImagePayload? parse(Uint8List plainBytes) {
    if (!_startsWith(plainBytes, marker)) return null;
    if (plainBytes.length < marker.length + 1) return null;
    final metaByte = plainBytes[marker.length];
    // Mirrors ImageChunkStatus.unsupportedFormat on the channel side: a null
    // here means "this build doesn't recognize the rate point/resolution",
    // not "this isn't an image" — the caller still knows a photo was sent,
    // it just cannot be decoded.
    final metadata = ImageStreamMetadata.decode(metaByte);
    final bitstream = Uint8List.sublistView(plainBytes, marker.length + 1);
    return OtpImagePayload(metadata: metadata, bitstream: bitstream);
  }

  static bool _startsWith(Uint8List bytes, Uint8List prefix) {
    if (bytes.length < prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (bytes[i] != prefix[i]) return false;
    }
    return true;
  }

  /// A deterministic, negative "virtual channel index" for one contact's OTP
  /// DM image stream.
  ///
  /// [ReceivedImageStore] keys every entry by `(senderPrefix, imgId,
  /// channelIndex)` — a shape built for GRP_DATA's real, small,
  /// non-negative channel indices. Reusing the whole store for DM images
  /// (rather than duplicating its persistence/decode-queue/eviction logic)
  /// means giving each contact's DM conversation its own stand-in
  /// "channel" that can never collide with a real one (0..N) or with
  /// another contact's.
  ///
  /// Computed fresh from the contact's public key hex every call —
  /// deliberately NOT `String.hashCode`, which Dart does not guarantee is
  /// stable across versions/platforms/restarts — so a restart still maps
  /// the same contact to the same virtual index and lets already-persisted
  /// entries keep resolving to it.
  static int virtualChannelIndexFor(String contactPublicKeyHex) {
    // FNV-1a, 32-bit.
    var h = 0x811c9dc5;
    for (final unit in contactPublicKeyHex.codeUnits) {
      h = ((h ^ unit) * 0x01000193) & 0xFFFFFFFF;
    }
    return -1000000 - (h & 0xFFFFF);
  }
}

class OtpImagePayload {
  /// Null when the metadata byte names a rate point or resolution this
  /// build cannot decode (see [ImageStreamMetadata.decode]). [bitstream] is
  /// still returned so the caller can surface "unsupported image" rather
  /// than silently dropping the transfer.
  final ImageStreamMetadata? metadata;
  final Uint8List bitstream;

  const OtpImagePayload({required this.metadata, required this.bitstream});
}
