// MeshCore Open TAK - reads a picked video as frames and sound for
// video_codec.dart: android/.../VoxVideoChannel.kt on Android,
// MeshVideoReader in ios/Runner/AppDelegate.swift on iPhone (and
// macos/Runner/MainFlutterWindow.swift on the Mac), Media Foundation in
// windows/runner/video_extract.cpp on Windows, and the ffmpeg program on
// Linux (below).

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

  /// Videos can be picked and sent on this platform (menus offer it).
  static bool get isSupported {
    if (kIsWeb) return false;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
      case TargetPlatform.linux:
        return true;
      default:
        return false;
    }
  }

  /// Everything needed is here now: on Linux that is the ffmpeg program
  /// ([unsupportedReason] says so when it isn't).
  static bool get isReady =>
      isSupported &&
      (kIsWeb ||
          defaultTargetPlatform != TargetPlatform.linux ||
          _ffmpeg != null);

  /// Why videos can't be sent from here, for the message the picker shows.
  static String get unsupportedReason =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.linux
      ? 'Sending videos on Linux needs ffmpeg: install it (for example '
            '"sudo apt install ffmpeg") and open the app again.'
      : 'Video messages can be sent from Android, iPhone, Windows, macOS '
            'and Linux.';

  /// A camera to record with: phones only (a computer picks a file).
  static bool get canRecord =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  /// The ffmpeg program on Linux, found once on PATH.
  static final String? _ffmpeg = () {
    if (kIsWeb || !Platform.isLinux) return null;
    final dirs = [
      ...(Platform.environment['PATH'] ?? '').split(':'),
      '/usr/bin',
      '/usr/local/bin',
      '/snap/bin',
    ];
    for (final d in dirs) {
      if (d.isEmpty) continue;
      final f = File('$d/ffmpeg');
      if (f.existsSync()) return f.path;
    }
    return null;
  }();

  /// Reads the first [voxVideoMaxSeconds] of the video at [path].
  static Future<VoxPickedVideo> read(String path) async {
    final r = !kIsWeb && Platform.isLinux
        ? await _extractWithFfmpeg(path)
        : await _channel.invokeMapMethod<String, Object?>('extract', {
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

  /// Linux: the same answer as the platform readers, from two ffmpeg runs
  /// (frames, then sound). ffmpeg turns phone videos upright itself.
  static Future<Map<String, Object?>> _extractWithFfmpeg(String path) async {
    final ffmpeg = _ffmpeg;
    if (ffmpeg == null) throw StateError(unsupportedReason);
    final tmp = await Directory.systemTemp.createTemp('vox_video');
    final frames = File('${tmp.path}/frames.rgb');
    const side = voxVideoSourceSide, fps = voxVideoSourceFps;
    final picture = await Process.run(ffmpeg, [
      '-nostdin',
      '-hide_banner',
      '-y',
      '-t',
      '$voxVideoMaxSeconds',
      '-i',
      path,
      '-an',
      '-sn',
      '-dn',
      '-vf',
      'fps=$fps,scale=w=$side:h=$side:force_original_aspect_ratio=decrease:'
          'force_divisible_by=2:flags=area',
      '-pix_fmt',
      'rgb24',
      '-f',
      'rawvideo',
      frames.path,
    ]);
    if (picture.exitCode != 0 || !await frames.exists()) {
      await tmp.delete(recursive: true);
      throw StateError('ffmpeg couldn\'t read the video');
    }
    final size = ffmpegOutputSize('${picture.stderr}');
    if (size == null) {
      await tmp.delete(recursive: true);
      throw StateError('ffmpeg didn\'t say the picture size');
    }
    final (w, h) = size;
    final count = await frames.length() ~/ (w * h * 3);
    if (count < 1) {
      await tmp.delete(recursive: true);
      throw StateError('no picture in this video');
    }
    final sound = File('${tmp.path}/sound.pcm');
    final audio = await Process.run(ffmpeg, [
      '-nostdin',
      '-hide_banner',
      '-y',
      '-t',
      '$voxVideoMaxSeconds',
      '-i',
      path,
      '-vn',
      '-sn',
      '-dn',
      '-ac',
      '1',
      '-ar',
      '48000',
      '-f',
      's16le',
      sound.path,
    ]);
    final hasSound =
        audio.exitCode == 0 &&
        await sound.exists() &&
        await sound.length() >= 2;
    return {
      'frames': frames.path,
      'width': w,
      'height': h,
      'fps': fps,
      'count': count,
      'durationMs': count * 1000 ~/ fps,
      'sound': hasSound ? sound.path : null,
      'samples': hasSound ? await sound.length() ~/ 2 : 0,
    };
  }
}

/// The picture size of ffmpeg's raw video output, from its log: the
/// "Output #0" section's `Video: rawvideo ... rgb24, 256x144` line.
@visibleForTesting
(int, int)? ffmpegOutputSize(String log) {
  final at = log.indexOf('Output #0');
  if (at < 0) return null;
  for (final line in log.substring(at).split('\n')) {
    if (!line.contains('Video:')) continue;
    final m = RegExp(r'[ ,](\d{2,5})x(\d{2,5})[ ,\]]').firstMatch('$line ');
    if (m != null) return (int.parse(m.group(1)!), int.parse(m.group(2)!));
  }
  return null;
}
