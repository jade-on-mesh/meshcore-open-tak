// MeshCore Open TAK - AI photo enhancement (4x super-resolution) for the
// photo viewer.
//
// Model: Real-ESRGAN realesr-general-x4v3 (SRVGGNetCompact), BSD-3-Clause,
// Copyright (c) 2021 Xintao Wang, https://github.com/xinntao/Real-ESRGAN.
// Converted to ONNX by scripts/models/realesr_to_onnx.py (no PyTorch needed):
// input "input" [1,3,H,W] RGB 0..1, outputs "output" [1,3,4H,4W] and
// "output_x2" [1,3,2H,2W] (the same, 2x2 averaged). Published as this repo's
// `upscale-onnx-v2` release, downloaded on first use (~5 MB) and checked by
// SHA-256, like the Mimi voice model.
//
// Sharp and Super Sharp photos open enhanced on their own once the model is
// here (voxPhotoIsSharp); any photo can be enhanced from the viewer's button.
//
// Display only: the stored photo, the chat bubble and anything forwarded stay
// the photo as received. The viewer says the enhanced view may invent detail.

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// The model file, as published.
class VoxUpscaleModel {
  static const name = 'realesr-general-x4v3.onnx';
  static const sha256Hex =
      'a42df91ba5418c2b2b51eb70b7b0eef8ced79251eee586ccf36fb0494a8831fe';
  static const bytes = 4860599;
  static const url =
      'https://github.com/jade-on-mesh/meshcore-open-tak/releases/download/'
      'upscale-onnx-v2/$name';
  static const scale = 4;
}

/// Photos up to this many pixels a side are enhanced 4x (up to 2048 px).
const voxUpscaleMaxSide4x = 512;

/// Photos up to this many pixels a side can be enhanced: those over
/// [voxUpscaleMaxSide4x] (Sharp is up to 768, Super Sharp 1024) 2x, from the
/// model's averaged output, so the result stays within 2048 px.
const voxUpscaleMaxSide = 1024;

/// How much a photo of this size is enlarged: 4, 2, or 0 (not at all).
int voxUpscaleScale(int width, int height) {
  final side = max(width, height);
  if (width <= 0 || height <= 0 || side > voxUpscaleMaxSide) return 0;
  return side <= voxUpscaleMaxSide4x ? 4 : 2;
}

/// A Sharp or Super Sharp photo (71 or up to 247 packets; More detail is 36):
/// the viewer opens these enhanced when the model is on the device.
const voxSharpMinPackets = 50;
bool voxPhotoIsSharp(int totalPackets) => totalPackets >= voxSharpMinPackets;

/// Square tiles the image is enhanced in, so memory stays small. Each gets
/// [voxUpscaleTilePad] pixels of context on every side, cropped away again: the
/// network sees 34 pixels around each one, and with 32 the tiles join without
/// a visible seam (measured: at most 1/255 from a whole-image pass; 8 left
/// seams up to 20/255).
const voxUpscaleTile = 160;
const voxUpscaleTilePad = 32;

/// One tile: the part of the output it fills ([x], [y], [w], [h] in input
/// pixels) and the input region the model sees for it ([rx]..[rx]+[rw]).
@immutable
class VoxUpscaleTile {
  final int x, y, w, h;
  final int rx, ry, rw, rh;
  const VoxUpscaleTile(
    this.x,
    this.y,
    this.w,
    this.h,
    this.rx,
    this.ry,
    this.rw,
    this.rh,
  );
}

/// The tiles covering a [width] x [height] image, row by row.
List<VoxUpscaleTile> voxUpscaleTiles(
  int width,
  int height, {
  int tile = voxUpscaleTile,
  int pad = voxUpscaleTilePad,
}) {
  final out = <VoxUpscaleTile>[];
  for (var y = 0; y < height; y += tile) {
    for (var x = 0; x < width; x += tile) {
      final w = min(tile, width - x), h = min(tile, height - y);
      final rx = max(0, x - pad), ry = max(0, y - pad);
      final rx1 = min(width, x + w + pad), ry1 = min(height, y + h + pad);
      out.add(VoxUpscaleTile(x, y, w, h, rx, ry, rx1 - rx, ry1 - ry));
    }
  }
  return out;
}

/// The model's input for [t]: planar RGB in 0..1, from [rgba] (width [width]).
Float32List voxUpscaleInput(Uint8List rgba, int width, VoxUpscaleTile t) {
  final plane = t.rw * t.rh;
  final out = Float32List(3 * plane);
  for (var yy = 0; yy < t.rh; yy++) {
    var src = ((t.ry + yy) * width + t.rx) * 4;
    var dst = yy * t.rw;
    for (var xx = 0; xx < t.rw; xx++, src += 4, dst++) {
      out[dst] = rgba[src] / 255.0;
      out[plane + dst] = rgba[src + 1] / 255.0;
      out[2 * plane + dst] = rgba[src + 2] / 255.0;
    }
  }
  return out;
}

/// Copies the part of the model's output [y] (planar RGB, [s]x the tile's
/// region) that belongs to [t] into [out] (RGBA, [s] x [width] wide).
void voxUpscaleWrite(
  List<num> y,
  VoxUpscaleTile t,
  Uint8List out,
  int width, {
  int s = VoxUpscaleModel.scale,
}) {
  final ow = t.rw * s, plane = ow * t.rh * s;
  final outW = width * s;
  final offX = (t.x - t.rx) * s, offY = (t.y - t.ry) * s;
  int px(num v) {
    final i = (v * 255.0 + 0.5).floor();
    return i < 0 ? 0 : (i > 255 ? 255 : i);
  }

  for (var yy = 0; yy < t.h * s; yy++) {
    var src = (offY + yy) * ow + offX;
    var dst = ((t.y * s + yy) * outW + t.x * s) * 4;
    for (var xx = 0; xx < t.w * s; xx++, src++, dst += 4) {
      out[dst] = px(y[src]);
      out[dst + 1] = px(y[plane + src]);
      out[dst + 2] = px(y[2 * plane + src]);
      out[dst + 3] = 255;
    }
  }
}

