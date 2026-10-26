// MeshCore Open TAK - the AI voice restorer for received Codec2 clips.
//
// Codec2 sends 8 kHz speech that sounds buzzy and robotic, with nothing above
// 4 kHz (the "s", "f" and "t" sounds and the air in a voice). The restorer
// rebuilds the whole voice from it and plays the clip at 48 kHz.
//
// Model: LavaSR's bandwidth-extension enhancer (Vocos backbone and spectrogram
// head; Apache-2.0, Yatharth Sharma, https://github.com/ysharma3501/LavaSR, via
// https://github.com/Topping1/LavaSR-ONNX), fine-tuned on Codec2 itself (VCTK,
// CC-BY-4.0) with tools/voice-training and exported through
// scripts/models/voice_bwe_to_onnx.py with its 4 kHz merge off: one graph,
// input "pcm" float32 [N] at 8 kHz, output "audio" float32 [6N] at 48 kHz.
// Published as this repo's `voice-restorer-onnx-v1` release, downloaded once
// (~28 MB, on Wi-Fi on first open) and checked by SHA-256, like the Mimi voice
// and photo models. It replaced the plain enhancer (`voice-bwe-onnx-v1`,
// treble only); that model's file is deleted from phones that had it.
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

/// A voice model file, as published. Both take 8 kHz in and give 48 kHz out.
class VoxVoiceModelSpec {
  const VoxVoiceModelSpec({
    required this.name,
    required this.sha256Hex,
    required this.bytes,
    required this.tag,
    required this.dir,
  });
  final String name;
  final String sha256Hex;
  final int bytes;

  /// This repo's release it's published in.
  final String tag;

  /// Folder under the app's support directory.
  final String dir;

  String get url =>
      'https://github.com/jade-on-mesh/meshcore-open-tak/releases/download/'
      '$tag/$name';
}

/// The voice model and its shape.
class VoxVoiceEnhanceModel {
  /// The folder the old treble-only enhancer was kept in (deleted).
  static const oldEnhancerDir = 'vox_voice_bwe';

  /// The voice restorer (the whole voice), trained with tools/voice-training.
  static const restorer = VoxVoiceModelSpec(
    name: 'codec2-restorer-8k-48k.onnx',
    sha256Hex:
        'abc0e80e32a83a4fc964cdba62ad0288a86f34c7ac2eb32c3465e9f4d5f3578e',
    bytes: 28318025,
    tag: 'voice-restorer-onnx-v1',
    dir: 'vox_voice_restorer',
  );

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

/// Download state and inference for one voice model. One of each per app.
class VoxVoiceEnhancer extends ChangeNotifier {
  VoxVoiceEnhancer._(this.spec) {
    unawaited(refresh());
  }

  /// The voice restorer: rebuilds the whole voice.
  static final VoxVoiceEnhancer restorer = VoxVoiceEnhancer._(
    VoxVoiceEnhanceModel.restorer,
  );

  final VoxVoiceModelSpec spec;

  /// Deletes the old treble-only enhancer's model (~28 MB) from phones that
  /// downloaded it; the restorer replaced it.
  static Future<void> deleteOldEnhancer() async {
    if (!supported) return;
    try {
      final base = await getApplicationSupportDirectory();
      final d = Directory(
        '${base.path}${Platform.pathSeparator}'
        '${VoxVoiceEnhanceModel.oldEnhancerDir}',
      );
      if (await d.exists()) await d.delete(recursive: true);
    } catch (_) {}
  }

  /// Whether this build can run the model at all (no ONNX Runtime on web).
  static bool get supported => !kIsWeb;

  int get downloadMb => (spec.bytes / 1e6).round();

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
    final d = Directory('${base.path}${Platform.pathSeparator}${spec.dir}');
    if (!await d.exists()) await d.create(recursive: true);
    return _path = File('${d.path}${Platform.pathSeparator}${spec.name}');
  }

  Future<void> refresh() async {
    if (!supported || _state == VoxVoiceEnhanceState.downloading) return;
    try {
      final f = await _file();
      _state = await f.exists() && await f.length() == spec.bytes
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
      final resp = await client.send(http.Request('GET', Uri.parse(spec.url)));
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
          _progress = done / spec.bytes;
          notifyListeners();
        }
      } finally {
        await sink.close();
      }
      final digest = await sha256.bind(part.openRead()).first;
      if (digest.toString() != spec.sha256Hex) {
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
    if (!isReady) throw StateError('${spec.name} is not downloaded');
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
