// MeshCore Open TAK - plays a decoded video message: its frames in time with
// its sound.

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'image_message_bubble.dart' show voxRgbToUiImage;
import 'video_codec.dart';
import 'wav_source.dart';

/// The frames of [frames] as images (converted once, then reused).
Future<List<ui.Image>> voxFramesToImages(VoxVideoFrames frames) async {
  final out = <ui.Image>[];
  for (var i = 0; i < frames.count; i++) {
    out.add(await voxRgbToUiImage(frames.frame(i)));
  }
  return out;
}

/// A clip that plays when tapped (and stops when tapped again), with a play
/// badge over its first frame while stopped.
class VoxVideoView extends StatefulWidget {
  final VoxVideoFrames frames;

  /// Its sound as a WAV file; null plays it silent.
  final Uint8List? wav;

  /// Start playing as soon as it is shown.
  final bool autoPlay;

  /// How the frames fill the box.
  final BoxFit fit;

  const VoxVideoView({
    super.key,
    required this.frames,
    this.wav,
    this.autoPlay = false,
    this.fit = BoxFit.contain,
  });

  @override
  State<VoxVideoView> createState() => _VoxVideoViewState();
}

class _VoxVideoViewState extends State<VoxVideoView>
    with SingleTickerProviderStateMixin {
  List<ui.Image>? _images;
  late final Ticker _ticker = createTicker(_tick);
  AudioPlayer? _player;
  int _shown = 0;
  bool _playing = false;
  int _gen = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(VoxVideoView old) {
    super.didUpdateWidget(old);
    if (!identical(old.frames, widget.frames)) {
      _stop();
      _disposeImages();
      _shown = 0;
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final gen = ++_gen;
    final images = await voxFramesToImages(widget.frames);
    if (!mounted || gen != _gen) {
      for (final i in images) {
        i.dispose();
      }
      return;
    }
    setState(() => _images = images);
    if (widget.autoPlay) unawaited(_play());
  }

  void _disposeImages() {
    for (final i in _images ?? const <ui.Image>[]) {
      i.dispose();
    }
    _images = null;
  }

  Future<void> _play() async {
    if (_images == null || _images!.isEmpty) return;
    setState(() {
      _playing = true;
      _shown = 0;
    });
    final wav = widget.wav;
    if (wav != null) {
      final p = _player ??= AudioPlayer();
      try {
        await p.play(await voxWavSource(wav));
      } catch (_) {}
    }
    if (!mounted || !_playing) return;
    _ticker.start();
  }

  void _stop() {
    if (_ticker.isActive) _ticker.stop();
    unawaited(_player?.stop());
    if (mounted) {
      setState(() {
        _playing = false;
        _shown = 0;
      });
    } else {
      _playing = false;
    }
  }

  void _tick(Duration elapsed) {
    final images = _images;
    if (images == null) return;
    final i = elapsed.inMilliseconds * widget.frames.fps ~/ 1000;
    if (i >= images.length) {
      _stop();
      return;
    }
    if (i != _shown) setState(() => _shown = i);
  }

  @override
  void dispose() {
    _ticker.dispose();
    unawaited(_player?.dispose());
    _disposeImages();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final images = _images;
    final frames = widget.frames;
    return GestureDetector(
      onTap: images == null ? null : (_playing ? _stop : _play),
      child: AspectRatio(
        aspectRatio: frames.width / frames.height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            const ColoredBox(color: Colors.black),
            if (images != null && images.isNotEmpty)
              RawImage(
                image: images[_shown.clamp(0, images.length - 1)],
                fit: widget.fit,
                // Bicubic: small frames scaled up stay smooth, not blocky.
                filterQuality: FilterQuality.high,
              )
            else
              const Center(child: CircularProgressIndicator()),
            if (images != null && !_playing)
              const Center(child: VoxPlayBadge()),
          ],
        ),
      ),
    );
  }
}

/// The round play mark over a video's still.
class VoxPlayBadge extends StatelessWidget {
  final double size;
  const VoxPlayBadge({super.key, this.size = 56});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        color: Colors.black54,
        shape: BoxShape.circle,
      ),
      child: Icon(Icons.play_arrow, color: Colors.white, size: size * 0.6),
    );
  }
}

/// Full screen, playing at once.
class VoxVideoScreen extends StatelessWidget {
  final VoxVideoFrames frames;
  final Uint8List? wav;

  /// Shown under the clip (sound missing, size).
  final String? note;

  const VoxVideoScreen({super.key, required this.frames, this.wav, this.note});

  static Future<void> open(
    BuildContext context,
    VoxVideoFrames frames, {
    Uint8List? wav,
    String? note,
  }) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => VoxVideoScreen(frames: frames, wav: wav, note: note),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        centerTitle: true,
        title: Text(
          '${frames.width} × ${frames.height} · '
          '${(frames.duration.inMilliseconds / 1000).toStringAsFixed(1)} s',
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: VoxVideoView(frames: frames, wav: wav, autoPlay: true),
              ),
            ),
            if (note != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  note!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
