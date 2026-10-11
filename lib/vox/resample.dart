// MeshCore Open TAK - integer-factor downsampling for the voice recorder.
//
// The mic is recorded once at 48 kHz (a rate every Android device supports)
// and decimated to 24 kHz for Mimi or 8 kHz for Codec2.

import 'dart:math';
import 'dart:typed_data';

/// Recording rate used by the voice recorder.
const int voxRecordSampleRate = 48000;

/// Low-pass filters (windowed sinc, Blackman) and keeps every [factor]-th
/// sample. Input is PCM16; output is float in [-1, 1].
Float32List voxDecimate(Int16List input, int factor, {int taps = 63}) {
  if (factor <= 1) {
    return Float32List.fromList([for (final s in input) s / 32768.0]);
  }
  // Cut off a little below the new Nyquist frequency.
  final cutoff = 0.45 / factor;
  final h = Float64List(taps);
  final mid = (taps - 1) / 2;
  var sum = 0.0;
  for (var i = 0; i < taps; i++) {
    final n = i - mid;
    final sinc = n == 0 ? 2 * cutoff : sin(2 * pi * cutoff * n) / (pi * n);
    final w =
        0.42 -
        0.5 * cos(2 * pi * i / (taps - 1)) +
        0.08 * cos(4 * pi * i / (taps - 1));
    h[i] = sinc * w;
    sum += h[i];
  }
  for (var i = 0; i < taps; i++) {
    h[i] /= sum;
  }
  final outLen = input.length ~/ factor;
  final out = Float32List(outLen);
  final half = taps ~/ 2;
  for (var o = 0; o < outLen; o++) {
    final c = o * factor;
    var acc = 0.0;
    for (var k = 0; k < taps; k++) {
      final idx = c + k - half;
      if (idx >= 0 && idx < input.length) acc += h[k] * input[idx];
    }
    out[o] = (acc / 32768.0).clamp(-1.0, 1.0);
  }
  return out;
}

/// Float [-1, 1] samples to PCM16.
Int16List voxFloatToPcm16(Float32List x) {
  final out = Int16List(x.length);
  for (var i = 0; i < x.length; i++) {
    out[i] = (x[i].clamp(-1.0, 1.0) * 32767).round();
  }
  return out;
}
