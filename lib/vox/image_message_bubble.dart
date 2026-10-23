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

  void _maybeLoad() {
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

class _VoxImageViewer extends StatelessWidget {
  final ui.Image image;
  const _VoxImageViewer({required this.image});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text('${image.width} × ${image.height} as sent'),
      ),
      body: InteractiveViewer(
        maxScale: 8,
        child: Center(
          child: AspectRatio(
            aspectRatio: image.width / image.height,
            child: RawImage(
              image: image,
              fit: BoxFit.contain,
              filterQuality: FilterQuality.medium,
            ),
          ),
        ),
      ),
    );
  }
}
