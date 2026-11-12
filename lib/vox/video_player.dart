// MeshCore Open TAK - plays a decoded video message: its frames in time with
// its sound.

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'image_message_bubble.dart' show voxRgbToUiImage;
import 'video_codec.dart';
import 'vox_interp.dart';
import 'vox_upscale.dart';
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

/// Full screen, playing at once, with the AI views: Smooth motion (frames
/// made up in between, vox_interp.dart) and Enhance (each frame sharpened
/// 2x, vox_upscale.dart). Both are switches remembered for next time, display
/// only, and say on screen that they invent what wasn't sent.
class VoxVideoScreen extends StatefulWidget {
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
  State<VoxVideoScreen> createState() => _VoxVideoScreenState();
}

const _kSmooth = 'vox_video_smooth';
const _kEnhance = 'vox_video_enhance';

/// Most frames kept with Enhance on (they are 4x the pixels).
const _maxEnhancedFrames = 240;

class _VoxVideoScreenState extends State<VoxVideoScreen> {
  final _interp = VoxInterpolator.instance;
  final _up = VoxUpscaler.instance;
  bool _smooth = false;
  bool _enhance = false;
  bool _working = false;
  double _progress = 0;
  String _stage = '';
  String? _error;
  late VoxVideoFrames _shown = widget.frames;
  int _job = 0;

  bool get _canEnhance =>
      VoxUpscaler.canEnhance(widget.frames.width, widget.frames.height);

  @override
  void initState() {
    super.initState();
    unawaited(_restore());
  }