enum VoxUpscaleState { missing, downloading, ready, failed }

/// Download state and inference for the enhancement model. One per app.
class VoxUpscaler extends ChangeNotifier {
  VoxUpscaler._() {
    unawaited(refresh());
  }
  static final VoxUpscaler instance = VoxUpscaler._();

  /// Whether this build can run the model at all (no ONNX Runtime on web).
  static bool get supported => !kIsWeb;

  /// Whether a photo of this size can be enhanced.
  static bool canEnhance(int width, int height) =>
      supported && voxUpscaleScale(width, height) > 0;

  static int get downloadMb => (VoxUpscaleModel.bytes / 1e6).round();

  VoxUpscaleState _state = VoxUpscaleState.missing;
  double _progress = 0;
  String? _error;
  File? _path;

  VoxUpscaleState get state => _state;
  bool get isReady => _state == VoxUpscaleState.ready;
  double get progress => _progress;
  String? get error => _error;

  Future<File> _file() async {
    if (_path != null) return _path!;
    final base = await getApplicationSupportDirectory();
    final d = Directory('${base.path}${Platform.pathSeparator}vox_upscale');
    if (!await d.exists()) await d.create(recursive: true);
    return _path = File(
      '${d.path}${Platform.pathSeparator}${VoxUpscaleModel.name}',
    );
  }

  Future<void> refresh() async {
    if (!supported || _state == VoxUpscaleState.downloading) return;
    try {
      final f = await _file();
      final there = await f.exists();
      _state = there && await f.length() == VoxUpscaleModel.bytes
          ? VoxUpscaleState.ready
          : VoxUpscaleState.missing;
      // An older model is here: it was downloaded on purpose, so fetch the
      // current one in the background (it replaces the file when checked).
      if (there && _state == VoxUpscaleState.missing) {
        unawaited(Future(download));
      }
    } catch (_) {
      _state = VoxUpscaleState.missing;
    }
    notifyListeners();
  }

  /// Downloads and checks the model.
  Future<void> download() async {
    if (!supported || _state == VoxUpscaleState.downloading || isReady) return;
    _state = VoxUpscaleState.downloading;
    _progress = 0;
    _error = null;
    notifyListeners();
    final client = http.Client();
    try {
      final dest = await _file();
      final part = File('${dest.path}.part');
      final resp = await client.send(
        http.Request('GET', Uri.parse(VoxUpscaleModel.url)),
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
          _progress = done / VoxUpscaleModel.bytes;
          notifyListeners();
        }
      } finally {
        await sink.close();
      }
      final digest = await sha256.bind(part.openRead()).first;
      if (digest.toString() != VoxUpscaleModel.sha256Hex) {
        await part.delete();
        throw StateError('the download failed its checksum');
      }
      if (await dest.exists()) await dest.delete(); // an older model
      await part.rename(dest.path);
      _state = VoxUpscaleState.ready;
    } catch (e) {
      _state = VoxUpscaleState.failed;
      _error = '$e';
    } finally {
      client.close();
      notifyListeners();
    }
  }

  Future<void> deleteModel() async {
    await _close();
    final f = await _file();
    if (await f.exists()) await f.delete();
    _state = VoxUpscaleState.missing;
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

  /// [image] enhanced, 4x or 2x ([voxUpscaleScale]). [onProgress] gets 0..1
  /// as tiles finish.
  Future<ui.Image> enhance(
    ui.Image image, {
    void Function(double)? onProgress,
  }) {
    final c = Completer<ui.Image>();
    _lock = _lock.then((_) async {
      try {
        c.complete(await _enhance(image, onProgress));
      } catch (e, st) {
        c.completeError(e, st);
      }
    });
    return c.future;
  }

  Future<ui.Image> _enhance(
    ui.Image image,
    void Function(double)? onProgress,
  ) async {
    if (!isReady) throw StateError('The enhancer is not downloaded');
    final w = image.width, h = image.height;
    if (!canEnhance(w, h)) throw StateError('This photo is already full size');
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) throw StateError('Could not read the photo');
    final rgba = data.buffer.asUint8List();
    _idle?.cancel();
    final session = _session ??= await _runtime.createSession(
      (await _file()).path,
    );
    final s = voxUpscaleScale(w, h);
    final outName = s == 4 ? 'output' : 'output_x2';
    final out = Uint8List(w * s * h * s * 4);
    final tiles = voxUpscaleTiles(w, h);
    for (var i = 0; i < tiles.length; i++) {
      final t = tiles[i];
      final input = await OrtValue.fromList(voxUpscaleInput(rgba, w, t), [
        1,
        3,
        t.rh,
        t.rw,
      ]);
      final outputs = <OrtValue>[];
      try {
        final result = await session.run({'input': input});
        outputs.addAll(result.values);
        final y = await result[outName]!.asFlattenedList();
        voxUpscaleWrite(y.cast<num>(), t, out, w, s: s);
      } finally {
        await input.dispose();
        for (final o in outputs) {
          await o.dispose();
        }
      }
      onProgress?.call((i + 1) / tiles.length);
    }
    // The session holds a few MB; let it go when the viewer has been idle.
    _idle = Timer(const Duration(seconds: 60), () => unawaited(_close()));
    final done = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      out,
      w * s,
      h * s,
      ui.PixelFormat.rgba8888,
      done.complete,
    );
    return done.future;
  }
}
