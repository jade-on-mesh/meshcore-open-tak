// MeshCore Open TAK - voice clean-up around Codec2 (as Wadamesh TAK's
// VoxVoice: jade-on-mesh/wadamesh-tak#120, after GridDown's voice chain).
//
// Sending: the recording is levelled to a healthy peak and a soft noise gate
// takes the hiss between words down 16 dB, so pauses come out quiet instead of
// as Codec2's rendering of hiss.
//
// Playing: Codec2's 8 kHz output is levelled (up to 6x, towards -3 dBFS),
// interpolated up to 16 kHz and low-passed at 3.6 kHz, so the platform's
// resampler doesn't add a metallic image band above 4 kHz, and a soft limiter
// rounds off any overshoot instead of clipping.
//
// No pre-emphasis: that only helps when every receiver de-emphasizes, and
// radios on older firmware don't.

import 'dart:math';
import 'dart:typed_data';

/// Codec2's sample rate.
const int voxCodecRate = 8000;

/// The rate decoded voice is played at.
const int voxPlayRate = 16000;

const double _kKnee = 24000;
const double _kCeiling = 32000;

/// Soft limiter: linear up to 24000, then rounds off towards 32000.
double voxSoftLimit(double v) {
  final m = v.abs();
  if (m <= _kKnee) return v;
  final e = m - _kKnee;
  final r = _kKnee + (_kCeiling - _kKnee) * e / (e + (_kCeiling - _kKnee));
  return v < 0 ? -r : r;
}

/// Gain that brings a clip peaking at [peak] towards -3 dBFS: 1..6 (a
/// near-silent clip isn't turned into hiss, a loud one isn't turned down).
double voxPlayNormGain(int peak) {
  if (peak <= 0) return 1;
  return (23000 / peak).clamp(1.0, 6.0);
}

int _peak(Int16List pcm, [int? limit]) {
  final n = limit == null ? pcm.length : min(limit, pcm.length);
  var p = 0;
  for (var i = 0; i < n; i++) {
    final a = pcm[i].abs();
    if (a > p) p = a;
  }
  return p;
}

/// 8 kHz voice out at [outRate]: gain, linear interpolation, a 3.6 kHz RBJ
/// low-pass (when upsampling) and the soft limiter. Streams: [push] each
/// chunk as it's decoded.
class VoxPlayOut {
  VoxPlayOut({this.outRate = voxPlayRate, this.gain = 1})
    : _step = voxCodecRate / outRate,
      _lpf = outRate > voxCodecRate {
    if (_lpf) {
      final w0 = 2 * pi * 3600 / outRate;
      final alpha = sin(w0) / (2 * 0.70710678);
      final c = cos(w0);
      final a0 = 1 + alpha;
      _b0 = ((1 - c) / 2) / a0;
      _b1 = (1 - c) / a0;
      _b2 = _b0;
      _a1 = (-2 * c) / a0;
      _a2 = (1 - alpha) / a0;
    }
  }

  final int outRate;
  double gain;
  final double _step;
  final bool _lpf;
  double _rel = 1, _prev = 0;
  double _b0 = 1, _b1 = 0, _b2 = 0, _a1 = 0, _a2 = 0;
  double _x1 = 0, _x2 = 0, _y1 = 0, _y2 = 0;

  Int16List push(Int16List pcm8k) {
    final out = Int16List((pcm8k.length / _step).ceil() + 2);
    var n = 0;
    for (final s in pcm8k) {
      final cur = s * gain;
      while (_rel <= 1) {
        var y = _prev + (cur - _prev) * _rel;
        if (_lpf) {
          final f = _b0 * y + _b1 * _x1 + _b2 * _x2 - _a1 * _y1 - _a2 * _y2;
          _x2 = _x1;
          _x1 = y;
          _y2 = _y1;
          _y1 = f;
          y = f;
        }
        if (n < out.length) {
          out[n++] = voxSoftLimit(y).round().clamp(-32768, 32767);
        }
        _rel += _step;
      }
      _rel -= 1;
      _prev = cur;
    }
    return Int16List.sublistView(out, 0, n);
  }
}

/// A whole decoded clip, ready to play at [voxPlayRate]: levelled from its
/// first 3 s, upsampled, filtered and limited.
Int16List voxPlayClip(Int16List pcm8k) {
  final gain = voxPlayNormGain(_peak(pcm8k, 3 * voxCodecRate));
  return VoxPlayOut(gain: gain).push(pcm8k);
}

/// Soft noise gate on 8 kHz samples (PCM16 scale). A peak envelope (fast
/// attack, ~0.3 s release) opens it above [openAt]; it opens in ~2 ms and
/// closes over ~60 ms to [floor] (-16 dB), so words and their tails are never
/// clipped, only the pauses quietened.
class VoxMicGate {
  VoxMicGate({this.openAt = 180, this.floor = 0.16});

  final double openAt;
  final double floor;
  static const double _envAttack = 0.3;
  static const double _envRelease = 1 / (0.3 * voxCodecRate);
  static const double _attack = 1 / (0.002 * voxCodecRate);
  static const double _release = 1 / (0.060 * voxCodecRate);

  double _env = 0;
  double _gate = 1; // open: the first syllable isn't faded in

  double process(double s) {
    final a = s.abs();
    _env += (a - _env) * (a > _env ? _envAttack : _envRelease);
    final to = _env > openAt ? 1.0 : floor;
    _gate += (to - _gate) * (to > _gate ? _attack : _release);
    return s * _gate;
  }

  /// [pcm] gated in place.
  Int16List processPcm(Int16List pcm) {
    for (var i = 0; i < pcm.length; i++) {
      pcm[i] = process(pcm[i].toDouble()).round().clamp(-32768, 32767);
    }
    return pcm;
  }
}

/// A whole 8 kHz recording ([-1, 1] floats) ready for Codec2: levelled
/// towards a peak of about -8 dBFS (at most 8x; never turned down), gated
/// and soft-limited. Returns PCM16.
Int16List voxPrepClip(Float32List audio8k) {
  var peak = 0.0;
  for (final s in audio8k) {
    final a = s.abs();
    if (a > peak) peak = a;
  }
  final p16 = peak * 32768;
  final gain = p16 <= 0 ? 1.0 : (13000 / p16).clamp(1.0, 8.0);
  // Gate threshold ~30 dB below the levelled peak.
  final gate = VoxMicGate(openAt: max(180.0, p16 * gain / 32));
  final out = Int16List(audio8k.length);
  for (var i = 0; i < audio8k.length; i++) {
    final v = gate.process(audio8k[i] * 32768 * gain);
    out[i] = voxSoftLimit(v).round().clamp(-32768, 32767);
  }
  return out;
}
