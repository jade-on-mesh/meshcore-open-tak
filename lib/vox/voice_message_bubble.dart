// MeshCore Open TAK - chat bubble content for a VE3 voice message.

import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../connector/meshcore_connector.dart';
import '../l10n/l10n.dart';
import '../models/channel.dart';
import '../models/contact.dart';
import '../services/chat_text_scale_service.dart';
import 'image_message_bubble.dart';
import 'mimi.dart';
import 'voice_service.dart';
import 'voice_wire.dart';
import 'vox_voice_enhance.dart';
import 'walkie_wire.dart' show voxWaveBars;

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

  @override
  void didUpdateWidget(VoxVoiceMessageContent old) {
    super.didUpdateWidget(old);
    if (old.envelope.sessionId != widget.envelope.sessionId) {
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
    if (mounted) setState(() {});
  }

  Future<void> _onTap() async {
    final s = _service;
    if (s == null) return;
    final env = widget.envelope;
    if (s.playbackFor(env) != VoxPlayback.idle) return s.stopPlayback();
    final st = s.stateFor(env);
    if (st.status == VoxClipStatus.complete) {
      if (!s.canPlay(env)) {
        // A Mimi clip on a phone without the model: offer the download.
        showVoxVoiceLog(context, s);
        return;
      }
      return s.play(env);
    }
    // Most of it is here: play it now with silence for what's missing (the
    // rest keeps coming; a gave-up fetch starts again).
    if (s.canPlayPartial(env)) {
      if (st.status == VoxClipStatus.unavailable ||
          st.status == VoxClipStatus.remote) {
        unawaited(
          s.requestClip(
            env,
            sender: widget.sender,
            channelIndex: widget.channelIndex,
          ),
        );
      }
      return s.playPartial(env);
    }
    if (st.status == VoxClipStatus.requesting ||
        st.status == VoxClipStatus.receiving) {
      return;
    }
    await s.requestAndPlay(
      env,
      sender: widget.sender,
      channelIndex: widget.channelIndex,
    );
  }

  @override
  void dispose() {
    _service?.removeListener(_onServiceChanged);
    super.dispose();
  }

  static String _clock(Duration d) =>
      '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final media = _buildMedia(context);
    final caption = widget.envelope.caption;
    // A photo puts its caption under the picture itself; a talk's caption is
    // only its marker.
    if (caption.isEmpty || widget.envelope.isImage || widget.envelope.isTalk) {
      return media;
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        media,
        const SizedBox(height: 4),
        VoxCaption(caption, color: widget.textColor),
      ],
    );
  }

  Widget _buildMedia(BuildContext context) {
    if (widget.envelope.isImage) {
      return VoxImageMessageContent(
        key: ValueKey('vox-image-${widget.envelope.sessionId}'),
        envelope: widget.envelope,
        isOutgoing: widget.isOutgoing,
        textColor: widget.textColor,
        sender: widget.sender,
        channelIndex: widget.channelIndex,
      );
    }
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
    final playback = s.playbackFor(env);
    final partial = s.canPlayPartial(env);
    final busy =
        (st.status == VoxClipStatus.requesting ||
            st.status == VoxClipStatus.receiving) &&
        !partial &&
        playback == VoxPlayback.idle;
    final accent = Theme.of(context).colorScheme.primary;
    final talk = s.isTalk(env);

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

    final IconData icon = st.status == VoxClipStatus.complete
        ? (s.canPlay(env) ? Icons.play_circle_outline : Icons.graphic_eq)
        : st.status == VoxClipStatus.unavailable
        ? Icons.refresh
        : Icons.download_for_offline_outlined;

    final gapsNote = partial ? ' · tap to play with gaps' : '';
    final String subtitle = switch (st.status) {
      _
          when st.status != VoxClipStatus.complete &&
              playback == VoxPlayback.playing =>
        'Playing with gaps · tap to stop',
      _
          when st.status != VoxClipStatus.complete &&
              playback == VoxPlayback.preparing =>
        'Preparing audio…',
      VoxClipStatus.complete when !s.canPlay(env) =>
        'Mimi voice · tap to get the voice model '
            '(${VoxMimi.downloadMb} MB) to play',
      VoxClipStatus.complete when playback == VoxPlayback.preparing =>
        'Preparing audio…',
      VoxClipStatus.complete when playback == VoxPlayback.playing =>
        'Playing · tap to stop',
      VoxClipStatus.complete =>
        '${env.durationSeconds}s · '
            '${env.mode.isMimi ? 'Mimi' : 'Codec2 ${env.mode.label}'}',
      // Pushed (or sent for someone else) and arriving unasked.
      VoxClipStatus.remote when !widget.isOutgoing && st.received > 0 =>
        'Receiving ${st.received}/${st.total}$gapsNote',
      VoxClipStatus.remote =>
        widget.isOutgoing
            ? '${env.durationSeconds}s · waiting for listeners'
            : '${env.durationSeconds}s · tap to download'
                  '${airHint == null ? '' : ' ($airHint)'}',
      VoxClipStatus.requesting => '${st.message ?? 'Requesting…'}$gapsNote',
      VoxClipStatus.receiving =>
        'Receiving ${st.received}/${st.total}$gapsNote',
      VoxClipStatus.unavailable =>
        '${st.message ?? 'Voice unavailable right now'}$gapsNote',
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
              child: switch (playback) {
                // Decoding (Mimi takes a few seconds): a spinning ring in the
                // accent colour around a waveform.
                VoxPlayback.preparing => Stack(
                  alignment: Alignment.center,
                  children: [
                    SizedBox.expand(
                      child: CircularProgressIndicator(
                        strokeWidth: 3,
                        color: accent,
                      ),
                    ),
                    Icon(Icons.graphic_eq, size: 18, color: accent),
                  ],
                ),
                // Playing: the ring fills as the clip plays, around a stop.
                VoxPlayback.playing => ValueListenableBuilder<double>(
                  valueListenable: s.playbackFraction,
                  builder: (_, f, _) => Stack(
                    alignment: Alignment.center,
                    children: [
                      SizedBox.expand(
                        child: CircularProgressIndicator(
                          strokeWidth: 3,
                          value: f,
                          color: accent,
                          backgroundColor: accent.withValues(alpha: 0.2),
                        ),
                      ),
                      Icon(Icons.stop_rounded, size: 20, color: accent),
                    ],
                  ),
                ),
                VoxPlayback.idle when busy => Padding(
                  padding: const EdgeInsets.all(6),
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    color: color,
                    value: st.status == VoxClipStatus.receiving
                        ? st.progress
                        : null,
                  ),
                ),
                VoxPlayback.idle => Icon(icon, size: 34, color: color),
              },
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (talk)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.record_voice_over_outlined,
                          size: 16,
                          color: accent,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          'Talk',
                          style: TextStyle(
                            color: color,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    )
                  else
                    Text(
                      'Voice message',
                      style: TextStyle(
                        color: color,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  if (talk)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: playback == VoxPlayback.playing
                          ? ValueListenableBuilder<double>(
                              valueListenable: s.playbackFraction,
                              builder: (_, f, _) => VoxWaveform(
                                bars: s.waveformFor(env),
                                played: f,
                                color: meta,
                                playedColor: accent,
                              ),
                            )
                          : VoxWaveform(
                              bars: s.waveformFor(env),
                              played: 0,
                              color: meta,
                              playedColor: accent,
                            ),
                    ),
                  if (playback == VoxPlayback.playing)
                    ValueListenableBuilder<double>(
                      valueListenable: s.playbackFraction,
                      builder: (_, f, _) => Text(
                        'Playing ${_clock(s.playbackLength * f)} / '
                        '${_clock(s.playbackLength)}',
                        style: TextStyle(color: meta, fontSize: 12),
                      ),
                    )
                  else
                    Text(subtitle, style: TextStyle(color: meta, fontSize: 12)),
                  if (!widget.isOutgoing &&
                      st.status == VoxClipStatus.complete &&
                      st.via != null)
                    VoxReceivedViaLabel(
                      via: st.via!,
                      color: meta,
                      repeater: st.viaRepeater,
                    ),
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

/// A clip's loudness as bars; those before [played] (0..1) in [playedColor].
/// With no [bars] yet (not downloaded), a flat placeholder.
class VoxWaveform extends StatelessWidget {
  final List<double>? bars;
  final double played;
  final Color color;
  final Color playedColor;
  final double width;
  final double height;

  const VoxWaveform({
    super.key,
    required this.bars,
    required this.played,
    required this.color,
    required this.playedColor,
    this.width = 160,
    this.height = 26,
  });

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: Size(width, height),
    painter: _WavePainter(bars, played, color, playedColor),
  );
}

class _WavePainter extends CustomPainter {
  _WavePainter(this.bars, this.played, this.color, this.playedColor);

  final List<double>? bars;
  final double played;
  final Color color;
  final Color playedColor;

  @override
  void paint(Canvas canvas, Size size) {
    final b = bars;
    final n = b?.length ?? voxWaveBars;
    if (n == 0) return;
    final step = size.width / n;
    final w = max(1.5, step * 0.6);
    final paint = Paint()
      ..strokeWidth = w
      ..strokeCap = StrokeCap.round;
    final mid = size.height / 2;
    for (var i = 0; i < n; i++) {
      // -1: that part hasn't arrived yet (drawn as the placeholder).
      final pending = b == null || b[i] < 0;
      final v = pending ? 0.08 : b[i];
      final h = max(w, v * size.height);
      final x = step * i + step / 2;
      paint.color = (i + 0.5) / n <= played
          ? playedColor
          : color.withValues(alpha: pending ? 0.35 : 0.75);
      canvas.drawLine(Offset(x, mid - h / 2), Offset(x, mid + h / 2), paint);
    }
  }

  @override
  bool shouldRepaint(_WavePainter old) =>
      old.bars != bars ||
      old.played != played ||
      old.color != color ||
      old.playedColor != playedColor;
}

/// Shows VOX's voice diagnostic log with a copy button.
void showVoxVoiceLog(BuildContext context, VoxVoiceService service) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) {
      return SafeArea(
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.8,
          child: ValueListenableBuilder<int>(
            valueListenable: service.logVersion,
            builder: (context, _, _) {
              final lines = [
                service.radioSummary(),
                ...service.log.reversed.map((e) => e.toString()),
              ];
              final text = lines.join('\n');
              return Column(
                children: [
                  const ListTile(
                    title: Text('Voice diagnostics'),
                    subtitle: Text(
                      'Newest first. Copy or share the whole log when '
                      'reporting a problem.',
                    ),
                  ),
                  // Buttons, not an icon at the edge: on a phone the icon
                  // was off screen and the log can't be selected in one go.
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        FilledButton.tonalIcon(
                          icon: const Icon(Icons.copy),
                          label: const Text('Copy log'),
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: text));
                            ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                              const SnackBar(content: Text('Copied')),
                            );
                          },
                        ),
                        FilledButton.tonalIcon(
                          icon: const Icon(Icons.share),
                          label: const Text('Share log'),
                          onPressed: () => SharePlus.instance.share(
                            ShareParams(
                              text: text,
                              subject: 'MeshCore Open TAK voice diagnostics',
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  VoxMimiTile(service: service),
                  VoxEnhanceVoiceTile(service: service),
                  VoxCodec2QualityTile(service: service),
                  VoxAutoPlayTile(service: service),
                  VoxForcedRouteTile(service: service),
                  ListTile(
                    leading: const Icon(Icons.network_ping),
                    title: const Text('Link test'),
                    subtitle: const Text(
                      'Ping a contact over raw data: no repeaters, their '
                      'stored route, and your forced repeaters. Their app '
                      'must be open.',
                    ),
                    onTap: () => _pickLinkTestTarget(context, service),
                  ),
                  ListTile(
                    leading: const Icon(Icons.speed),
                    title: const Text('Transfer test'),
                    subtitle: const Text(
                      'Send a small test photo a few times to a contact or '
                      'channel, then see how many arrived, how fast, and how '
                      'many requests it took. Receivers need this app, open.',
                    ),
                    onTap: () => _runTransferTest(context, service),
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
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      );
    },
  );
}

Future<void> _pickLinkTestTarget(
  BuildContext context,
  VoxVoiceService service,
) async {
  final contacts = service.chatContacts;
  final picked = await showDialog<Contact>(
    context: context,
    builder: (context) => SimpleDialog(
      title: const Text('Link test with'),
      children: contacts.isEmpty
          ? [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('No chat contacts yet.'),
              ),
            ]
          : [
              for (final c in contacts)
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(context, c),
                  child: Text(
                    '${c.name}  ·  ${c.pathLength < 0 ? 'no route' : '${c.pathLength} hops'}',
                  ),
                ),
            ],
    ),
  );
  if (picked != null) unawaited(service.sendLinkTest(picked));
}

