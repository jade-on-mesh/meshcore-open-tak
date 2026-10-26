// MeshCore Open TAK - the walkie-talkie for a channel: hold to talk, hear
// talks as they arrive. See walkie_service.dart.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
import '../models/channel.dart';
import '../models/contact.dart';
import 'walkie_service.dart';
import 'walkie_wire.dart';

/// Opens the walkie for [channel], or the DM with [contact], from the chat
/// composer.
class WalkieButton extends StatelessWidget {
  final Channel? channel;
  final Contact? contact;
  const WalkieButton({super.key, required Channel this.channel})
    : contact = null;
  const WalkieButton.dm({super.key, required Contact this.contact})
    : channel = null;

  @override
  Widget build(BuildContext context) {
    final walkie = context.watch<WalkieService>();
    if (!walkie.available) return const SizedBox.shrink();
    final c = contact;
    final live = c != null
        ? walkie.activeTalkWith(c.publicKeyHex) != null
        : walkie.activeTalkOn(channel!.index) != null;
    return IconButton(
      icon: Icon(
        Icons.record_voice_over_outlined,
        color: live ? Theme.of(context).colorScheme.primary : null,
      ),
      tooltip: context.l10n.walkie_tooltip,
      onPressed: () => c != null
          ? showDmWalkieSheet(context, c)
          : showWalkieSheet(context, channel!),
    );
  }
}

Future<void> showWalkieSheet(BuildContext context, Channel channel) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => WalkieSheet(channel: channel),
    );

/// The walkie for a DM: talks go to [contact] alone.
Future<void> showDmWalkieSheet(BuildContext context, Contact contact) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => WalkieSheet.dm(contact: contact),
    );

class WalkieSheet extends StatefulWidget {
  final Channel? channel;
  final Contact? contact;
  const WalkieSheet({super.key, required Channel this.channel})
    : contact = null;
  const WalkieSheet.dm({super.key, required Contact this.contact})
    : channel = null;

  @override
  State<WalkieSheet> createState() => _WalkieSheetState();
}

class _WalkieSheetState extends State<WalkieSheet> {
  late final WalkieService _walkie;
  String? _message;
  bool _holding = false;

  @override
  void initState() {
    super.initState();
    _walkie = context.read<WalkieService>()..clearError();
    final c = widget.contact;
    if (c != null) {
      _walkie.dmPanelOpened(c.publicKeyHex);
    } else {
      _walkie.panelOpened(widget.channel!.index);
    }
  }

  @override
  void dispose() {
    final c = widget.contact;
    if (c != null) {
      _walkie.dmPanelClosed(c.publicKeyHex);
      if (_walkie.talkingWith == c.publicKeyHex) _walkie.stopTalk();
    } else {
      _walkie.panelClosed(widget.channel!.index);
      if (_walkie.talkingOn == widget.channel!.index) _walkie.stopTalk();
    }
    super.dispose();
  }

  Future<void> _press() async {
    if (_holding) return;
    _holding = true;
    setState(() => _message = null);
    final c = widget.contact;
    final err = c != null
        ? await _walkie.startTalkTo(c)
        : await _walkie.startTalk(widget.channel!);
    if (!mounted) return;
    if (err != null) {
      HapticFeedback.heavyImpact();
      setState(() => _message = err);
    }
  }

