// MeshCore Open TAK - alert sounds for watched channels.
//
// Each watched channel can have its own sound, played when one of its reports
// with a position lands on the map, so a #dronewatch drone and an #icewatch
// sighting can be told apart without looking. The sounds are synthesized
// here (like the SOS siren in team_alert_host.dart): nothing to bundle or
// license, and they stay short and distinct.

import 'dart:math';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';

/// One tone in a sound: [hz] (0 = silence), [ms] long, at [level] (0-1).
/// [toHz] slides the pitch; [decay] fades it out like a struck bell.
class _Tone {
  final double hz, toHz, level;
  final int ms;
  final bool decay;
  const _Tone(
    this.hz,
    this.ms, {
    double? to,
    this.level = 0.6,
    this.decay = false,
  }) : toHz = to ?? hz;
  const _Tone.rest(this.ms) : hz = 0, toHz = 0, level = 0, decay = false;
}

enum WatchSound {
  off('Off', []),
  chime('Chime', [
    _Tone(880, 160, decay: true),
    _Tone(1318.5, 380, decay: true),
  ]),
  ping('Ping', [_Tone(1760, 420, level: 0.55, decay: true)]),
  doubleBeep('Double beep', [
    _Tone(1200, 110),
    _Tone.rest(80),
    _Tone(1200, 110),
  ]),
  tripleBeep('Triple beep', [
    _Tone(1500, 80),
    _Tone.rest(60),
    _Tone(1500, 80),
    _Tone.rest(60),
    _Tone(1500, 80),
  ]),
  rising('Rising', [
    _Tone(523.3, 110),
    _Tone(659.3, 110),
    _Tone(784, 110),
    _Tone(1046.5, 220, decay: true),
  ]),
  falling('Falling', [
    _Tone(1046.5, 110),
    _Tone(784, 110),
    _Tone(659.3, 110),
    _Tone(523.3, 220, decay: true),
  ]),
  sonar('Sonar', [_Tone(1050, 900, level: 0.65, decay: true)]),
  warble('Warble', [
    _Tone(900, 70),
    _Tone(1300, 70),
    _Tone(900, 70),
    _Tone(1300, 70),
    _Tone(900, 70),
    _Tone(1300, 70),
  ]),
  sweep('Sweep', [_Tone(500, 450, to: 1900, level: 0.55)]),
  lowHorn('Low horn', [
    _Tone(330, 260, level: 0.7),
    _Tone.rest(90),
    _Tone(330, 260, level: 0.7),
  ]),
  klaxon('Klaxon', [
    _Tone(620, 180, level: 0.7),
    _Tone(480, 180, level: 0.7),
    _Tone(620, 180, level: 0.7),
    _Tone(480, 180, level: 0.7),
  ]);

  final String label;
  final List<_Tone> _tones;
  const WatchSound(this.label, this._tones);

  static WatchSound fromName(String? name) => WatchSound.values.firstWhere(
    (s) => s.name == name,
    orElse: () => WatchSound.off,
  );

  static const _rate = 22050;

  /// The sound as a 16-bit mono WAV file.
  Uint8List wav() {
    final samples = <int>[];
    for (final t in _tones) {
      final n = _rate * t.ms ~/ 1000;
      final attack = min(n ~/ 2, _rate * 4 ~/ 1000); // 4 ms: no clicks
      var phase = 0.0;
      for (var i = 0; i < n; i++) {
        if (t.hz == 0) {
          samples.add(0);
          continue;
        }
        final f = t.hz + (t.toHz - t.hz) * i / n;
        phase += 2 * pi * f / _rate;
        var env = t.decay ? exp(-4.0 * i / n) : 1.0;
        if (i < attack) env *= i / attack;
        if (n - i < attack) env *= (n - i) / attack;
        // A touch of the octave makes small phone speakers carry it.
        final v = sin(phase) * 0.85 + sin(phase * 2) * 0.15;
        samples.add((v * env * t.level * 32767).round());
      }
    }
    final data = ByteData(44 + samples.length * 2);
    void str(int o, String s) {
      for (var i = 0; i < s.length; i++) {
        data.setUint8(o + i, s.codeUnitAt(i));
      }
    }

    str(0, 'RIFF');
    data.setUint32(4, 36 + samples.length * 2, Endian.little);
    str(8, 'WAVE');
    str(12, 'fmt ');
    data.setUint32(16, 16, Endian.little);
    data.setUint16(20, 1, Endian.little);
    data.setUint16(22, 1, Endian.little);
    data.setUint32(24, _rate, Endian.little);
    data.setUint32(28, _rate * 2, Endian.little);
    data.setUint16(32, 2, Endian.little);
    data.setUint16(34, 16, Endian.little);
    str(36, 'data');
    data.setUint32(40, samples.length * 2, Endian.little);
    for (var i = 0; i < samples.length; i++) {
      data.setInt16(44 + i * 2, samples[i].clamp(-32768, 32767), Endian.little);
    }
    return data.buffer.asUint8List();
  }
}

/// Plays watch sounds, one at a time (a newer one cuts off an older one).
class WatchSoundPlayer {
  AudioPlayer? _player;
  final Map<WatchSound, Uint8List> _cache = {};

  Future<void> play(WatchSound s) async {
    if (s == WatchSound.off) return;
    try {
      final p = _player ??= AudioPlayer();
      await p.stop();
      await p.play(BytesSource(_cache.putIfAbsent(s, s.wav)));
    } catch (_) {
      // No audio output (a test, a desktop without sound): stay quiet.
    }
  }

  void dispose() {
    _player?.dispose();
    _player = null;
  }
}
