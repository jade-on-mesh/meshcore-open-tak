import 'dart:typed_data';

import 'voice_wire.dart';

bool get voxCodecAvailable => false;
String? get voxCodecUnavailableReason =>
    'Voice is not supported on this platform';

Uint8List voxEncodePcm(Int16List pcm, VoxVoiceMode mode) =>
    throw UnsupportedError('Codec2 unavailable');

Int16List voxDecodeBits(Uint8List bits, VoxVoiceMode mode) =>
    throw UnsupportedError('Codec2 unavailable');

class VoxCodec2Stream {
  VoxCodec2Stream(VoxVoiceMode mode) {
    throw UnsupportedError('Codec2 unavailable');
  }
  int get samplesPerFrame => 320;
  int get bytesPerFrame => 6;
  Uint8List encode(Int16List pcm) => throw UnsupportedError('Codec2 unavailable');
  Int16List decode(Uint8List bits) =>
      throw UnsupportedError('Codec2 unavailable');
  void dispose() {}
}
