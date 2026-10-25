// MeshCore Open TAK - AI voice enhancement for received Codec2 clips.
//
// Codec2 sends 8 kHz speech, so everything above 4 kHz (the "s", "f" and "t"
// sounds and the air in a voice) is missing and it sounds muffled. The enhancer
// fills that band back in and plays the clip at 48 kHz. What was received
// (below 4 kHz) is played as decoded; only the band above it is generated.
//
// Model: LavaSR's bandwidth-extension enhancer (Vocos backbone and spectrogram
// head), Apache-2.0, Yatharth Sharma, https://github.com/ysharma3501/LavaSR,
// via the ONNX export at https://github.com/Topping1/LavaSR-ONNX. Wrapped by
// scripts/models/voice_bwe_to_onnx.py with its signal processing (upsampling,
// STFT, mel features, the low/high merge and the inverse STFT) into one graph:
// input "pcm" float32 [N] at 8 kHz, output "audio" float32 [6N] at 48 kHz.
// Published as this repo's `voice-bwe-onnx-v1` release, downloaded on first
// use (~28 MB) and checked by SHA-256, like the Mimi voice and photo models.
//
// Playback only: the clip as received is what's stored, forwarded and served.
// Mimi clips are already wideband and are played as they are.

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'voice_dsp.dart';

/// The model file, as published.
class VoxVoiceEnhanceModel {
  static const name = 'lavasr-bwe-8k-48k.onnx';
  static const sha256Hex =
      '23a73ebdec18e122d60d5c5de563b74f9f2559d2564d8e8b5a00c16c1f769df4';
  static const bytes = 28459238;
  static const url =
      'https://github.com/jade-on-mesh/meshcore-open-tak/releases/download/'
      'voice-bwe-onnx-v1/$name';

  /// Output samples per input sample (8 kHz in, 48 kHz out).
  static const upsample = 6;
  static const outRate = voxCodecRate * upsample;

  /// The shortest input the graph takes (its reflect padding needs it).
  static const minSamples = 256;
}

/// The model's input for a decoded 8 kHz clip: levelled as plain playback is
/// ([voxPlayNormGain] from its first 3 s), as floats, padded with silence to
/// [VoxVoiceEnhanceModel.minSamples].
Float32List voxEnhanceInput(Int16List pcm8k) {
  var peak = 0;
  final n3 = min(pcm8k.length, 3 * voxCodecRate);
  for (var i = 0; i < n3; i++) {
    final a = pcm8k[i].abs();
    if (a > peak) peak = a;
  }
  final g = voxPlayNormGain(peak) / 32768.0;
  final out = Float32List(max(pcm8k.length, VoxVoiceEnhanceModel.minSamples));
  for (var i = 0; i < pcm8k.length; i++) {
    out[i] = pcm8k[i] * g;
  }
  return out;
}

/// The model's output as PCM16 for [samples8k] input samples: trimmed of the
/// padding and soft-limited as plain playback is.
Int16List voxEnhanceOutput(List<num> audio, int samples8k) {
  final n = min(audio.length, samples8k * VoxVoiceEnhanceModel.upsample);
  final out = Int16List(n);
  for (var i = 0; i < n; i++) {
    out[i] = voxSoftLimit(audio[i] * 32768.0).round().clamp(-32768, 32767);
  }
  return out;
}

enum VoxVoiceEnhanceState { missing, downloading, ready, failed }

/// Download state and inference for the voice enhancer. One per app.
class VoxVoiceEnhancer extends ChangeNotifier {
  VoxVoiceEnhancer._() {
    unawaited(refresh());
  }
  static final VoxVoiceEnhancer instance = VoxVoiceEnhancer._();

  /// Whether this build can run the model at all (no ONNX Runtime on web).
  static bool get supported => !kIsWeb;

  static int get downloadMb => (VoxVoiceEnhanceModel.bytes / 1e6).round();

  VoxVoiceEnhanceState _state = VoxVoiceEnhanceState.missing;
  double _progress = 0;
  String? _error;
  bool _cancel = false;
  File? _path;

  VoxVoiceEnhanceState get state => _state;
  bool get isReady => _state == VoxVoiceEnhanceState.ready;
  double get progress => _progress;
  String? get error => _error;

