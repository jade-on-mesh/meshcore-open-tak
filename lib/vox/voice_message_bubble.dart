// MeshCore Open VOX - chat bubble content for a VE3 voice message.

import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../connector/meshcore_connector.dart';
import '../models/contact.dart';
import 'voice_service.dart';
import 'voice_wire.dart';

class VoxVoiceMessageContent extends StatefulWidget {
  final VoxVoiceEnvelope envelope;
  final bool isOutgoing;

  /// The contact to fetch audio from (DM partner, or channel sender resolved
  /// by name). Null for outgoing clips or unknown senders.
  final Contact? sender;

  /// Channel the envelope was posted in (null for DMs). Enables the
  /// channel fallback when the sender cannot be reached directly.
  final int? channelIndex;
  final Color textColor;

  const VoxVoiceMessageContent({
    super.key,
    required this.envelope,
    required this.isOutgoing,
    required this.textColor,
    this.sender,
    this.channelIndex,
  });

  @override
  State<VoxVoiceMessageContent> createState() => _VoxVoiceMessageContentState();
}

class _VoxVoiceMessageContentState extends State<VoxVoiceMessageContent> {
  AudioPlayer? _player;
  bool _playing = false;
  bool _playWhenReady = false;
  VoxVoiceService? _service;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final s = context.read<VoxVoiceService>();
    if (s != _service) {
      _service?.removeListener(_onServiceChanged);
      _service = s;
      _service?.addListener(_onServiceChanged);
      unawaited(
        _service?.warmUp(
          widget.envelope,
          sender: widget.sender,
          channelIndex: widget.channelIndex,
        ),
      );
    }
  }

  void _onServiceChanged() {
    final s = _service;
    if (s == null || !mounted) return;
    if (_playWhenReady &&
        s.stateFor(widget.envelope).status == VoxClipStatus.complete) {
      _playWhenReady = false;
      unawaited(_play());
    }
    setState(() {});
  }

  Future<void> _play() async {
    final s = _service;
    if (s == null) return;
    final wav = await s.wavFor(widget.envelope);
    if (wav == null || !mounted) return;
    var player = _player;
    if (player == null) {
      player = _player = AudioPlayer();
      player.onPlayerComplete.listen((_) {
        if (mounted) setState(() => _playing = false);
      });
    }
    setState(() => _playing = true);
    await player.play(BytesSource(wav));
  }

  Future<void> _stop() async {
    await _player?.stop();
    if (mounted) setState(() => _playing = false);
  }

  Future<void> _onTap() async {
    final s = _service;
    if (s == null) return;
    if (_playing) return _stop();
    final st = s.stateFor(widget.envelope);
    if (st.status == VoxClipStatus.complete) return _play();
    if (st.status == VoxClipStatus.requesting ||
        st.status == VoxClipStatus.receiving) {
      return;
    }
    _playWhenReady = true;
    await s.requestClip(
      widget.envelope,
      sender: widget.sender,
      channelIndex: widget.channelIndex,
    );
  }

  @override
  void dispose() {
    _service?.removeListener(_onServiceChanged);
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = _service;
    final env = widget.envelope;
    final color = widget.textColor;
    final meta = color.withValues(alpha: 0.65);
    if (s == null || !s.isAvailable) {
      return Text(
        '🎙 Voice message (${env.durationSeconds}s) — '
        '${s?.unavailableReason ?? 'voice unsupported here'}',
        style: TextStyle(color: meta, fontStyle: FontStyle.italic),
      );
    }
    final st = s.stateFor(env);
    final busy =
        st.status == VoxClipStatus.requesting ||
        st.status == VoxClipStatus.receiving;

    final connector = context.read<MeshCoreConnector>();
    final sf = connector.currentSf;
    final bw = connector.currentBwHz;
    String? airHint;
    if (sf != null && bw != null && bw > 0) {
      final air = voxEstimateAirtime(
        totalPackets: env.totalPackets,
        codecBytesPerPacket: env.mode.bytesPerPacket,
        spreadingFactor: sf,
        bandwidthKhz: bw / 1000,
        codingRate: connector.currentCr ?? 5,
        pathLength: widget.sender?.pathLength.clamp(0, 64) ?? 0,
      );
      airHint = '~${(air.inMilliseconds / 1000).toStringAsFixed(1)}s air';
    }

    final IconData icon = _playing
        ? Icons.stop_circle_outlined
        : st.status == VoxClipStatus.complete
        ? Icons.play_circle_outline
        : st.status == VoxClipStatus.unavailable
        ? Icons.refresh
        : Icons.download_for_offline_outlined;

    final String subtitle = switch (st.status) {
      VoxClipStatus.complete =>
        '${env.durationSeconds}s · Codec2 ${env.mode.label}',
      VoxClipStatus.remote =>
        widget.isOutgoing
            ? '${env.durationSeconds}s · waiting for listeners'
            : '${env.durationSeconds}s · tap to download'
                  '${airHint == null ? '' : ' ($airHint)'}',
      VoxClipStatus.requesting => st.message ?? 'Requesting…',
      VoxClipStatus.receiving => 'Receiving ${st.received}/${st.total}',
      VoxClipStatus.unavailable => st.message ?? 'Voice unavailable right now',
    };

    return InkWell(
      onTap: busy ? null : _onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 36,
              height: 36,
              child: busy
                  ? Padding(
                      padding: const EdgeInsets.all(6),
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: color,
                        value: st.status == VoxClipStatus.receiving
                            ? st.progress
                            : null,
                      ),
                    )
                  : Icon(icon, size: 34, color: color),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Voice message',
                    style: TextStyle(color: color, fontWeight: FontWeight.w600),
                  ),
                  Text(subtitle, style: TextStyle(color: meta, fontSize: 12)),
                ],
              ),
            ),
            IconButton(
              icon: Icon(Icons.info_outline, size: 18, color: meta),
              tooltip: 'Voice diagnostics',
              visualDensity: VisualDensity.compact,
              onPressed: () => showVoxVoiceLog(context, s),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shows VOX's voice diagnostic log with a copy button.
void showVoxVoiceLog(BuildContext context, VoxVoiceService service) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) {
      final lines = [
        service.radioSummary(),
        ...service.log.reversed.map((e) => e.toString()),
      ];
      final text = lines.join('\n');
      return SafeArea(
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.7,
          child: Column(
            children: [
              ListTile(
                title: const Text('Voice diagnostics'),
                subtitle: const Text('Newest first. Copy and share when reporting a problem.'),
                trailing: IconButton(
                  icon: const Icon(Icons.copy),
                  tooltip: 'Copy',
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: text));
                    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                      const SnackBar(content: Text('Copied')),
                    );
                  },
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: lines.length,
                  itemBuilder: (_, i) => Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: SelectableText(
                      lines[i],
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
