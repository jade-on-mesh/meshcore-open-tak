// MeshCore Open TAK - reads a picked video as frames and sound for
// video_codec.dart: android/.../VoxVideoChannel.kt on Android,
// MeshVideoReader in ios/Runner/AppDelegate.swift on iPhone.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'video_codec.dart';

/// A picked clip, read for encoding.
class VoxPickedVideo {
  /// At most [voxVideoSourceSide] px at [voxVideoSourceFps].
  final VoxVideoFrames frames;

  /// 48 kHz mono, or null when the clip has no sound (or it can't be read).
  final Int16List? sound;
  const VoxPickedVideo(this.frames, this.sound);
}

class VoxVideoSource {
  VoxVideoSource._();

  static const _channel = MethodChannel('meshcore_open/vox_video');

  /// Videos can be picked and sent from this device.
  static bool get isSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  /// Reads the first [voxVideoMaxSeconds] of the video at [path].
  static Future<VoxPickedVideo> read(String path) async {
    final r = await _channel.invokeMapMethod<String, Object?>('extract', {
      'path': path,
      'maxSide': voxVideoSourceSide,
      'fps': voxVideoSourceFps,
      'maxSeconds': voxVideoMaxSeconds,
    });
    if (r == null) throw StateError('Couldn\'t read the video');
    final framesFile = File(r['frames']! as String);
    final rgb = await framesFile.readAsBytes();
    unawaited(framesFile.delete().catchError((_) => framesFile));
    final w = r['width']! as int, h = r['height']! as int;
    final fps = r['fps']! as int;
    final count = r['count']! as int;
    final whole = rgb.length ~/ (w * h * 3);
    final frames = VoxVideoFrames(
      w,
      h,
      fps,
      whole >= count ? rgb : Uint8List.sublistView(rgb, 0, whole * w * h * 3),
    );
    Int16List? sound;
    final soundPath = r['sound'] as String?;
    final samples = (r['samples'] as int?) ?? 0;
    if (soundPath != null && samples > 0) {
      final f = File(soundPath);
      final bytes = await f.readAsBytes();
      unawaited(f.delete().catchError((_) => f));
      sound = Int16List.view(
        bytes.buffer,
        bytes.offsetInBytes,
        (bytes.length ~/ 2).clamp(0, samples),
      );
    }
    return VoxPickedVideo(frames, sound);
  }
}