  Future<File> _file() async {
    if (_path != null) return _path!;
    final base = await getApplicationSupportDirectory();
    final d = Directory('${base.path}${Platform.pathSeparator}vox_voice_bwe');
    if (!await d.exists()) await d.create(recursive: true);
    return _path = File(
      '${d.path}${Platform.pathSeparator}${VoxVoiceEnhanceModel.name}',
    );
  }

  Future<void> refresh() async {
    if (!supported || _state == VoxVoiceEnhanceState.downloading) return;
    try {
      final f = await _file();
      _state =
          await f.exists() && await f.length() == VoxVoiceEnhanceModel.bytes
          ? VoxVoiceEnhanceState.ready
          : VoxVoiceEnhanceState.missing;
    } catch (_) {
      _state = VoxVoiceEnhanceState.missing;
    }
    notifyListeners();
  }

  void cancelDownload() => _cancel = true;

  /// Downloads and checks the model.
  Future<void> download() async {
    if (!supported || _state == VoxVoiceEnhanceState.downloading || isReady) {
      return;
    }
    _state = VoxVoiceEnhanceState.downloading;
    _progress = 0;
    _error = null;
    _cancel = false;
    notifyListeners();
    final client = http.Client();
    File? part;
    try {
      final dest = await _file();
      part = File('${dest.path}.part');
      final resp = await client.send(
        http.Request('GET', Uri.parse(VoxVoiceEnhanceModel.url)),
      );
      if (resp.statusCode != 200) {
        throw HttpException('HTTP ${resp.statusCode}');
      }
      final sink = part.openWrite();
      var done = 0;
      try {
        await for (final c in resp.stream) {
          if (_cancel) throw const _Cancelled();
          sink.add(c);
          done += c.length;
          _progress = done / VoxVoiceEnhanceModel.bytes;
          notifyListeners();
        }
      } finally {
        await sink.close();
      }
      final digest = await sha256.bind(part.openRead()).first;
      if (digest.toString() != VoxVoiceEnhanceModel.sha256Hex) {
        throw StateError('the download failed its checksum');
      }
      if (await dest.exists()) await dest.delete();
      await part.rename(dest.path);
      _state = VoxVoiceEnhanceState.ready;
    } on _Cancelled {
      _state = VoxVoiceEnhanceState.missing;
    } catch (e) {
      _state = VoxVoiceEnhanceState.failed;
      _error = '$e';
    } finally {
      client.close();
      try {
        if (part != null && await part.exists()) await part.delete();
      } catch (_) {}
      notifyListeners();
    }
  }

  Future<void> deleteModel() async {
    await _close();
    final f = await _file();
    if (await f.exists()) await f.delete();
    _state = VoxVoiceEnhanceState.missing;
    notifyListeners();
  }

  final OnnxRuntime _runtime = OnnxRuntime();
  OrtSession? _session;
  Timer? _idle;
  Future<void> _lock = Future.value();

  Future<void> _close() async {
    final s = _session;
    _session = null;
    try {
      await s?.close();
    } catch (_) {}
  }

  /// [pcm8k] (decoded Codec2) enhanced: PCM16 at
  /// [VoxVoiceEnhanceModel.outRate], six samples for each one in.
  Future<Int16List> enhance(Int16List pcm8k) {
    final c = Completer<Int16List>();
    _lock = _lock.then((_) async {
      try {
        c.complete(await _enhance(pcm8k));
      } catch (e, st) {
        c.completeError(e, st);
      }
    });
    return c.future;
  }

  Future<Int16List> _enhance(Int16List pcm8k) async {
    if (!isReady) throw StateError('The voice enhancer is not downloaded');
    _idle?.cancel();
    final session = _session ??= await _runtime.createSession(
      (await _file()).path,
    );
    final x = voxEnhanceInput(pcm8k);
    final input = await OrtValue.fromList(x, [x.length]);
    final outputs = <OrtValue>[];
    try {
      final result = await session.run({'pcm': input});
      outputs.addAll(result.values);
      final y = await result['audio']!.asFlattenedList();
      return voxEnhanceOutput(y.cast<num>(), pcm8k.length);
    } finally {
      await input.dispose();
      for (final o in outputs) {
        await o.dispose();
      }
      // The session holds the model (~56 MB in memory); let it go when no
      // clip has been played for a while.
      _idle = Timer(const Duration(seconds: 90), () => unawaited(_close()));
    }
  }
}

class _Cancelled implements Exception {
  const _Cancelled();
}
