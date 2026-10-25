// MeshCore Open TAK - chat bubble content for a VI1 image message.

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/contact.dart';
import 'av1_ffi.dart';
import 'voice_message_bubble.dart'
    show showVoxVoiceLog, VoxCaption, VoxReceivedViaLabel;
import 'voice_service.dart';
import 'voice_wire.dart';
import 'vox_upscale.dart';

/// RGB888 picture -> ui.Image for display.
Future<ui.Image> voxRgbToUiImage(VoxRgbImage img) {
  final n = img.width * img.height;
  final rgba = Uint8List(n * 4);
  for (var i = 0; i < n; i++) {
    rgba[i * 4] = img.rgb[i * 3];
    rgba[i * 4 + 1] = img.rgb[i * 3 + 1];
    rgba[i * 4 + 2] = img.rgb[i * 3 + 2];
    rgba[i * 4 + 3] = 255;
  }
  final c = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    rgba,
    img.width,
    img.height,
    ui.PixelFormat.rgba8888,
    c.complete,
  );
  return c.future;
}

class VoxImageMessageContent extends StatefulWidget {
  final VoxVoiceEnvelope envelope;
  final bool isOutgoing;
  final Contact? sender;
  final int? channelIndex;
  final Color textColor;

  const VoxImageMessageContent({
    super.key,
    required this.envelope,
    required this.isOutgoing,
    required this.textColor,
    this.sender,
    this.channelIndex,
  });

  @override
  State<VoxImageMessageContent> createState() => _VoxImageMessageContentState();
}

class _VoxImageMessageContentState extends State<VoxImageMessageContent> {
  VoxVoiceService? _service;
  ui.Image? _image;