  /// The switches as last left; applied at once when their models are here
  /// (never downloads by itself).
  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _smooth = prefs.getBool(_kSmooth) ?? false;
      _enhance = (prefs.getBool(_kEnhance) ?? false) && _canEnhance;
    } catch (_) {}
    await Future.wait([_interp.refresh(), _up.refresh()]);
    if (!mounted) return;
    if (_smooth && !_interp.isReady) _smooth = false;
    if (_enhance && !_up.isReady) _enhance = false;
    setState(() {});
    if (_smooth || _enhance) await _apply();
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kSmooth, _smooth);
      await prefs.setBool(_kEnhance, _enhance);
    } catch (_) {}
  }

  /// Asks to download a model, saying what it does and what it invents.
  Future<bool> _offer({required String title, required String body}) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Download'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _toggleSmooth() async {
    if (_working) return;
    if (!_smooth && !_interp.isReady) {
      final ok = await _offer(
        title: 'Smooth motion',
        body:
            'Makes up the frames in between the ones that were sent, on this '
            'device, with an AI model (RIFE, about ${VoxInterpolator.downloadMb} '
            'MB, downloaded once), so the clip plays at about '
            '$voxInterpTargetFps frames a second. The clip itself is not '
            'changed. The in-between frames are guesses: fast movement can '
            'smear or warp, so don\'t rely on them for what happened between '
            'frames.',
      );
      if (!ok || !mounted) return;
      final got = await _download(
        _interp.download,
        () => _interp.progress,
        () => _interp.isReady,
        _interp,
        'Downloading Smooth motion…',
      );
      if (!mounted) return;
      if (!got) {
        _say(
          'Couldn\'t download Smooth motion: '
          '${_interp.error ?? 'unknown error'}',
        );
        return;
      }
    }
    setState(() => _smooth = !_smooth);
    unawaited(_save());
    await _apply();
  }

  Future<void> _toggleEnhance() async {
    if (_working) return;
    if (!_enhance && !_up.isReady) {
      final ok = await _offer(
        title: 'Enhance video',
        body:
            'Sharpens every frame (2x) on this device with an AI model '
            '(Real-ESRGAN, about ${VoxUpscaler.downloadMb} MB, downloaded '
            'once; the same one photos use). The clip itself is not changed. '
            'The enhanced view can invent detail, and fine detail can shimmer '
            'from frame to frame, so don\'t rely on it for small text, faces '
            'or numbers.',
      );
      if (!ok || !mounted) return;
      final got = await _download(
        _up.download,
        () => _up.progress,
        () => _up.isReady,
        _up,
        'Downloading the enhancer…',
      );
      if (!mounted) return;
      if (!got) {
        _say(
          'Couldn\'t download the enhancer: ${_up.error ?? 'unknown error'}',
        );
        return;
      }
    }
    setState(() => _enhance = !_enhance);
    unawaited(_save());
    await _apply();
  }

  /// Runs [download] with its progress (from [model]) on screen; true if
  /// the model is ready after it.
  Future<bool> _download(
    Future<void> Function() download,
    double Function() progress,
    bool Function() ready,
    ChangeNotifier model,
    String stage,
  ) async {
    setState(() {
      _working = true;
      _progress = 0;
      _stage = stage;
    });
    void tick() {
      if (mounted) setState(() => _progress = progress());
    }

    model.addListener(tick);
    try {
      await download();
    } finally {
      model.removeListener(tick);
      if (mounted) setState(() => _working = false);
    }
    return ready();
  }

  /// Builds the frames to show for the switches as they are.
  Future<void> _apply() async {
    final job = ++_job;
    var f = widget.frames;
    if (!_smooth && !_enhance) {
      setState(() {
        _shown = f;
        _error = null;
      });
      return;
    }
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      if (_smooth) {
        final m = voxInterpMultiple(
          f.fps,
          f.count,
          maxFrames: _enhance ? _maxEnhancedFrames : 720,
        );
        if (m > 1) {
          setState(() {
            _stage = 'Making in-between frames…';
            _progress = 0;
          });
          f = await _interp.interpolate(
            f,
            m,
            onProgress: (p) {
              if (mounted && job == _job) setState(() => _progress = p);
            },
          );
        }
      }
      if (job != _job || !mounted) return;
      if (_enhance && _canEnhance) {
        setState(() {
          _stage = 'Enhancing…';
          _progress = 0;
        });
        f = await _up.enhanceClip(
          f,
          onProgress: (p) {
            if (mounted && job == _job) setState(() => _progress = p);
          },
        );
      }
      if (job != _job || !mounted) return;
      setState(() {
        _shown = f;
        _working = false;
      });
    } catch (e) {
      if (job != _job || !mounted) return;
      setState(() {
        _working = false;
        _error = 'Couldn\'t make the AI view: $e';
      });
    }
  }

  void _say(String text) {
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final frames = _shown;
    final aiNotes = [
      if (_smooth && frames.fps > widget.frames.fps)
        'In-between frames are made up',
      if (_enhance && frames.width > widget.frames.width)
        'Detail may be invented',
    ];
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        centerTitle: true,
        title: Text('${frames.width} × ${frames.height} · ${frames.fps} fps'),
        actions: [
          if (VoxInterpolator.supported)
            IconButton(
              tooltip: _smooth ? 'Smooth motion off' : 'Smooth motion (AI)',
              onPressed: _working ? null : _toggleSmooth,
              icon: Icon(
                Icons.slow_motion_video,
                color: _smooth ? Colors.amberAccent : Colors.white,
              ),
            ),
          if (_canEnhance)
            IconButton(
              tooltip: _enhance ? 'Show as sent' : 'Enhance (AI)',
              onPressed: _working ? null : _toggleEnhance,
              icon: Icon(
                _enhance ? Icons.auto_awesome : Icons.auto_awesome_outlined,
                color: _enhance ? Colors.amberAccent : Colors.white,
              ),
            ),
        ],
        bottom: _working
            ? PreferredSize(
                preferredSize: const Size.fromHeight(3),
                child: LinearProgressIndicator(
                  value: _progress > 0 ? _progress : null,
                  minHeight: 3,
                ),
              )
            : null,
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: VoxVideoView(
                  frames: frames,
                  wav: widget.wav,
                  autoPlay: true,
                ),
              ),
            ),
            if (_working || aiNotes.isNotEmpty || _error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    _working
                        ? '$_stage ${(_progress * 100).round()}%'
                        : _error ?? 'AI view: ${aiNotes.join('; ')}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
              ),
            if (widget.note != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  widget.note!,
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