Future<void> _runTransferTest(
  BuildContext context,
  VoxVoiceService service,
) async {
  if (service.transferTestRunning) {
    await _showTransferProgress(context, service, null);
    return;
  }
  final contacts = service.chatContacts;
  final channels = service.namedChannels;
  var count = 3;
  final picked = await showDialog<Object>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => SimpleDialog(
        title: const Text('Transfer test to'),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                const Text('Photos'),
                const SizedBox(width: 12),
                SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 3, label: Text('3')),
                    ButtonSegment(value: 5, label: Text('5')),
                    ButtonSegment(value: 10, label: Text('10')),
                  ],
                  selected: {count},
                  onSelectionChanged: (v) => setState(() => count = v.first),
                ),
              ],
            ),
          ),
          if (channels.isNotEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(24, 16, 24, 4),
              child: Text('Channels'),
            ),
          for (final ch in channels)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, ch),
              child: Text('#${ch.name}'),
            ),
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 16, 24, 4),
            child: Text('Contacts'),
          ),
          if (contacts.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 24, vertical: 8),
              child: Text('No chat contacts yet.'),
            ),
          for (final c in contacts)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, c),
              child: Text(
                '${c.name}  ·  ${c.pathLength < 0 ? 'no route' : '${c.pathLength} hops'}',
              ),
            ),
        ],
      ),
    ),
  );
  if (picked == null || !context.mounted) return;
  final run = service.runTransferTest(
    contact: picked is Contact ? picked : null,
    channel: picked is Channel ? picked : null,
    count: count,
  );
  await _showTransferProgress(context, service, run);
}

