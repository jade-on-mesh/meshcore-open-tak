// MeshCore Open TAK - Mimi neural voice codec (Kyutai, CC-BY 4.0).
//
// The ONNX encoder/decoder (~223 MB together) are downloaded on first use
// from this repo's `mimi-onnx-v1` release and verified by SHA-256. Both
// graphs take a fixed 20 s; clips are padded with silence and trimmed.
//
// Sessions are opened on demand and closed again after a short idle period,
// because together they hold several hundred MB of fp32 weights in RAM.

import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'voice_wire.dart';

class VoxMimiFile {
  final String name;
  final String sha256;
  final int bytes;
  const VoxMimiFile(this.name, this.sha256, this.bytes);

  String get url =>
      'https://github.com/jade-on-mesh/meshcore-open-tak/releases/download/'
      'mimi-onnx-v1/$name';
}

const voxMimiEncoderFile = VoxMimiFile(
  'mimi_encoder_fp16.onnx',
  'd36a126fdcf47dd9e2bae2730d9dbd5a68c77f9be1dc1298ff9a4750af5241ae',
  124824482,
);
const voxMimiDecoderFile = VoxMimiFile(
  'mimi_decoder_fp16.onnx',
  'dd4b185fb4103261313157c31b5e65e5715605a3604f9bfb085c1d807d2b5ba6',
  97817328,
);
const _files = [voxMimiEncoderFile, voxMimiDecoderFile];

enum VoxMimiState { missing, downloading, ready, failed }

/// Download state and on-device inference for the Mimi model.
class VoxMimi extends ChangeNotifier {
  VoxMimi() {
    unawaited(refresh());
  }

  VoxMimiState _state = VoxMimiState.missing;
  double _progress = 0;
  String? _error;
  bool _cancel = false;
  Directory? _dir;

  VoxMimiState get state => _state;
  bool get isReady => _state == VoxMimiState.ready;
  double get progress => _progress;
  String? get error => _error;

  /// Total download size in MB, for the UI.
  static int get downloadMb =>
      (_files.fold<int>(0, (a, f) => a + f.bytes) / 1e6).round();

  Future<Directory> _modelDir() async {
    if (_dir != null) return _dir!;
    final base = await getApplicationSupportDirectory();
    final d = Directory('${base.path}${Platform.pathSeparator}vox_mimi');
    if (!await d.exists()) await d.create(recursive: true);
    return _dir = d;
  }

  Future<File> _file(VoxMimiFile f) async =>
      File('${(await _modelDir()).path}${Platform.pathSeparator}${f.name}');

  /// Re-checks which files are present (sizes only; hashes are checked at
  /// download time).
  Future<void> refresh() async {
    if (_state == VoxMimiState.downloading) return;
    var ok = true;
    for (final f in _files) {
      final file = await _file(f);
      if (!await file.exists() ||
          (f.bytes > 0 && await file.length() != f.bytes)) {
        ok = false;
      }
    }
    _state = ok ? VoxMimiState.ready : VoxMimiState.missing;
    notifyListeners();
  }

  /// Downloads and verifies both model files.
  Future<void> download() async {
    if (_state == VoxMimiState.downloading || isReady) return;
    _state = VoxMimiState.downloading;
    _progress = 0;
    _error = null;
    _cancel = false;
    notifyListeners();
    final client = http.Client();
    try {
      final total = _files.fold<int>(0, (a, f) => a + f.bytes);
      var done = 0;
      for (final f in _files) {
        final dest = await _file(f);
        if (await dest.exists() && await _hashOk(dest, f)) {
          done += f.bytes;
          continue;
        }
        final part = File('${dest.path}.part');
        final resp = await client.send(http.Request('GET', Uri.parse(f.url)));
        if (resp.statusCode != 200) {
          throw HttpException('HTTP ${resp.statusCode} for ${f.name}');
        }
        final sink = part.openWrite();
        final digestOut = _DigestSink();
        final hasher = sha256.startChunkedConversion(digestOut);
        try {
          await for (final chunk in resp.stream) {
            if (_cancel) throw const _Cancelled();
            sink.add(chunk);
            hasher.add(chunk);
            done += chunk.length;
            if (total > 0) _progress = done / total;
            notifyListeners();
          }
        } finally {
          await sink.close();
          hasher.close();
        }
        if (digestOut.value.toString() != f.sha256) {
          await part.delete();
          throw StateError('${f.name} failed its checksum');
        }
        await part.rename(dest.path);
      }
      _state = VoxMimiState.ready;
    } on _Cancelled {
      _state = VoxMimiState.missing;
    } catch (e) {
      _state = VoxMimiState.failed;
      _error = '$e';
    } finally {
      client.close();
      notifyListeners();
    }
  }