  void _release() {
    if (!_holding) return;
    _holding = false;
    _walkie.stopTalk();
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e.logicalKey != LogicalKeyboardKey.space) return KeyEventResult.ignored;
    if (e is KeyDownEvent) {
      _press();
    } else if (e is KeyUpEvent) {
      _release();
    }
    return KeyEventResult.handled;
  }

  String _fmt(Duration d) =>
      '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final walkie = context.watch<WalkieService>();
    final ch = widget.channel;
    final dm = widget.contact;
    final dmKey = dm?.publicKeyHex;
    final mine = dm != null
        ? walkie.talkingWith == dmKey
        : walkie.talkingOn == ch!.index;
    final tx = mine ? walkie.tx : WalkieTx.idle;
    final talk = dm != null
        ? walkie.activeTalkWith(dmKey!)
        : walkie.activeTalkOn(ch!.index);
    final busy = talk != null && !mine;
    final otherChannel =
        (walkie.talkingOn != null || walkie.talkingWith != null) && !mine;
    final direct = ch != null && walkie.isDirect(ch);

    final String status;
    final Color statusColor;
    final IconData statusIcon;
    switch (tx) {
      case WalkieTx.onAir:
        status =
            '${l.walkie_onAir}  ${_fmt(walkie.talkElapsed)} / '
            '${_fmt(walkieMaxTalk)}';
        statusColor = scheme.error;
        statusIcon = Icons.fiber_manual_record;
      case WalkieTx.starting:
        status = l.walkie_starting;
        statusColor = scheme.onSurfaceVariant;
        statusIcon = Icons.hourglass_top;
      case WalkieTx.finishing:
        status = l.walkie_finishing;
        statusColor = scheme.onSurfaceVariant;
        statusIcon = Icons.send;
      case WalkieTx.idle:
        if (talk != null) {
          status = talk.name.isEmpty
              ? l.walkie_someoneTalking
              : l.walkie_nameTalking(talk.name);
          statusColor = scheme.primary;
          statusIcon = talk.playing ? Icons.volume_up : Icons.graphic_eq;
        } else {
          status = l.walkie_clear;
          statusColor = scheme.onSurfaceVariant;
          statusIcon = Icons.check_circle_outline;
        }
    }
    final last = talk == null && tx == WalkieTx.idle
        ? (dm != null ? walkie.lastTalkWith(dmKey!) : walkie.lastTalkOn(ch!.index))
        : null;
    final note = _message ?? (mine ? null : walkie.error);

    final onAir = tx == WalkieTx.onAir || tx == WalkieTx.starting;
    final buttonColor = onAir
        ? scheme.error
        : (busy || otherChannel)
        ? scheme.surfaceContainerHighest
        : scheme.primary;
    final buttonText = onAir
        ? l.walkie_releaseToSend
        : busy
        ? (talk.name.isEmpty
              ? l.walkie_someoneTalking
              : l.walkie_nameTalking(talk.name))
        : l.walkie_holdToTalk;
    final onButton = (busy || otherChannel) && !onAir
        ? scheme.onSurfaceVariant
        : onAir
        ? scheme.onError
        : scheme.onPrimary;

    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.record_voice_over_outlined),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '${l.walkie_title} · ${dm?.name ?? ch!.name}',
                      style: Theme.of(context).textTheme.titleMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(statusIcon, color: statusColor, size: 20),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      status,
                      style: TextStyle(
                        color: statusColor,
                        fontWeight: FontWeight.w600,
                        fontSize: 16,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              if (last != null && last.name.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    l.walkie_lastTalk(last.name),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              const SizedBox(height: 10),
              SizedBox(
                height: 6,
                child: tx == WalkieTx.onAir
                    ? LinearProgressIndicator(
                        value: walkie.talkLevel / 100,
                        color: scheme.error,
                      )
                    : null,
              ),
              const SizedBox(height: 16),
              Center(
                child: Listener(
                  onPointerDown: (_) => _press(),
                  onPointerUp: (_) => _release(),
                  onPointerCancel: (_) => _release(),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    width: 184,
                    height: 184,
                    decoration: BoxDecoration(
                      color: buttonColor,
                      shape: BoxShape.circle,
                      boxShadow: [
                        if (onAir)
                          BoxShadow(
                            color: scheme.error.withValues(alpha: 0.45),
                            blurRadius: 28,
                            spreadRadius: 6,
                          ),
                      ],
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          onAir ? Icons.mic : Icons.mic_none,
                          size: 56,
                          color: onButton,
                        ),
                        const SizedBox(height: 6),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 18),
                          child: Text(
                            buttonText,
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: onButton,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (note != null && note.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    note,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: scheme.error),
                  ),
                ),
              if (dm != null) ...[
                const SizedBox(height: 18),
                Text(
                  walkie.dmRouteKnown(dm)
                      ? l.dmWalkie_routed(dm.name)
                      : l.dmWalkie_noRoute(dm.name),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ] else if (ch != null) ...[
              const SizedBox(height: 18),
              Text(
                l.walkie_reach,
                style: Theme.of(context).textTheme.labelLarge,
              ),
              const SizedBox(height: 6),
              SegmentedButton<bool>(
                segments: [
                  ButtonSegment(
                    value: false,
                    icon: const Icon(Icons.cell_tower),
                    label: Text(l.walkie_viaRepeaters),
                  ),
                  ButtonSegment(
                    value: true,
                    icon: const Icon(Icons.swap_horiz),
                    label: Text(l.walkie_direct),
                  ),
                ],
                selected: {direct},
                onSelectionChanged: tx == WalkieTx.idle
                    ? (v) => walkie.setDirect(ch, v.first)
                    : null,
              ),
              const SizedBox(height: 4),
              Text(
                direct ? l.walkie_directHelp : l.walkie_repeatersHelp,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(l.voiceMute_everyChannel),
                subtitle: Text(l.voiceMute_everyChannelHelp),
                value: walkie.liveAll,
                onChanged: walkie.setLiveAll,
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(l.voiceMute_channel),
                subtitle: Text(l.voiceMute_channelHelp),
                value: walkie.isVoiceMuted(ch),
                onChanged: (v) => walkie.setVoiceMuted(ch, v),
              ),
              ],
              const SizedBox(height: 4),
              Text(
                l.walkie_footer(walkieMaxTalk.inSeconds),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
