import 'dart:convert';
import 'dart:typed_data';

import 'otp_service.dart';

/// Framing/parsing for OTP multi-packet chunked messages and their
/// application-level acks — a direct port of WADAMESH OTP_2_RC15.lua's
/// `MARKER.msg_chunk` / `MARKER.msg_ack` envelope.
///
/// Both markers are prepended to the PLAINTEXT before XOR, so the envelope
/// is invisible on the wire: ciphertext for a chunk looks exactly like
/// ciphertext for any single-shot message of the same length — someone
/// without the pad can't tell a chunked transfer apart from an ordinary
/// message just by looking at packets.
///
/// Wire layout of one chunk's PLAINTEXT (before XOR):
///   [MARKER.msg_chunk : 9 bytes] [tid : 1 byte] [idx : 1 byte] [totCh : 1 byte] [chunk data : N bytes]
///
/// Wire layout of one ack's PLAINTEXT (before XOR):
///   [MARKER.msg_ack : 8 bytes] [tid : 1 byte] [idx : 1 byte]
///
/// (Lua's `MARKER.msg_chunk` is the literal byte string
/// `"\1MSGCHNK\2"` — 0x01, "MSGCHNK", 0x02 — 9 bytes; `MARKER.msg_ack` is
/// `"\1MSGACK\2"` — 0x01, "MSGACK", 0x02 — 8 bytes.)
class OtpChunkService {
  OtpChunkService._();

  static final Uint8List msgChunkMarker = Uint8List.fromList([
    1,
    ...utf8.encode('MSGCHNK'),
    2,
  ]);

  static final Uint8List msgAckMarker = Uint8List.fromList([
    1,
    ...utf8.encode('MSGACK'),
    2,
  ]);

  /// tid + idx + totCh, immediately after the chunk marker.
  static const int _chunkHeaderLen = 3;

  /// tid + idx, immediately after the ack marker.
  static const int _ackHeaderLen = 2;

  /// Bytes of framing overhead one chunk carries beyond its raw data:
  /// marker + tid + idx + totCh. Callers must reserve this much out of the
  /// single-packet plaintext budget when deciding how much raw data fits
  /// in each chunk.
  static int get chunkOverheadBytes => msgChunkMarker.length + _chunkHeaderLen;

  /// Total plaintext bytes an ack frame occupies (marker + tid + idx).
  static int get ackFrameBytes => msgAckMarker.length + _ackHeaderLen;

  /// The largest message this app will attempt to chunk-send/receive over
  /// a contact DM, in plaintext UTF-8 bytes — 255 chunks (tid/idx/totCh are
  /// single bytes, matching Lua) at the per-chunk data capacity.
  static int maxChunkedPlaintextBytesForContact() {
    final perChunk = OtpService.maxPlaintextBytesForContact() - chunkOverheadBytes;
    if (perChunk <= 0) return 0;
    return perChunk * 255;
  }

  /// Same as [maxChunkedPlaintextBytesForContact] but for a channel, whose
  /// single-packet budget also has to make room for the "<name>: " prefix.
  static int maxChunkedPlaintextBytesForChannel(String? senderName) {
    final perChunk =
        OtpService.maxPlaintextBytesForChannel(senderName) - chunkOverheadBytes;
    if (perChunk <= 0) return 0;
    return perChunk * 255;
  }

  /// Builds the PLAINTEXT byte buffer for one chunk — the caller is
  /// responsible for XOR-encrypting this against the sender's own pad
  /// slice (see OtpService.encryptBytes) and never re-encrypting it again
  /// on retry, exactly like the single-shot "encrypt exactly once at
  /// compose time" rule this app already follows.
  static Uint8List buildChunkFrame({
    required int tid,
    required int idx,
    required int totCh,
    required Uint8List chunkData,
  }) {
    assert(tid >= 0 && tid <= 0xFF);
    assert(idx >= 0 && idx <= 0xFF);
    assert(totCh >= 1 && totCh <= 0xFF);
    final out = Uint8List(chunkOverheadBytes + chunkData.length);
    out.setRange(0, msgChunkMarker.length, msgChunkMarker);
    out[msgChunkMarker.length] = tid & 0xFF;
    out[msgChunkMarker.length + 1] = idx & 0xFF;
    out[msgChunkMarker.length + 2] = totCh & 0xFF;
    out.setRange(chunkOverheadBytes, out.length, chunkData);
    return out;
  }

