import 'dart:typed_data';

import '../services/codec2_ffi.dart';
import 'voice_wire.dart';

bool get voxCodecAvailable => Codec2Ffi.isAvailable;

String? get voxCodecUnavailableReason => Codec2Ffi.isAvailable
    ? null
    : 'Codec2 not available: ${Codec2Ffi.loadError}';

Uint8List voxEncodePcm(Int16List pcm, VoxVoiceMode mode) {
  final session = Codec2Ffi.instanceOrNull!.createSession(mode.codec2Id);
  try {
    return session.encode(pcm);
  } finally {
    session.dispose();
  }
}

Int16List voxDecodeBits(Uint8List bits, VoxVoiceMode mode) {
  final session = Codec2Ffi.instanceOrNull!.createSession(mode.codec2Id);
  try {
    return session.decode(bits);
  } finally {
    session.dispose();
  }
}

/// A Codec2 session kept open across calls, for push-to-talk: Codec2 carries
/// state from one frame to the next, so a live talk is encoded (or decoded)
/// a few frames at a time with the same session.
class VoxCodec2Stream {
  VoxCodec2Stream(VoxVoiceMode mode)
    : _session = Codec2Ffi.instanceOrNull!.createSession(mode.codec2Id);

  final Codec2Session _session;

  int get samplesPerFrame => _session.samplesPerFrame;
  int get bytesPerFrame => _session.bytesPerFrame;

  /// Whole frames of 8 kHz PCM in, their Codec2 bytes out.
  Uint8List encode(Int16List pcm) => _session.encode(pcm);

  /// Whole frames of Codec2 in, 8 kHz PCM out.
  Int16List decode(Uint8List bits) => _session.decode(bits);

  void dispose() => _session.dispose();
}