/// The running test's progress, then its results ([run] null: progress
/// only, for a test started earlier).
Future<void> _showTransferProgress(
  BuildContext context,
  VoxVoiceService service,
  Future<List<String>>? run,
) => showDialog<void>(
  context: context,
  builder: (context) => AlertDialog(
    title: const Text('Transfer test'),
    content: FutureBuilder<List<String>>(
      future: run,
      builder: (context, snap) {
        final lines = snap.data;
        if (lines != null) {
          return SingleChildScrollView(child: SelectableText(lines.join('\n')));
        }
        return ValueListenableBuilder<String?>(
          valueListenable: service.transferTestStatus,
          builder: (context, status, _) => Row(
            children: [
              if (status != null) ...[
                const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 16),
              ],
              Expanded(
                child: Text(status ?? 'Done: the results are in the log.'),
              ),
            ],
          ),
        );
      },
    ),
    actions: [
      ValueListenableBuilder<String?>(
        valueListenable: service.transferTestStatus,
        builder: (context, status, _) => status == null
            ? const SizedBox.shrink()
            : TextButton(
                onPressed: service.stopTransferTest,
                child: const Text('Stop'),
              ),
      ),
      FutureBuilder<List<String>>(
        future: run,
        builder: (context, snap) => snap.data == null
            ? const SizedBox.shrink()
            : TextButton(
                onPressed: () => Clipboard.setData(
                  ClipboardData(text: snap.data!.join('\n')),
                ),
                child: const Text('Copy'),
              ),
      ),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Close'),
      ),
    ],
  ),
);

