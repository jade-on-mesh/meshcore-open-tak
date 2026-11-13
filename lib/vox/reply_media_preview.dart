// MeshCore Open TAK - a reply's quote of a photo, video or voice message: the
// picture (the downloaded photo, else its thumbnail) and its caption, instead
// of the message's wire text (`VI1:11um4ka:14:h:3p IMAGE Where I want...`).

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
import 'image_message_bubble.dart' show voxRgbToUiImage;
import 'voice_service.dart';
import 'voice_wire.dart';

/// The quote of [text] when it's a photo, video or voice message, else null.
Widget? voxReplyMediaPreview(
  BuildContext context,
  String text, {
  required double textScale,
  required Color color,
  double size = 44,
}) {
  final env = VoxVoiceEnvelope.tryParse(text);
  if (env == null) return null;
  return VoxReplyMediaPreview(
    envelope: env,
    textScale: textScale,
    color: color,
    size: size,
  );
}

class VoxReplyMediaPreview extends StatefulWidget {
  final VoxVoiceEnvelope envelope;
  final double textScale;
  final Color color;
  final double size;

  const VoxReplyMediaPreview({
    super.key,
    required this.envelope,
    required this.textScale,
    required this.color,
    this.size = 44,
  });

  @override
  State<VoxReplyMediaPreview> createState() => _VoxReplyMediaPreviewState();
}

class _VoxReplyMediaPreviewState extends State<VoxReplyMediaPreview> {
  VoxVoiceService? _service;
  ui.Image? _picture;
  bool _full = false; // _picture is the downloaded photo, not the thumbnail
  bool _askedFull = false;
  int _gen = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    VoxVoiceService? s;
    try {
      s = context.read<VoxVoiceService>();
    } catch (_) {
      s = null; // no voice service (a test): text only
    }
    if (s == _service) return;
    _service?.removeListener(_onChanged);
    _service = s;
    s?.addListener(_onChanged);
    _warmUp();
  }

  /// Loads a photo downloaded before a restart (asks the mesh for nothing).
  void _warmUp() {
    final s = _service;
    if (s == null || !widget.envelope.isMedia) return;
    final gen = _gen;
    unawaited(
      s.warmUp(widget.envelope).then((_) {
        if (mounted && gen == _gen) _load();
      }),
    );
  }

  @override
  void didUpdateWidget(VoxReplyMediaPreview old) {
    super.didUpdateWidget(old);
    if (old.envelope.sessionId == widget.envelope.sessionId) return;
    _picture?.dispose();
    _picture = null;
    _full = false;
    _askedFull = false;
    _gen++;
    _warmUp();
  }

  @override
  void dispose() {
    _service?.removeListener(_onChanged);
    _picture?.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) _load();
  }

  /// The downloaded photo when there is one (decoded once, cached by the
  /// service), else the thumbnail its first packets carry.
  void _load() {
    final s = _service;
    final env = widget.envelope;
    if (s == null || !env.isMedia || _full) return;
    final gen = _gen;
    if (env.isImage &&
        !_askedFull &&
        s.stateFor(env).status == VoxClipStatus.complete) {
      _askedFull = true;
      unawaited(
        s.imageFor(env).then((rgb) async {
          if (rgb == null) {
            _showThumb(s, gen);
            return;
          }
          final img = await voxRgbToUiImage(rgb);
          if (!mounted || gen != _gen) {
            img.dispose();
            return;
          }
          setState(() {
            _picture?.dispose();
            _picture = img;
            _full = true;
          });
        }),
      );
      return;
    }
    _showThumb(s, gen);
  }

  void _showThumb(VoxVoiceService s, int gen) {
    if (_picture != null || !mounted) return;
    final rgb = s.thumbFor(widget.envelope);
    if (rgb == null) return;
    unawaited(
      voxRgbToUiImage(rgb).then((img) {
        if (!mounted || gen != _gen || _picture != null) {
          img.dispose();
          return;
        }
        setState(() => _picture = img);
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final env = widget.envelope;
    final l10n = context.l10n;
    final caption = env.caption.trim();
    final kind = env.isImage
        ? l10n.chat_replyPhoto
        : env.isVideo
        ? l10n.chat_replyVideo(env.durationSeconds)
        : l10n.chat_replyVoice(env.durationSeconds);
    final style = TextStyle(
      fontSize: 12 * widget.textScale,
      color: widget.color,
      fontStyle: FontStyle.italic,
    );
    final label = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (caption.isNotEmpty)
          Text(
            caption,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        Text(
          kind,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: style.copyWith(
            fontStyle: FontStyle.normal,
            fontSize: 11 * widget.textScale,
          ),
        ),
      ],
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _thumb(context),
        const SizedBox(width: 8),
        Flexible(child: label),
      ],
    );
  }

  Widget _thumb(BuildContext context) {
    final env = widget.envelope;
    final scheme = Theme.of(context).colorScheme;
    final s = widget.size;
    final picture = _picture;
    if (!env.isMedia) {
      return Icon(Icons.mic_none, size: 18 * widget.textScale, color: widget.color);
    }
    Widget body = picture != null
        ? RawImage(image: picture, fit: BoxFit.cover, width: s, height: s)
        : Container(
            width: s,
            height: s,
            color: scheme.surfaceContainerHighest,
            child: Icon(
              env.isVideo ? Icons.videocam_outlined : Icons.photo_outlined,
              size: s * 0.5,
              color: widget.color,
            ),
          );
    if (env.isVideo && picture != null) {
      body = Stack(
        alignment: Alignment.center,
        children: [
          body,
          Icon(
            Icons.play_circle_fill,
            size: s * 0.45,
            color: Colors.white.withValues(alpha: 0.85),
          ),
        ],
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(width: s, height: s, child: body),
    );
  }
}
