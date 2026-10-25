// MeshCore Open TAK - live speaker output for push-to-talk.
//
// Voice PCM (16 kHz) is streamed to the platform's own audio output, with no
// plugin: Android AudioTrack (PcmStreamChannel.kt), AVAudioEngine on iOS
// (AppDelegate.swift) and macOS (MainFlutterWindow.swift). Elsewhere (Windows,
// Linux) each second is played as a short WAV, one after another, which can
// leave a tiny gap between seconds.

import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'wav.dart';

class WalkieSpeaker {
  WalkieSpeaker();

  static const _channel = MethodChannel('meshcore_open/pcm_stream');

  /// Codec2's 8 kHz, upsampled and filtered by VoxPlayOut (voice_dsp.dart).
  static const int sampleRate = 16000;

  bool get _native =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS);

  bool _open = false;
  bool _nativeFailed = false;

  // Fallback: WAV chunks in turn.
  AudioPlayer? _player;
  final Queue<Int16List> _queue = Queue();
  bool _playing = false;
  StreamSubscription<void>? _done;

  Future<void> start() async {
    if (_open) return;
    _open = true;
    if (_native && !_nativeFailed) {
      try {
        final ok = await _channel.invokeMethod<bool>('open', {
          'sampleRate': sampleRate,
        });
        if (ok == true) return;
      } on MissingPluginException {
        // Not in this build: the fallback below.
      } on PlatformException {
        // The output couldn't start: the fallback below.
      }
      _nativeFailed = true;
    }
    _player ??= AudioPlayer();
    _done ??= _player!.onPlayerComplete.listen((_) {
      _playing = false;
      _pump();
    });
  }

  Future<void> write(Int16List pcm) async {
    if (!_open || pcm.isEmpty) return;
    if (_native && !_nativeFailed) {
      try {
        await _channel.invokeMethod<void>('write', {
          'pcm': pcm.buffer.asUint8List(pcm.offsetInBytes, pcm.lengthInBytes),
        });
        return;
      } catch (_) {
        _nativeFailed = true;
        await start();
      }
    }
    _queue.add(pcm);
    _pump();
  }

  void _pump() {
    final p = _player;
    if (p == null || _playing || _queue.isEmpty) return;
    _playing = true;
    final wav = voxPcm16ToWav(_queue.removeFirst(), sampleRate: sampleRate);
    unawaited(
      p.play(BytesSource(wav)).catchError((Object _) {
        _playing = false;
      }),
    );
  }

  /// Lets what was written finish playing, then lets the output go.
  Future<void> finish() async {
    if (!_open) return;
    _open = false;
    if (_native && !_nativeFailed) {
      try {
        await _channel.invokeMethod<void>('close', {'drain': true});
      } catch (_) {}
    }
  }

  /// Stops at once.
  Future<void> stop() async {
    _open = false;
    _queue.clear();
    if (_native && !_nativeFailed) {
      try {
        await _channel.invokeMethod<void>('close', {'drain': false});
      } catch (_) {}
    }
    _playing = false;
    try {
      await _player?.stop();
    } catch (_) {}
  }

  Future<void> dispose() async {
    await stop();
    await _done?.cancel();
    _done = null;
    await _player?.dispose();
    _player = null;
  }
}