/// Auto-play settings: play new voice DMs as they arrive.
class VoxAutoPlayTile extends StatelessWidget {
  final VoxVoiceService service;
  const VoxAutoPlayTile({super.key, required this.service});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SwitchListTile(
            secondary: const Icon(Icons.volume_up_outlined),
            title: const Text('Auto-play voice, auto-show photos'),
            subtitle: const Text(
              'Download new voice and photo DMs as soon as they arrive, '
              'and play voice messages.',
            ),
            value: service.autoPlay,
            onChanged: service.setAutoPlay,
          ),
          if (service.autoPlay)
            SwitchListTile(
              secondary: const SizedBox(width: 24),
              title: const Text('Also auto-download in channels'),
              subtitle: const Text(
                'Off: channel clips auto-play only if they reach you anyway. '
                'On: every listener pulls its own copy, which adds airtime '
                'on busy channels.',
              ),
              value: service.autoDownloadChannels,
              onChanged: service.setAutoDownloadChannels,
            ),
          SwitchListTile(
            secondary: const Icon(Icons.bolt_outlined),
            title: const Text('Send channel photos and voice right away'),
            subtitle: const Text(
              'Your photos and voice clips go straight to the radios in '
              'range (not relayed), so they are there when opened. '
              'Listeners further away still ask for them.',
            ),
            value: service.pushChannelClips,
            onChanged: service.setPushChannelClips,
          ),
        ],
      ),
    );
  }
}