  /// The thumbnail from the photo's first two packets, shown until [_image].
  ui.Image? _thumb;
  bool _thumbLoading = false;
  bool _loading = false;
  bool _failed = false;
  int _loadGen = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final s = context.read<VoxVoiceService>();
    if (s != _service) {
      _service?.removeListener(_onServiceChanged);
      _service = s;
      s.addListener(_onServiceChanged);
      unawaited(
        s
            .warmUp(
              widget.envelope,
              sender: widget.sender,
              channelIndex: widget.channelIndex,
            )
            .then((_) => _maybeLoad()),
      );
    }
  }

  /// The chat list reuses bubble state when messages shift, so a bubble can
  /// be handed a different photo. Drop everything tied to the old one.
  @override
  void didUpdateWidget(VoxImageMessageContent old) {
    super.didUpdateWidget(old);
    if (old.envelope.sessionId == widget.envelope.sessionId) return;
    _image?.dispose();
    _image = null;
    _thumb?.dispose();
    _thumb = null;
    _thumbLoading = false;
    _loading = false;
    _failed = false;
    _loadGen++;
    final s = _service;
    if (s != null) {
      unawaited(
        s
            .warmUp(
              widget.envelope,
              sender: widget.sender,
              channelIndex: widget.channelIndex,
            )
            .then((_) {
              if (mounted) _maybeLoad();
            }),
      );
    }
  }

  void _onServiceChanged() {
    if (!mounted) return;
    _maybeLoad();
    setState(() {});
  }

  void _maybeLoadThumb() {
    final s = _service;
    if (s == null || _image != null || _thumb != null || _thumbLoading) return;
    final rgb = s.thumbFor(widget.envelope);
    if (rgb == null) return;
    _thumbLoading = true;
    final gen = _loadGen;
    unawaited(
      voxRgbToUiImage(rgb).then((img) {
        if (!mounted || gen != _loadGen || _image != null) {
          img.dispose();
          return;
        }
        setState(() {
          _thumb = img;
          _thumbLoading = false;
        });
      }),
    );
  }

  void _maybeLoad() {
    _maybeLoadThumb();
    final s = _service;
    if (s == null || _image != null || _loading || _failed) return;
    if (s.stateFor(widget.envelope).status != VoxClipStatus.complete) return;
    _loading = true;
    final gen = _loadGen;
    final env = widget.envelope;
    unawaited(() async {
      final rgb = await s.imageFor(env);
      final img = rgb == null ? null : await voxRgbToUiImage(rgb);
      // Drop the result if this bubble now shows a different photo.
      if (!mounted || gen != _loadGen) {
        img?.dispose();
        return;
      }
      setState(() {
        _image = img;
        _failed = img == null;
        _loading = false;
        if (img != null) {
          _thumb?.dispose();
          _thumb = null;
        }
      });
    }());
  }

  Future<void> _onTap() async {
    final s = _service;
    if (s == null) return;
    if (_image != null) {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => _VoxImageViewer(image: _image!),
          fullscreenDialog: true,
        ),
      );
      return;
    }
    final st = s.stateFor(widget.envelope);
    if (st.status == VoxClipStatus.requesting ||
        st.status == VoxClipStatus.receiving ||
        st.status == VoxClipStatus.complete) {
      return;
    }
    await s.requestAndPlay(
      widget.envelope,
      sender: widget.sender,
      channelIndex: widget.channelIndex,
    );
  }

  @override
  void dispose() {
    _service?.removeListener(_onServiceChanged);
    _image?.dispose();
    _thumb?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = _service;
    final env = widget.envelope;
    final color = widget.textColor;
    final meta = color.withValues(alpha: 0.65);
    if (s == null || !s.imagesAvailable) {
      final note = Text(
        '🖼 Photo — this build can\'t show photo messages',
        style: TextStyle(color: meta, fontStyle: FontStyle.italic),
      );
      if (env.caption.isEmpty) return note;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          note,
          const SizedBox(height: 4),
          VoxCaption(env.caption, color: color),
        ],
      );
    }
    final st = s.stateFor(env);
    final aspect = env.imageAspect.clamp(0.4, 2.5);
    final kb = (env.estimatedCodecBytes / 1000).toStringAsFixed(1);

    // Where photos go: radio2 (MediaMesh) when they go there alone.
    final air = s.mediaAirtime(env.totalPackets);
    final String? airHint = air == null
        ? null
        : '~${(air.inMilliseconds / 1000).toStringAsFixed(0)}s air';

    final String caption = switch (st.status) {
      VoxClipStatus.complete when _failed => 'Photo could not be decoded',
      VoxClipStatus.complete => 'Photo · $kb KB · tap to enlarge',
      // Pushed (or sent for someone else) and arriving unasked.
      VoxClipStatus.remote when !widget.isOutgoing && st.received > 0 =>
        'Receiving ${st.received}/${st.total}',
      VoxClipStatus.remote =>
        widget.isOutgoing
            ? 'Photo · $kb KB · waiting for viewers'
            : 'Photo · $kb KB · tap to download'
                  '${airHint == null ? '' : ' ($airHint)'}',
      VoxClipStatus.requesting => st.message ?? 'Requesting…',
      VoxClipStatus.receiving => 'Receiving ${st.received}/${st.total}',
      VoxClipStatus.unavailable => st.message ?? 'Photo unavailable right now',
    };

    final busy =
        st.status == VoxClipStatus.requesting ||
        st.status == VoxClipStatus.receiving;

    Widget picture;
    if (_image != null) {
      picture = RawImage(
        image: _image,
        fit: BoxFit.cover,
        filterQuality: FilterQuality.medium,
      );
    } else if (_thumb != null) {
      // The thumbnail sent first, scaled up (soft, as a preview should be),
      // with the download's progress over it.
      picture = Stack(
        fit: StackFit.expand,
        children: [
          RawImage(
            image: _thumb,
            fit: BoxFit.cover,
            // Bicubic: a 96 px picture scaled up to the bubble stays smooth
            // rather than blocky.
            filterQuality: FilterQuality.high,
          ),
          if (busy)
            Center(
              child: SizedBox(
                width: 40,
                height: 40,
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  color: Colors.white,
                  backgroundColor: Colors.black26,
                  value: st.status == VoxClipStatus.receiving
                      ? st.progress
                      : null,
                ),
              ),
            ),
        ],
      );
    } else {
      picture = Container(
        color: color.withValues(alpha: 0.08),
        alignment: Alignment.center,
        child: busy
            ? SizedBox(
                width: 40,
                height: 40,
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  color: color,
                  value: st.status == VoxClipStatus.receiving
                      ? st.progress
                      : null,
                ),
              )
            : Icon(
                st.status == VoxClipStatus.unavailable
                    ? Icons.refresh
                    : st.status == VoxClipStatus.complete
                    ? Icons.image_outlined
                    : Icons.download_for_offline_outlined,
                size: 40,
                color: meta,
              ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: busy ? null : _onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 260, maxHeight: 320),
            child: AspectRatio(
              aspectRatio: aspect,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: picture,
              ),
            ),
          ),
        ),
        if (env.caption.isNotEmpty) ...[
          const SizedBox(height: 6),
          VoxCaption(env.caption, color: color),
        ],
        const SizedBox(height: 4),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(caption, style: TextStyle(color: meta, fontSize: 12)),
            ),
            IconButton(
              icon: Icon(Icons.info_outline, size: 16, color: meta),
              tooltip: 'Transfer diagnostics',
              visualDensity: VisualDensity.compact,
              onPressed: () => showVoxVoiceLog(context, s),
            ),
          ],
        ),
        if (!widget.isOutgoing &&
            st.status == VoxClipStatus.complete &&
            !_failed &&
            st.via != null)
          VoxReceivedViaLabel(
            via: st.via!,
            color: meta,
            repeater: st.viaRepeater,
          ),
      ],
    );
  }
}

