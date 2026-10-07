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