/// Testing toggle: force voice raw data through chosen repeaters.
class VoxForcedRouteTile extends StatelessWidget {
  final VoxVoiceService service;
  const VoxForcedRouteTile({super.key, required this.service});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final keys = service.forcedRepeaterKeys;
        final on = service.forceRepeaterRoute && keys.isNotEmpty;
        return SwitchListTile(
          title: const Text('Force voice through repeaters'),
          subtitle: Text(
            keys.isEmpty
                ? 'Testing only. Pick repeaters to route voice through, even '
                      'when the other device is in direct range.'
                : '${on ? 'On' : 'Off'} · via ${service.forcedRouteLabel()}'
                      ' · tap to change. Enable on both devices.',
          ),
          value: on,
          onChanged: (v) async {
            if (v && keys.isEmpty) {
              final picked = await pickVoxRepeaters(context, service);
              if (picked != null && picked.isNotEmpty) {
                await service.setForceRepeaterRoute(true, picked);
              }
            } else {
              await service.setForceRepeaterRoute(v, keys);
            }
          },
          secondary: IconButton(
            icon: const Icon(Icons.alt_route),
            tooltip: 'Choose repeaters',
            onPressed: () async {
              final picked = await pickVoxRepeaters(context, service);
              if (picked != null) {
                await service.setForceRepeaterRoute(picked.isNotEmpty, picked);
              }
            },
          ),
        );
      },
    );
  }
}

/// Lets the user pick repeaters in route order (tap order). Returns the
/// selected public keys, or null if cancelled.
Future<List<String>?> pickVoxRepeaters(
  BuildContext context,
  VoxVoiceService service,
) {
  final candidates = service.repeaterCandidates;
  final selected = [...service.forcedRepeaterKeys];
  return showDialog<List<String>>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('Route voice via'),
        content: SizedBox(
          width: double.maxFinite,
          child: candidates.isEmpty
              ? const Text(
                  'No repeaters in your contacts yet. Add a nearby repeater '
                  'from its advert first.',
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Tap repeaters in order, starting from the one nearest '
                      'the listener. One nearby repeater is usually enough. '
                      'Replies use the reverse order.',
                      style: TextStyle(fontSize: 12),
                    ),
                    const SizedBox(height: 8),
                    Flexible(
                      child: ListView(
                        shrinkWrap: true,
                        children: [
                          for (final c in candidates)
                            CheckboxListTile(
                              dense: true,
                              value: selected.contains(c.publicKeyHex),
                              title: Text(c.name),
                              subtitle: Text(
                                'hash ${c.publicKeyHex.substring(0, 2)} · '
                                '${c.pathLength < 0
                                    ? 'no route'
                                    : c.pathLength == 0
                                    ? 'direct neighbour'
                                    : '${c.pathLength} hops'}',
                              ),
                              secondary: selected.contains(c.publicKeyHex)
                                  ? CircleAvatar(
                                      radius: 12,
                                      child: Text(
                                        '${selected.indexOf(c.publicKeyHex) + 1}',
                                        style: const TextStyle(fontSize: 12),
                                      ),
                                    )
                                  : null,
                              onChanged: (v) => setState(() {
                                if (v == true) {
                                  selected.add(c.publicKeyHex);
                                } else {
                                  selected.remove(c.publicKeyHex);
                                }
                              }),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, const <String>[]),
            child: const Text('Clear'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, selected),
            child: const Text('Use route'),
          ),
        ],
      ),
    ),
  );
}

