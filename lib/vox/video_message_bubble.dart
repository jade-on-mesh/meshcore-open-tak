// MeshCore Open TAK - chat bubble content for a VV1 video message.

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/contact.dart';
import '../services/app_settings_service.dart';
import 'image_message_bubble.dart' show voxRgbToUiImage;
import 'video_codec.dart';
import 'video_player.dart';
import 'voice_message_bubble.dart'
    show showVoxVoiceLog, VoxCaption, VoxReceivedViaLabel;
import 'voice_service.dart';
import 'voice_wire.dart';

class VoxVideoMessageContent extends StatefulWidget {
  final VoxVoiceEnvelope envelope;
  final bool isOutgoing;
  final Contact? sender;
  final int? channelIndex;
  final Color textColor;

  const VoxVideoMessageContent({
    super.key,
    required this.envelope,
    required this.isOutgoing,
    required this.textColor,
    this.sender,
    this.channelIndex,
  });

  @override
  State<VoxVideoMessageContent> createState() => _VoxVideoMessageContentState();
}

class _VoxVideoMessageContentState extends State<VoxVideoMessageContent> {
  VoxVoiceService? _service;
  VoxPlayableVideo? _video;

  /// The first frame, sent ahead in the first two packets: shown until the
  /// clip is here.
  ui.Image? _thumb;
  bool _thumbLoading = false;
  bool _loading = false;
  bool _failed = false;
  int _gen = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final s = context.read<VoxVoiceService>();
    if (s != _service) {
      _service?.removeListener(_onServiceChanged);
      _service = s;
      s.addListener(_onServiceChanged);
      _warmUp();
    }
  }

  /// The chat list reuses bubble state when messages shift: drop everything
  /// tied to the old clip.
  @override
  void didUpdateWidget(VoxVideoMessageContent old) {
    super.didUpdateWidget(old);
    if (old.envelope.sessionId == widget.envelope.sessionId) return;
    _thumb?.dispose();
    _thumb = null;
    _video = null;
    _thumbLoading = false;
    _loading = false;
    _failed = false;
    _gen++;
    _warmUp();
  }

  void _warmUp() {
    final s = _service;
    if (s == null) return;
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

  void _onServiceChanged() {
    if (!mounted) return;
    _maybeLoad();
    setState(() {});
  }

  void _maybeLoad() {
    final s = _service;
    if (s == null) return;
    if (_video == null && _thumb == null && !_thumbLoading) {
      final rgb = s.thumbFor(widget.envelope);
      if (rgb != null) {
        _thumbLoading = true;
        final gen = _gen;
        unawaited(
          voxRgbToUiImage(rgb).then((img) {
            if (!mounted || gen != _gen) {
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
    }
    if (_video != null || _loading || _failed) return;
    if (s.stateFor(widget.envelope).status != VoxClipStatus.complete) return;
    _loading = true;
    final gen = _gen;
    unawaited(() async {
      final v = await s.videoFor(widget.envelope);
      if (!mounted || gen != _gen) return;
      setState(() {
        _video = v;
        _failed = v == null;
        _loading = false;
      });
    }());
  }

  Future<void> _download() async {
    final s = _service;
    if (s == null) return;
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

  void _fullScreen() {
    final v = _video;
    if (v == null) return;
    unawaited(
      VoxVideoScreen.open(context, v.frames, wav: v.wav, note: v.soundNote),
    );
  }

  @override
  void dispose() {
    _service?.removeListener(_onServiceChanged);
    _thumb?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = _service;
    final env = widget.envelope;
    final color = widget.textColor;
    final meta = color.withValues(alpha: 0.65);
    if (s == null || !s.videosAvailable) {
      final note = Text(
        '🎬 Video (${env.durationSeconds}s) — this build can\'t play video '
        'messages',
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
    final kb = (env.estimatedCodecBytes / 1000).toStringAsFixed(1);
    final air = s.mediaAirtime(env.totalPackets);
    final String? airHint = air == null
        ? null
        : '~${(air.inMilliseconds / 1000).toStringAsFixed(0)}s air';
    final video = _video;
    final aspect = (video != null
            ? video.frames.width / video.frames.height
            : _thumb != null
            ? _thumb!.width / _thumb!.height
            : 4 / 3)
        .clamp(0.4, 2.5);

    final soundBit = video == null
        ? ''
        : video.soundNote != null
        ? ' · ${video.soundNote}'
        : video.hasSound
        ? ''
        : ' · no sound';
    final String status = switch (st.status) {
      VoxClipStatus.complete when _failed => 'Video could not be decoded',
      VoxClipStatus.complete when video == null => 'Video · decoding…',
      VoxClipStatus.complete =>
        'Video · ${env.durationSeconds}s · $kb KB$soundBit',
      VoxClipStatus.remote when !widget.isOutgoing && st.received > 0 =>
        'Receiving ${st.received}/${st.total}',
      VoxClipStatus.remote =>
        widget.isOutgoing
            ? 'Video · ${env.durationSeconds}s · $kb KB · waiting for viewers'
            : 'Video · ${env.durationSeconds}s · $kb KB · tap to download'
                  '${airHint == null ? '' : ' ($airHint)'}',
      VoxClipStatus.requesting => st.message ?? 'Requesting…',
      VoxClipStatus.receiving => 'Receiving ${st.received}/${st.total}',
      VoxClipStatus.unavailable => st.message ?? 'Video unavailable right now',
    };
    final busy =
        st.status == VoxClipStatus.requesting ||
        st.status == VoxClipStatus.receiving;

    Widget picture;
    if (video != null) {
      picture = VoxVideoView(
        frames: video.frames,
        wav: video.wav,
        fit: BoxFit.cover,
      );
    } else {
      picture = GestureDetector(
        onTap: busy ? null : _download,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (_thumb != null)
              RawImage(
                image: _thumb,
                fit: BoxFit.cover,
                filterQuality: FilterQuality.high,
              )
            else
              ColoredBox(color: color.withValues(alpha: 0.08)),
            Center(
              child: busy || (_loading && !_failed)
                  ? SizedBox(
                      width: 40,
                      height: 40,
                      child: CircularProgressIndicator(
                        strokeWidth: 3,
                        color: _thumb != null ? Colors.white : color,
                        backgroundColor: _thumb != null ? Colors.black26 : null,
                        value: st.status == VoxClipStatus.receiving
                            ? st.progress
                            : null,
                      ),
                    )
                  : st.status == VoxClipStatus.complete
                  ? const VoxPlayBadge()
                  : Icon(
                      st.status == VoxClipStatus.unavailable
                          ? Icons.refresh
                          : Icons.download_for_offline_outlined,
                      size: 40,
                      color: _thumb != null ? Colors.white : meta,
                    ),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 260, maxHeight: 320),
          child: AspectRatio(
            aspectRatio: aspect,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: picture,
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
              child: Text(status, style: TextStyle(color: meta, fontSize: 12)),
            ),
            if (video != null)
              IconButton(
                icon: Icon(Icons.fullscreen, size: 18, color: meta),
                tooltip: 'Full screen',
                visualDensity: VisualDensity.compact,
                onPressed: _fullScreen,
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
            repeater:
                context.select<AppSettingsService, bool>(
                  (a) => a.settings.showRepeaterPath,
                )
                ? st.viaRepeater
                : null,
          ),
      ],
    );
  }
}
