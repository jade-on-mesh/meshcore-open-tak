import 'dart:typed_data';

/// Wraps mono PCM16 samples in a minimal RIFF/WAVE container for playback.
Uint8List voxPcm16ToWav(Int16List pcm, {int sampleRate = 8000}) {
  final dataLen = pcm.length * 2;
  final out = ByteData(44 + dataLen);
  void ascii(int off, String s) {
    for (var i = 0; i < s.length; i++) {
      out.setUint8(off + i, s.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  out.setUint32(4, 36 + dataLen, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  out.setUint32(16, 16, Endian.little);
  out.setUint16(20, 1, Endian.little); // PCM
  out.setUint16(22, 1, Endian.little); // mono
  out.setUint32(24, sampleRate, Endian.little);
  out.setUint32(28, sampleRate * 2, Endian.little);
  out.setUint16(32, 2, Endian.little);
  out.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  out.setUint32(40, dataLen, Endian.little);
  for (var i = 0; i < pcm.length; i++) {
    out.setInt16(44 + i * 2, pcm[i], Endian.little);
  }
  return out.buffer.asUint8List();
}