/// The Codec2 rate: 1200 / 1600 / 3200 ([voxCodec2RecordModes]).
class VoxCodec2QualityPicker extends StatelessWidget {
  final VoxVoiceService service;

  /// Called after the rate changes (the record sheet re-encodes its clip).
  final ValueChanged<VoxVoiceMode>? onChanged;
  final bool enabled;

  const VoxCodec2QualityPicker({
    super.key,
    required this.service,
    this.onChanged,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) => SegmentedButton<VoxVoiceMode>(
        showSelectedIcon: false,
        segments: [
          for (final m in voxCodec2RecordModes)
            ButtonSegment(value: m, label: Text(m.label)),
        ],
        selected: {service.codec2Mode},
        onSelectionChanged: enabled
            ? (s) async {
                await service.setCodec2Mode(s.first);
                onChanged?.call(s.first);
              }
            : null,
      ),
    );
  }
}

/// Voice settings: the Codec2 rate, with what each costs.
class VoxCodec2QualityTile extends StatelessWidget {
  final VoxVoiceService service;
  const VoxCodec2QualityTile({super.key, required this.service});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.record_voice_over_outlined),
      title: const Text('Codec2 quality (bps)'),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            VoxCodec2QualityPicker(service: service),
            const SizedBox(height: 6),
            const Text(
              'For clips sent as Codec2. Higher is clearer but takes longer '
              'to send: 1600 uses a third more airtime than 1200, 3200 '
              'nearly three times as much. Every VE3 app, and Wadamesh on a '
              'T-Deck, plays all three.',
            ),
          ],
        ),
      ),
    );
  }
}

/// Mimi voice model: download / progress / ready, and the send preference.
class VoxMimiTile extends StatelessWidget {
  final VoxVoiceService service;
  const VoxMimiTile({super.key, required this.service});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final mimi = service.mimi;
        final size = '${VoxMimi.downloadMb} MB';
        switch (mimi.state) {
          case VoxMimiState.ready:
            return GestureDetector(
              onLongPress: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (c) => AlertDialog(
                    title: const Text('Delete Mimi voice model?'),
                    content: Text(
                      'Frees $size. Mimi clips won\'t play until you download '
                      'it again, and new clips will be sent with Codec2.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(c, false),
                        child: const Text('Cancel'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(c, true),
                        child: const Text('Delete'),
                      ),
                    ],
                  ),
                );
                if (ok == true) await mimi.deleteModel();
              },
              child: SwitchListTile(
                secondary: const Icon(Icons.graphic_eq),
                title: const Text('Send voice with Mimi'),
                subtitle: const Text(
                  'Clearer voice, about the same data as Codec2 1200. Only MeshCore Open TAK '
                  'can play Mimi clips; turn off to send Codec2, which other '
                  'VE3 voice apps can play. Long-press to delete the model.',
                ),
                value: service.preferMimi,
                onChanged: service.setPreferMimi,
              ),
            );
          case VoxMimiState.downloading:
            return ListTile(
              leading: const Icon(Icons.downloading),
              title: Text(
                'Downloading Mimi voice model '
                '${(mimi.progress * 100).round()}%',
              ),
              subtitle: LinearProgressIndicator(value: mimi.progress),
              trailing: TextButton(
                onPressed: mimi.cancelDownload,
                child: const Text('Cancel'),
              ),
            );
          case VoxMimiState.missing:
          case VoxMimiState.failed:
            return ListTile(
              leading: const Icon(Icons.graphic_eq),
              title: const Text('Mimi voice model'),
              subtitle: Text(
                mimi.state == VoxMimiState.failed
                    ? 'Download failed: ${mimi.error}. Tap to retry.'
                    : 'Much clearer voice for the same airtime. One-time '
                          '$size download (Wi-Fi recommended). Needed to send '
                          'and play Mimi clips.',
              ),
              trailing: FilledButton(
                onPressed: mimi.download,
                child: const Text('Get'),
              ),
            );
        }
      },
    );
  }
}

