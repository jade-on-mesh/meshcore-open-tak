// MeshCore Open TAK - sending and hearing text over sound (ggwave).
//
// play() turns up to 140 bytes into a few seconds of tones on the speaker;
// listen() hears them on the microphone. Used to share contacts and
// channels by sound (a T-Deck has no camera for their QR codes) and for
// Wavest-compatible messages (wavest_format.dart).

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:record/record.dart';

import '../vox/wav.dart';
import 'ggwave_ffi.dart';

const int _rate = 48000;

class SoundLink {
  SoundLink._();
  static final SoundLink instance = SoundLink._();

  bool get available => Ggwave.isAvailable;

  AudioPlayer? _player;
  AudioRecorder? _recorder;
  StreamSubscription<Uint8List>? _sub;
  GgwaveReceiver? _rx;
  StreamController<String>? _heard;

  /// While playing (and a moment after), what the microphone hears is our
  /// own tones: not passed on, so a bridge can't echo itself.
  DateTime _deafUntil = DateTime.fromMillisecondsSinceEpoch(0);
  bool _playing = false;
  bool get playing => _playing;

  /// Plays [text] (at most 140 bytes of UTF-8) and completes when it ends.
  Future<void> play(
    String text, {
    GgwaveProtocol protocol = GgwaveProtocol.audibleFast,
    int volume = 60,
  }) async {
    final g = Ggwave.instanceOrNull;
    if (g == null) throw UnsupportedError('Sound link is not in this build');
    final pcm = g.encode(
      Uint8List.fromList(utf8.encode(text)),
      protocol: protocol,
      volume: volume.clamp(1, 100),
      sampleRate: _rate,
    );
    final ms = pcm.length * 1000 ~/ _rate;
    _deafUntil = DateTime.now().add(Duration(milliseconds: ms + 1500));
    final p = _player ??= AudioPlayer();
    final done = Completer<void>();
    final sub = p.onPlayerComplete.listen((_) {
      if (!done.isCompleted) done.complete();
    });
    _playing = true;
    try {
      await p.play(BytesSource(voxPcm16ToWav(pcm, sampleRate: _rate)));
      await done.future.timeout(
        Duration(milliseconds: ms + 3000),
        onTimeout: () {},
      );
    } finally {
      _playing = false;
      await sub.cancel();
      _deafUntil = DateTime.now().add(const Duration(milliseconds: 600));
    }
  }

  bool get listening => _heard != null;

  /// What the microphone hears, as text, until [stopListening].
  Future<Stream<String>> listen() async {
    final g = Ggwave.instanceOrNull;
    if (g == null) throw UnsupportedError('Sound link is not in this build');
    if (_heard != null) return _heard!.stream;
    final rec = _recorder ??= AudioRecorder();
    if (!await rec.hasPermission()) {
      throw StateError('Microphone permission denied');
    }
    final out = _heard = StreamController<String>.broadcast();
    final rx = _rx = g.receiver(sampleRate: _rate);
    final stream = await rec.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: _rate,
        numChannels: 1,
        // Tones, not speech: processing meant for voice would blur them.
        autoGain: false,
        noiseSuppress: false,
        echoCancel: false,
      ),
    );
    var carry = <int>[];
    _sub = stream.listen((bytes) {
      // PCM16 little-endian; a chunk can end mid-sample.
      final all = carry.isEmpty
          ? bytes
          : Uint8List.fromList([...carry, ...bytes]);
      final whole = all.length & ~1;
      carry = whole < all.length ? [all[whole]] : <int>[];
      final pcm = Int16List(whole ~/ 2);
      final bd = ByteData.sublistView(all, 0, whole);
      for (var i = 0; i < pcm.length; i++) {
        pcm[i] = bd.getInt16(i * 2, Endian.little);
      }
      for (final p in rx.add(pcm)) {
        if (DateTime.now().isBefore(_deafUntil)) continue; // our own tones
        out.add(utf8.decode(p, allowMalformed: true));
      }
    });
    return out.stream;
  }

  Future<void> stopListening() async {
    final out = _heard;
    _heard = null;
    await _sub?.cancel();
    _sub = null;
    try {
      await _recorder?.stop();
    } catch (_) {}
    _rx?.close();
    _rx = null;
    await out?.close();
  }
}
