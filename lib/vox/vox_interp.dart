// MeshCore Open TAK - AI frame interpolation ("Smooth motion") for video
// messages: the receiving phone makes the frames in between the ones that
// were sent, so a 6 or 12 fps clip plays at about 24.
//
// Model: RIFE 4.9 (IFNet, arch 4.7), Practical-RIFE, MIT, Copyright (c) 2021
// hzwer, https://github.com/hzwer/Practical-RIFE. Converted to ONNX by
// scripts/models/rife_to_onnx.py: inputs "img0", "img1" [1,3,H,W] RGB 0..1
// (H, W multiples of 64) and "timestep" [1,1,1,1], output "frame" [1,3,H,W].
// Published as this repo's `interp-onnx-v1` release
// (.github/workflows/interp-model.yml), downloaded on first use (~21 MB) and
// checked by SHA-256, like the photo enhancer.
//
// Display only: the clip as received is what's stored and forwarded. The
// player says the in-between frames are made up.

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'video_codec.dart';

/// The model file, as published.
class VoxInterpModel {
  static const name = 'rife49.onnx';
  static const sha256Hex =
      '5c5db0d4c18459fcbeb41cf48a336e579ddeda31cc622c6dc54bc5f4aaa3ae5b';
  static const bytes = 21432542;
  static const url =
      'https://github.com/jade-on-mesh/meshcore-open-tak/releases/download/'
      'interp-onnx-v1/$name';
}

/// Frame rate Smooth motion aims for.
const int voxInterpTargetFps = 24;

/// How many frames each sent frame becomes (2 to 4), for a clip at [fps],
/// keeping the result to at most [maxFrames] when it has [count] frames.
int voxInterpMultiple(int fps, int count, {int maxFrames = 720}) {
  var m = (voxInterpTargetFps / max(1, fps)).round().clamp(1, 4);
  while (m > 1 && (count - 1) * m + 1 > maxFrames) {
    m--;
  }
  return m;
}

/// Frame [i] of [f] as the model's input: planar RGB 0..1, [pw] x [ph]
/// (multiples of 64), edges repeated into the padding.
Float32List voxInterpInput(VoxVideoFrames f, int i, int pw, int ph) {
  final w = f.width, h = f.height, plane = pw * ph;
  final out = Float32List(3 * plane);
  final base = i * f.frameBytes;
  for (var y = 0; y < ph; y++) {
    final sy = min(y, h - 1);
    for (var x = 0; x < pw; x++) {
      final sx = min(x, w - 1);
      final s = base + (sy * w + sx) * 3;
      final d = y * pw + x;
      out[d] = f.rgb[s] / 255.0;
      out[plane + d] = f.rgb[s + 1] / 255.0;
      out[2 * plane + d] = f.rgb[s + 2] / 255.0;
    }
  }
  return out;
}

/// The model's output [y] (planar, [pw] x [ph]) cropped to [w] x [h] RGB888
/// into [out] at [offset].
void voxInterpWrite(
  List<num> y,
  int pw,
  int ph,
  int w,
  int h,
  Uint8List out,
  int offset,
) {
  final plane = pw * ph;
  int px(num v) {
    final i = (v * 255.0 + 0.5).floor();
    return i < 0 ? 0 : (i > 255 ? 255 : i);
  }

  for (var yy = 0; yy < h; yy++) {
    for (var xx = 0; xx < w; xx++) {
      final s = yy * pw + xx, d = offset + (yy * w + xx) * 3;
      out[d] = px(y[s]);
      out[d + 1] = px(y[plane + s]);
      out[d + 2] = px(y[2 * plane + s]);
    }
  }
}

enum VoxInterpState { missing, downloading, ready, failed }

/// Download state and inference for the interpolation model. One per app.
class VoxInterpolator extends ChangeNotifier {
  VoxInterpolator._() {
    unawaited(refresh());
  }
  static final VoxInterpolator instance = VoxInterpolator._();

  /// Whether this build can run the model at all (no ONNX Runtime on web).
  static bool get supported => !kIsWeb;

  static int get downloadMb => (VoxInterpModel.bytes / 1e6).round();

  VoxInterpState _state = VoxInterpState.missing;
  double _progress = 0;
  String? _error;
  File? _path;

  VoxInterpState get state => _state;
  bool get isReady => _state == VoxInterpState.ready;
  double get progress => _progress;
  String? get error => _error;

  Future<File> _file() async {
    if (_path != null) return _path!;
    final base = await getApplicationSupportDirectory();
    final d = Directory('${base.path}${Platform.pathSeparator}vox_interp');
    if (!await d.exists()) await d.create(recursive: true);
    return _path = File(
      '${d.path}${Platform.pathSeparator}${VoxInterpModel.name}',
    );
  }