/// The AI voice restorer: download / progress / on-off.
class VoxEnhanceVoiceTile extends StatelessWidget {
  final VoxVoiceService service;
  const VoxEnhanceVoiceTile({super.key, required this.service});

  @override
  Widget build(BuildContext context) {
    if (!VoxVoiceEnhancer.supported) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final e = service.restorer;
        final size = '${e.downloadMb} MB';
        switch (e.state) {
          case VoxVoiceEnhanceState.ready:
            return GestureDetector(
              onLongPress: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (c) => AlertDialog(
                    title: const Text('Delete voice restorer?'),
                    content: Text(
                      'Frees $size. Codec2 clips will play as decoded.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(c, false),
                        child: const Text('Cancel'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(c, true),
                        child: const Text('Delete'),
                      ),
                    ],
                  ),
                );
                if (ok == true) await e.deleteModel();
              },
              child: SwitchListTile(
                secondary: const Icon(Icons.record_voice_over),
                title: const Text('Restore Codec2 voice (AI)'),
                subtitle: const Text(
                  'Rebuilds the whole voice from Codec2: less buzzy and '
                  'robotic, with the treble filled in. Long-press to delete '
                  'the model.',
                ),
                value: service.restoreVoice,
                onChanged: service.setRestoreVoice,
              ),
            );
          case VoxVoiceEnhanceState.downloading:
            return ListTile(
              leading: const Icon(Icons.downloading),
              title: Text(
                'Downloading voice restorer ${(e.progress * 100).round()}%',
              ),
              subtitle: LinearProgressIndicator(value: e.progress),
              trailing: TextButton(
                onPressed: e.cancelDownload,
                child: const Text('Cancel'),
              ),
            );
          case VoxVoiceEnhanceState.missing:
          case VoxVoiceEnhanceState.failed:
            return ListTile(
              leading: const Icon(Icons.record_voice_over),
              title: const Text('AI voice restorer'),
              subtitle: Text(
                e.state == VoxVoiceEnhanceState.failed
                    ? 'Download failed: ${e.error}. Tap Get to retry.'
                    : 'Makes Codec2 clips sound clearer and less robotic on '
                          'this phone. One-time $size download (Wi-Fi '
                          'recommended).',
              ),
              trailing: FilledButton(
                onPressed: e.download,
                child: const Text('Get'),
              ),
            );
        }
      },
    );
  }
}

/// The text sent with a photo or voice clip, in the bubble's text style and
/// no wider than a photo.
class VoxCaption extends StatelessWidget {
  final String text;
  final Color color;
  const VoxCaption(this.text, {super.key, required this.color});

  @override
  Widget build(BuildContext context) {
    final scale = context.select<ChatTextScaleService, double>(
      (service) => service.scale,
    );
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 260),
      child: Text(
        text,
        style: TextStyle(color: color, fontSize: 14 * scale),
      ),
    );
  }
}

/// "Received via MediaMesh" under a downloaded photo or voice clip: which radio
/// profile its packets came over (Wadamesh with MediaMesh on reports it).
class VoxReceivedViaLabel extends StatelessWidget {
  final VoxReceivedVia via;
  final Color color;

  /// The MediaMesh repeater its last radio2 packet came through ("1ffb").
  final String? repeater;
  const VoxReceivedViaLabel({
    super.key,
    required this.via,
    required this.color,
    this.repeater,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final label = switch (via) {
      VoxReceivedVia.mediaMesh => l10n.vox_receivedViaMediaMesh,
      VoxReceivedVia.mainMesh => l10n.vox_receivedViaMainMesh,
      VoxReceivedVia.both => l10n.vox_receivedViaBoth,
    };
    final text = repeater != null && via != VoxReceivedVia.mainMesh
        ? '$label ($repeater)'
        : label;
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            via == VoxReceivedVia.mainMesh
                ? Icons.hub_outlined
                : Icons.perm_media_outlined,
            size: 12,
            color: color,
          ),
          const SizedBox(width: 4),
          Flexible(
            child: Text(text, style: TextStyle(color: color, fontSize: 11)),
          ),
        ],
      ),
    );
  }
}