  /// Builds the PLAINTEXT byte buffer for one ack (acknowledging chunk
  /// [idx] of transfer [tid]).
  static Uint8List buildAckFrame({required int tid, required int idx}) {
    assert(tid >= 0 && tid <= 0xFF);
    assert(idx >= 0 && idx <= 0xFF);
    final out = Uint8List(ackFrameBytes);
    out.setRange(0, msgAckMarker.length, msgAckMarker);
    out[msgAckMarker.length] = tid & 0xFF;
    out[msgAckMarker.length + 1] = idx & 0xFF;
    return out;
  }

  /// Parses already-decrypted plaintext bytes. Returns a [ParsedChunkFrame]
  /// if this is a chunk, a [ParsedAckFrame] if it's an ack, or null if it's
  /// an ordinary (non-chunked, non-ack) OTP message — the caller should
  /// then treat [plainBytes] as normal message plaintext (UTF-8 decode and
  /// display it).
  static Object? parse(Uint8List plainBytes) {
    if (_startsWith(plainBytes, msgChunkMarker)) {
      if (plainBytes.length < chunkOverheadBytes) return null;
      final tid = plainBytes[msgChunkMarker.length];
      final idx = plainBytes[msgChunkMarker.length + 1];
      final totCh = plainBytes[msgChunkMarker.length + 2];
      if (totCh == 0) return null;
      final data = Uint8List.sublistView(plainBytes, chunkOverheadBytes);
      return ParsedChunkFrame(tid: tid, idx: idx, totCh: totCh, data: data);
    }
    if (_startsWith(plainBytes, msgAckMarker)) {
      if (plainBytes.length < ackFrameBytes) return null;
      final tid = plainBytes[msgAckMarker.length];
      final idx = plainBytes[msgAckMarker.length + 1];
      return ParsedAckFrame(tid: tid, idx: idx);
    }
    return null;
  }

  static bool _startsWith(Uint8List bytes, Uint8List prefix) {
    if (bytes.length < prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (bytes[i] != prefix[i]) return false;
    }
    return true;
  }

  /// Splits [fullBytes] into pieces of at most [maxDataBytes] raw bytes
  /// each. Never inspects UTF-8 codepoint boundaries — a chunk's data may
  /// end mid-codepoint, which is fine because chunks are only ever
  /// UTF-8-decoded after every piece has been reassembled in order (see
  /// [joinOrderedChunks]), never individually.
  static List<Uint8List> splitPlaintextBytes(
    Uint8List fullBytes,
    int maxDataBytes,
  ) {
    if (maxDataBytes <= 0) {
      throw ArgumentError('maxDataBytes must be positive');
    }
    if (fullBytes.isEmpty) return [Uint8List(0)];
    final chunks = <Uint8List>[];
    var offset = 0;
    while (offset < fullBytes.length) {
      final end = (offset + maxDataBytes < fullBytes.length)
          ? offset + maxDataBytes
          : fullBytes.length;
      chunks.add(Uint8List.sublistView(fullBytes, offset, end));
      offset = end;
    }
    return chunks;
  }

  /// Concatenates already-ordered chunk data back into one byte buffer,
  /// ready for a single `utf8.decode`.
  static Uint8List joinOrderedChunks(List<Uint8List> orderedChunks) {
    final total = orderedChunks.fold<int>(0, (sum, c) => sum + c.length);
    final out = Uint8List(total);
    var offset = 0;
    for (final c in orderedChunks) {
      out.setRange(offset, offset + c.length, c);
      offset += c.length;
    }
    return out;
  }
}

class ParsedChunkFrame {
  final int tid;
  final int idx;
  final int totCh;
  final Uint8List data;

  ParsedChunkFrame({
    required this.tid,
    required this.idx,
    required this.totCh,
    required this.data,
  });
}

class ParsedAckFrame {
  final int tid;
  final int idx;

  ParsedAckFrame({required this.tid, required this.idx});
}