  Future<void> refresh() async {
    if (!supported || _state == VoxInterpState.downloading) return;
    try {
      final f = await _file();
      _state = await f.exists() && await f.length() == VoxInterpModel.bytes
          ? VoxInterpState.ready
          : VoxInterpState.missing;
    } catch (_) {
      _state = VoxInterpState.missing;
    }
    notifyListeners();
  }

  /// Downloads and checks the model.
  Future<void> download() async {
    if (!supported || _state == VoxInterpState.downloading || isReady) return;
    _state = VoxInterpState.downloading;
    _progress = 0;
    _error = null;
    notifyListeners();
    final client = http.Client();
    try {
      final dest = await _file();
      final part = File('${dest.path}.part');
      final resp = await client.send(
        http.Request('GET', Uri.parse(VoxInterpModel.url)),
      );
      if (resp.statusCode != 200) {
        throw HttpException('HTTP ${resp.statusCode}');
      }
      final sink = part.openWrite();
      var done = 0;
      try {
        await for (final c in resp.stream) {
          sink.add(c);
          done += c.length;
          _progress = done / VoxInterpModel.bytes;
          notifyListeners();
        }
      } finally {
        await sink.close();
      }
      final digest = await sha256.bind(part.openRead()).first;
      if (digest.toString() != VoxInterpModel.sha256Hex) {
        await part.delete();
        throw StateError('the download failed its checksum');
      }
      if (await dest.exists()) await dest.delete();
      await part.rename(dest.path);
      _state = VoxInterpState.ready;
    } catch (e) {
      _state = VoxInterpState.failed;
      _error = '$e';
    } finally {
      client.close();
      notifyListeners();
    }
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

  /// [f] with [multiple] - 1 made-up frames between each pair it has, at
  /// [multiple] times the frame rate. [onProgress] gets 0..1.
  Future<VoxVideoFrames> interpolate(
    VoxVideoFrames f,
    int multiple, {
    void Function(double)? onProgress,
  }) {
    final c = Completer<VoxVideoFrames>();
    _lock = _lock.then((_) async {
      try {
        c.complete(await _interpolate(f, multiple, onProgress));
      } catch (e, st) {
        c.completeError(e, st);
      }
    });
    return c.future;
  }

  Future<VoxVideoFrames> _interpolate(
    VoxVideoFrames f,
    int m,
    void Function(double)? onProgress,
  ) async {
    if (m < 2 || f.count < 2) return f;
    if (!isReady) throw StateError('Smooth motion is not downloaded');
    _idle?.cancel();
    final session = _session ??= await _runtime.createSession(
      (await _file()).path,
    );
    final w = f.width, h = f.height;
    final pw = (w + 63) ~/ 64 * 64, ph = (h + 63) ~/ 64 * 64;
    final n = (f.count - 1) * m + 1;
    final out = Uint8List(n * f.frameBytes);
    final shape = [1, 3, ph, pw];
    var next = voxInterpInput(f, 0, pw, ph);
    var done = 0;
    final total = (f.count - 1) * (m - 1);
    for (var i = 0; i < f.count - 1; i++) {
      final a = next;
      next = voxInterpInput(f, i + 1, pw, ph);
      out.setRange(
        i * m * f.frameBytes,
        (i * m + 1) * f.frameBytes,
        f.rgb,
        i * f.frameBytes,
      );
      for (var k = 1; k < m; k++) {
        final inputs = {
          'img0': await OrtValue.fromList(a, shape),
          'img1': await OrtValue.fromList(next, shape),
          'timestep': await OrtValue.fromList(Float32List.fromList([k / m]), [
            1,
            1,
            1,
            1,
          ]),
        };
        final outputs = <OrtValue>[];
        try {
          final result = await session.run(inputs);
          outputs.addAll(result.values);
          final y = await result['frame']!.asFlattenedList();
          voxInterpWrite(
            y.cast<num>(),
            pw,
            ph,
            w,
            h,
            out,
            (i * m + k) * f.frameBytes,
          );
        } finally {
          for (final v in inputs.values) {
            await v.dispose();
          }
          for (final o in outputs) {
            await o.dispose();
          }
        }
        onProgress?.call(++done / total);
      }
    }
    out.setRange(
      (n - 1) * f.frameBytes,
      n * f.frameBytes,
      f.rgb,
      (f.count - 1) * f.frameBytes,
    );
    // The session holds ~100 MB; let it go when the player has been idle.
    _idle = Timer(const Duration(seconds: 60), () => unawaited(_close()));
    return VoxVideoFrames(w, h, f.fps * m, out);
  }
}