  void cancelDownload() => _cancel = true;

  Future<void> deleteModel() async {
    await _closeSessions();
    for (final f in _files) {
      final file = await _file(f);
      if (await file.exists()) await file.delete();
    }
    _state = VoxMimiState.missing;
    notifyListeners();
  }

  Future<bool> _hashOk(File file, VoxMimiFile f) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString() == f.sha256;
  }

  // ------------------------------------------------------------ inference

  final OnnxRuntime _runtime = OnnxRuntime();
  OrtSession? _encoder;
  OrtSession? _decoder;
  Timer? _idle;
  Future<void> _lock = Future.value();

  Future<T> _serialized<T>(Future<T> Function() job) {
    final c = Completer<T>();
    _lock = _lock.then((_) async {
      try {
        c.complete(await job());
      } catch (e, st) {
        c.completeError(e, st);
      }
    });
    return c.future;
  }

  void _touch() {
    _idle?.cancel();
    _idle = Timer(const Duration(seconds: 60), () {
      unawaited(_serialized(_closeSessions));
    });
  }

  Future<void> _closeSessions() async {
    final e = _encoder, d = _decoder;
    _encoder = null;
    _decoder = null;
    for (final s in [e, d]) {
      try {
        await s?.close();
      } catch (_) {}
    }
  }

  /// 24 kHz float audio (any length up to 20 s) -> packed codes,
  /// [VoxMimiSpec.bytesPerFrame] bytes per 80 ms frame.
  Future<Uint8List> encode(Float32List audio24k) => _serialized(() async {
    if (!isReady) throw StateError('Mimi model not downloaded');
    final enc = _encoder ??= await _runtime.createSession(
      (await _file(voxMimiEncoderFile)).path,
    );
    _touch();
    final frames = VoxMimiSpec.framesFor(audio24k.length);
    final padded = Float32List(VoxMimiSpec.maxSamples)
      ..setRange(0, audio24k.length.clamp(0, VoxMimiSpec.maxSamples), audio24k);
    final input = await OrtValue.fromList(padded, [
      1,
      1,
      VoxMimiSpec.maxSamples,
    ]);
    final outputs = <OrtValue>[];
    try {
      final result = await enc.run({'audio': input});
      outputs.addAll(result.values);
      final codes = await (result['codes'] ?? result.values.first)
          .asFlattenedList();
      return voxPackMimiCodes(
        [for (final c in codes) (c as num).toInt()],
        frames,
        stride: VoxMimiSpec.maxFrames,
      );
    } finally {
      await input.dispose();
      for (final o in outputs) {
        await o.dispose();
      }
    }
  });

  /// Packed codes -> 24 kHz float audio, trimmed to the clip length.
  Future<Float32List> decode(Uint8List packed) => _serialized(() async {
    if (!isReady) throw StateError('Mimi model not downloaded');
    final dec = _decoder ??= await _runtime.createSession(
      (await _file(voxMimiDecoderFile)).path,
    );
    _touch();
    final frames = (packed.length ~/ VoxMimiSpec.bytesPerFrame).clamp(
      0,
      VoxMimiSpec.maxFrames,
    );
    final input = await OrtValue.fromList(voxUnpackMimiCodes(packed), [
      1,
      VoxMimiSpec.codebooks,
      VoxMimiSpec.maxFrames,
    ]);
    final outputs = <OrtValue>[];
    try {
      final result = await dec.run({'codes': input});
      outputs.addAll(result.values);
      final flat = await (result['audio'] ?? result.values.first)
          .asFlattenedList();
      final n = (frames * VoxMimiSpec.frameSamples).clamp(0, flat.length);
      final out = Float32List(n);
      for (var i = 0; i < n; i++) {
        out[i] = (flat[i] as num).toDouble();
      }
      return out;
    } finally {
      await input.dispose();
      for (final o in outputs) {
        await o.dispose();
      }
    }
  });

  @override
  void dispose() {
    _idle?.cancel();
    unawaited(_closeSessions());
    super.dispose();
  }
}

class _Cancelled implements Exception {
  const _Cancelled();
}

class _DigestSink implements Sink<Digest> {
  late Digest value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}