class _VoxImageViewer extends StatefulWidget {
  final ui.Image image;
  const _VoxImageViewer({required this.image});

  @override
  State<_VoxImageViewer> createState() => _VoxImageViewerState();
}

/// The photo as sent, and on request an AI-enhanced 4x view ([VoxUpscaler]).
/// The enhanced view is display only and says it may invent detail.
class _VoxImageViewerState extends State<_VoxImageViewer> {
  final VoxUpscaler _up = VoxUpscaler.instance;
  ui.Image? _enhanced;
  bool _showEnhanced = false;
  bool _working = false;
  double _progress = 0;

  bool get _canEnhance =>
      VoxUpscaler.canEnhance(widget.image.width, widget.image.height);

  @override
  void dispose() {
    _enhanced?.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_working) return;
    if (_enhanced != null) {
      setState(() => _showEnhanced = !_showEnhanced);
      return;
    }
    if (!_up.isReady) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Enhance photos'),
          content: Text(
            'Sharpens a photo 4x on this device with an AI model '
            '(Real-ESRGAN, about ${VoxUpscaler.downloadMb} MB, downloaded '
            'once). The photo itself is not changed. The enhanced view can '
            'invent detail, so don\'t rely on it for small text, faces or '
            'numbers.',
          ),
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
      if (ok != true || !mounted) return;
      setState(() {
        _working = true;
        _progress = 0;
      });
      void tick() {
        if (mounted) setState(() => _progress = _up.progress * 0.3);
      }

      _up.addListener(tick);
      await _up.download();
      _up.removeListener(tick);
      if (!mounted) return;
      if (!_up.isReady) {
        setState(() => _working = false);
        _say(
          'Couldn\'t download the enhancer: ${_up.error ?? 'unknown error'}',
        );
        return;
      }
    }
    setState(() {
      _working = true;
      _progress = _up.isReady && _progress > 0 ? _progress : 0;
    });
    final base = _progress;
    try {
      final img = await _up.enhance(
        widget.image,
        onProgress: (p) {
          if (mounted) setState(() => _progress = base + (1 - base) * p);
        },
      );
      if (!mounted) {
        img.dispose();
        return;
      }
      setState(() {
        _enhanced = img;
        _showEnhanced = true;
        _working = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _working = false);
      _say('Couldn\'t enhance the photo: $e');
    }
  }

  void _say(String text) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(text)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final shown = _showEnhanced && _enhanced != null
        ? _enhanced!
        : widget.image;
    final enhanced = identical(shown, _enhanced);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          enhanced
              ? '${shown.width} × ${shown.height} enhanced'
              : '${shown.width} × ${shown.height} as sent',
        ),
        actions: [
          if (_canEnhance)
            IconButton(
              tooltip: enhanced ? 'Show as sent' : 'Enhance (AI, 4x)',
              onPressed: _working ? null : _toggle,
              icon: Icon(
                enhanced ? Icons.auto_awesome : Icons.auto_awesome_outlined,
                color: enhanced ? Colors.amberAccent : Colors.white,
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
      body: Stack(
        children: [
          Positioned.fill(
            child: InteractiveViewer(
              maxScale: 8,
              child: Center(
                child: AspectRatio(
                  aspectRatio: shown.width / shown.height,
                  child: RawImage(
                    image: shown,
                    fit: BoxFit.contain,
                    filterQuality: FilterQuality.medium,
                  ),
                ),
              ),
            ),
          ),
          if (enhanced)
            Positioned(
              left: 0,
              right: 0,
              bottom: 24,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Text(
                    'AI-enhanced view: details may be invented',
                    style: TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
