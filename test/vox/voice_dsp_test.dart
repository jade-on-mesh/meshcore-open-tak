import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/vox/voice_dsp.dart';

Int16List _tone(double hz, double amp, int n, {int rate = 8000}) {
  final out = Int16List(n);
  for (var i = 0; i < n; i++) {
    out[i] = (amp * sin(2 * pi * hz * i / rate)).round();
  }
  return out;
}

/// Amplitude of [hz] in [x] (a single-bin DFT), skipping the first [skip].
double _bin(Int16List x, double hz, int rate, {int skip = 200}) {
  var re = 0.0, im = 0.0;
  final n = x.length - skip;
  for (var i = skip; i < x.length; i++) {
    re += x[i] * cos(2 * pi * hz * i / rate);
    im += x[i] * sin(2 * pi * hz * i / rate);
  }
  return 2 * sqrt(re * re + im * im) / n;
}

double _rms(Iterable<num> x) {
  var s = 0.0, n = 0;
  for (final v in x) {
    s += v.toDouble() * v.toDouble();
    n++;
  }
  return n == 0 ? 0 : sqrt(s / n);
}

void main() {
  test('play gain levels quiet clips, up to 6x, never down', () {
    expect(voxPlayNormGain(0), 1);
    expect(voxPlayNormGain(30000), 1);
    expect(voxPlayNormGain(11500), closeTo(2, 1e-9));
    expect(voxPlayNormGain(100), 6);
  });

  test('soft limiter is linear to the knee and stays under the ceiling', () {
    expect(voxSoftLimit(20000), 20000);
    expect(voxSoftLimit(-24000), -24000);
    expect(voxSoftLimit(60000), lessThan(32000));
    expect(voxSoftLimit(-60000), greaterThan(-32000));
    expect(voxSoftLimit(30000), greaterThan(voxSoftLimit(26000)));
  });

  test('upsampling keeps speech and leaves no image above 4 kHz', () {
    final x = _tone(1000, 8000, 8000);
    final y = VoxPlayOut().push(x);
    expect(y.length, closeTo(16000, 2));
    // Linear interpolation loses a little at 1 kHz (about 0.4 dB).
    expect(_bin(y, 1000, 16000), closeTo(7700, 500));
    // Sample-repeat would put a strong image at 8000 - 1000 = 7 kHz.
    final repeat = Int16List(x.length * 2);
    for (var i = 0; i < x.length; i++) {
      repeat[2 * i] = x[i];
      repeat[2 * i + 1] = x[i];
    }
    final imgRepeat = _bin(repeat, 7000, 16000);
    final imgOut = _bin(y, 7000, 16000);
    expect(imgRepeat, greaterThan(500));
    expect(imgOut, lessThan(imgRepeat / 20));
  });

  test('streaming in chunks matches one push', () {
    final x = _tone(700, 6000, 4000);
    final whole = VoxPlayOut().push(x);
    final po = VoxPlayOut();
    final parts = <int>[];
    for (var i = 0; i < x.length; i += 333) {
      final end = min(i + 333, x.length);
      parts.addAll(po.push(Int16List.sublistView(x, i, end)));
    }
    expect(parts, whole);
  });

  test('a quiet clip is levelled for playback', () {
    final y = voxPlayClip(_tone(500, 3000, 8000));
    expect(_bin(y, 500, 16000), closeTo(3000 * 6, 1500));
  });

  test('gate quietens hiss between words but not the words', () {
    final rnd = Random(1);
    final hiss = List.generate(16000, (_) => (rnd.nextDouble() - 0.5) * 120);
    final speech = _tone(400, 9000, 4000);
    final g = VoxMicGate();
    final outSpeech = [for (final s in speech) g.process(s.toDouble())];
    // The envelope lingers ~1.2 s after loud speech; measure the hiss after.
    final outHiss = [for (final s in hiss) g.process(s)];
    expect(_rms(outSpeech), closeTo(_rms(speech), _rms(speech) * 0.02));
    expect(
      _rms(outHiss.sublist(12000)),
      lessThan(_rms(hiss.sublist(12000)) * 0.25),
    );
  });

  test('prep levels a quiet recording and gates its pauses', () {
    final rnd = Random(2);
    final f = Float32List(24000);
    for (var i = 0; i < 8000; i++) {
      f[i] = 0.08 * sin(2 * pi * 300 * i / 8000);
    }
    for (var i = 8000; i < f.length; i++) {
      f[i] = (rnd.nextDouble() - 0.5) * 0.002;
    }
    final y = voxPrepClip(f);
    final peak = y.sublist(0, 8000).map((v) => v.abs()).reduce(max);
    expect(peak, closeTo(13000, 600));
    const gain = 13000 / (0.08 * 32768);
    final hissIn = _rms([for (final v in f.sublist(20000)) v * 32768 * gain]);
    expect(_rms(y.sublist(20000)), lessThan(hissIn * 0.25));
  });
}
