// MeshCore Open TAK - chat bubble content for a VE3 voice message.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../connector/meshcore_connector.dart';
import '../models/contact.dart';
import 'image_message_bubble.dart';
import 'mimi.dart';
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
    final busy =
        st.status == VoxClipStatus.requesting ||
        st.status == VoxClipStatus.receiving;
    final accent = Theme.of(context).colorScheme.primary;

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

    final String subtitle = switch (st.status) {
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
                  Text(
                    'Voice message',
                    style: TextStyle(color: color, fontWeight: FontWeight.w600),
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
                  ListTile(
                    title: const Text('Voice diagnostics'),
                    subtitle: const Text(
                      'Newest first. Copy and share when reporting a problem.',
                    ),
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
                  VoxMimiTile(service: service),
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
