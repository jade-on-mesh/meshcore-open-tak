// MeshCore Open TAK - chat docked on the map, like ATAK's GeoChat pane.
//
// Shows one channel (the team channel by default) beside the map in
// landscape or under it in portrait, with a compact composer. Messages that
// carry a position can be tapped to fly the map there.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../connector/meshcore_connector.dart';
import '../connector/meshcore_protocol.dart';
import '../models/channel.dart';
import '../models/channel_message.dart';
import '../screens/channel_chat_screen.dart';
import '../vox/image_send_sheet.dart';
import '../vox/voice_message_bubble.dart';
import '../vox/voice_record_sheet.dart';
import '../vox/voice_service.dart';
import '../vox/voice_wire.dart';
import 'tak/tak_service.dart';
import 'team_service.dart';
import 'watch_feed.dart';

/// Remembers the last channel shown, across map visits.
int? _lastChannelIndex;

/// Picks the channel the pane opens on: the last one used, else the team
/// channel, else the first named channel.
Channel? mapChatDefaultChannel(MeshCoreConnector connector, TeamService? team) {
  final named = [
    for (final c in connector.channels)
      if (c.name.isNotEmpty) c,
  ];
  for (final c in named) {
    if (c.index == _lastChannelIndex) return c;
  }
  final t = team?.teamChannel;
  if (t != null) return t;
  return named.isEmpty ? null : named.first;
}

class MapChatPane extends StatefulWidget {
  final VoidCallback onClose;

  /// Called when a message with a position is tapped.
  final ValueChanged<LatLng>? onLocate;

  /// True when docked at the side (landscape), false when under the map.
  final bool side;

  const MapChatPane({
    super.key,
    required this.onClose,
    this.onLocate,
    this.side = false,
  });

  @override
  State<MapChatPane> createState() => _MapChatPaneState();
}

class _MapChatPaneState extends State<MapChatPane> {
  final _text = TextEditingController();
  final _focus = FocusNode();
  int? _channelIndex;

  /// Showing TAK's All Chat Rooms instead of a mesh channel.
  bool _takMode = false;

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  Channel? _channel(MeshCoreConnector connector, TeamService? team) {
    if (_channelIndex != null) {
      for (final c in connector.channels) {
        if (c.index == _channelIndex) return c;
      }
    }
    return mapChatDefaultChannel(connector, team);
  }

  void _select(Channel c) {
    setState(() {
      _channelIndex = c.index;
      _takMode = false;
    });
    _lastChannelIndex = c.index;
  }

  Future<void> _send(MeshCoreConnector connector, Channel channel) async {
    final text = _text.text.trim();
    if (text.isEmpty) return;
    final maxBytes = maxChannelMessageBytes(connector.selfName);
    if (utf8.encode(text).length > maxBytes) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Too long for one message ($maxBytes bytes)')),
      );
      return;
    }
    _text.clear();
    _focus.requestFocus();
    await connector.sendChannelMessage(channel, text);
  }

  @override
  Widget build(BuildContext context) {
    final connector = context.watch<MeshCoreConnector>();
    TeamService? team;
    try {
      team = context.watch<TeamService>();
    } on ProviderNotFoundException {
      team = null;
    }
    TakService? tak;
    try {
      tak = context.watch<TakService>();
    } on ProviderNotFoundException {
      tak = null;
    }
    final takAvailable = tak != null && (tak.publishing || tak.chat.isNotEmpty);
    if (_takMode && !takAvailable) _takMode = false;
    if (_takMode) return _buildTak(context, connector, team, tak!);
    final scheme = Theme.of(context).colorScheme;
    final channel = _channel(connector, team);
    final channels = [
      for (final c in connector.channels)
        if (c.name.isNotEmpty) c,
    ];

    // Reading the pane counts as reading the channel.
    if (channel != null && connector.getUnreadCountForChannel(channel) > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) connector.markChannelRead(channel.index);
      });
    }

    final messages = channel == null
        ? const <ChannelMessage>[]
        : connector.getChannelMessages(channel);
    final start = messages.length > 150 ? messages.length - 150 : 0;
    final shown = messages.sublist(start).reversed.toList();

    // Callsign -> team colour, so teammates read like ATAK contacts.
    final colors = <String, Color>{
      for (final m in team?.members ?? const <TeamMember>[])
        m.callsign: Color(m.position.color.argb),
    };

    return Material(
      color: scheme.surface,
      elevation: 6,
      child: Column(
        children: [
          // ------------------------------------------------------- header
          Container(
            color: scheme.surfaceContainerHigh,
            padding: const EdgeInsets.fromLTRB(12, 2, 2, 2),
            child: Row(
              children: [
                Icon(Icons.forum, size: 20, color: scheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: channels.isEmpty && !takAvailable
                      ? const Text('No channels')
                      : DropdownButtonHideUnderline(
                          child: DropdownButton<int>(
                            isExpanded: true,
                            value: channel?.index,
                            items: [
                              if (takAvailable) _takMenuItem(),
                              for (final c in channels)
                                DropdownMenuItem(
                                  value: c.index,
                                  child: _ChannelLabel(
                                    channel: c,
                                    isTeam: c.index == team?.teamChannel?.index,
                                    unread: c.index == channel?.index
                                        ? 0
                                        : connector.getUnreadCountForChannel(c),
                                  ),
                                ),
                            ],
                            onChanged: (i) {
                              if (i == _takValue) {
                                setState(() => _takMode = true);
                                return;
                              }
                              for (final c in channels) {
                                if (c.index == i) _select(c);
                              }
                            },
                          ),
                        ),
                ),
                if (channel != null)
                  IconButton(
                    tooltip: 'Open full chat',
                    icon: const Icon(Icons.open_in_full, size: 20),
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ChannelChatScreen(channel: channel),
                      ),
                    ),
                  ),
                IconButton(
                  tooltip: 'Close chat',
                  icon: const Icon(Icons.close),
                  onPressed: widget.onClose,
                ),
              ],
            ),
          ),
          // ----------------------------------------------------- messages
          Expanded(
            child: shown.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        channel == null
                            ? 'Add a channel to chat from the map.'
                            : 'No messages in ${channel.name} yet.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    ),
                  )
                : ListView.builder(
                    reverse: true,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                    itemCount: shown.length,
                    itemBuilder: (context, i) {
                      final m = shown[i];
                      return _PaneMessage(
                        key: ValueKey(m.messageId),
                        message: m,
                        channel: channel!,
                        senderColor: colors[m.senderName],
                        onLocate: widget.onLocate,
                      );
                    },
                  ),
          ),
          // ----------------------------------------------------- composer
          if (channel != null)
            Container(
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: scheme.outlineVariant)),
              ),
              padding: const EdgeInsets.fromLTRB(4, 2, 4, 2),
              child: Row(
                children: [
                  VoxImageButton(
                    recipientLabel: channel.name,
                    onSend: (image) => context
                        .read<VoxVoiceService>()
                        .sendImageToChannel(channel, image),
                  ),
                  VoxMicButton(
                    recipientLabel: channel.name,
                    onSend: (clip) => context
                        .read<VoxVoiceService>()
                        .sendClipToChannel(channel, clip),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _text,
                      focusNode: _focus,
                      enabled: connector.isConnected,
                      minLines: 1,
                      maxLines: 3,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(connector, channel),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: connector.isConnected
                            ? 'Message ${channel.name}'
                            : 'Not connected',
                        border: InputBorder.none,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Send',
                    icon: Icon(Icons.send, color: scheme.primary),
                    onPressed: connector.isConnected
                        ? () => _send(connector, channel)
                        : null,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

const int _takValue = -1;

DropdownMenuItem<int> _takMenuItem() => const DropdownMenuItem(
  value: _takValue,
  child: Row(
    children: [
      Icon(Icons.hub_outlined, size: 16),
      SizedBox(width: 4),
      Flexible(
        child: Text(
          'TAK · All Chat Rooms',
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
    ],
  ),
);

extension on _MapChatPaneState {
  Widget _buildTak(
    BuildContext context,
    MeshCoreConnector connector,
    TeamService? team,
    TakService tak,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final channels = [
      for (final c in connector.channels)
        if (c.name.isNotEmpty) c,
    ];
    final lines = tak.chat.reversed.toList();
    return Material(
      color: scheme.surface,
      elevation: 6,
      child: Column(
        children: [
          Container(
            color: scheme.surfaceContainerHigh,
            padding: const EdgeInsets.fromLTRB(12, 2, 2, 2),
            child: Row(
              children: [
                Icon(Icons.forum, size: 20, color: scheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<int>(
                      isExpanded: true,
                      value: _takValue,
                      items: [
                        _takMenuItem(),
                        for (final c in channels)
                          DropdownMenuItem(
                            value: c.index,
                            child: _ChannelLabel(
                              channel: c,
                              isTeam: c.index == team?.teamChannel?.index,
                              unread: connector.getUnreadCountForChannel(c),
                            ),
                          ),
                      ],
                      onChanged: (i) {
                        for (final c in channels) {
                          if (c.index == i) _select(c);
                        }
                      },
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Close chat',
                  icon: const Icon(Icons.close),
                  onPressed: widget.onClose,
                ),
              ],
            ),
          ),
          Expanded(
            child: lines.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        'No TAK chat yet. Messages here go to TAK users only, '
                        'not over the mesh.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    ),
                  )
                : ListView.builder(
                    reverse: true,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                    itemCount: lines.length,
                    itemBuilder: (context, i) {
                      final l = lines[i];
                      final bg = l.outgoing
                          ? scheme.primaryContainer
                          : scheme.surfaceContainerHighest;
                      final fg = l.outgoing
                          ? scheme.onPrimaryContainer
                          : scheme.onSurface;
                      return Align(
                        alignment: l.outgoing
                            ? Alignment.centerRight
                            : Alignment.centerLeft,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 300),
                          child: Card(
                            margin: const EdgeInsets.symmetric(vertical: 3),
                            color: bg,
                            elevation: 0,
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${l.outgoing ? 'You' : l.callsign} · '
                                    '${_hhmm(l.time)}',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                      color: fg.withValues(alpha: 0.85),
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(l.text, style: TextStyle(color: fg)),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
          Container(
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: scheme.outlineVariant)),
            ),
            padding: const EdgeInsets.fromLTRB(12, 2, 4, 2),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _text,
                    focusNode: _focus,
                    enabled: tak.publishing,
                    minLines: 1,
                    maxLines: 3,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _sendTak(tak),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: tak.publishing
                          ? 'Message TAK users'
                          : 'TAK not connected',
                      border: InputBorder.none,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Send to TAK',
                  icon: Icon(Icons.send, color: scheme.primary),
                  onPressed: tak.publishing ? () => _sendTak(tak) : null,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _sendTak(TakService tak) {
    final t = _text.text.trim();
    if (t.isEmpty) return;
    _text.clear();
    _focus.requestFocus();
    tak.sendChat(t);
  }
}

class _ChannelLabel extends StatelessWidget {
  final Channel channel;
  final bool isTeam;
  final int unread;
  const _ChannelLabel({
    required this.channel,
    required this.isTeam,
    required this.unread,
  });

  @override
  Widget build(BuildContext context) => Row(
    children: [
      if (isTeam) ...[
        const Icon(Icons.shield_outlined, size: 16),
        const SizedBox(width: 4),
      ],
      Flexible(
        child: Text(
          channel.name,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      if (unread > 0) ...[
        const SizedBox(width: 6),
        Badge(label: Text('$unread')),
      ],
    ],
  );
}

String _hhmm(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

class _PaneMessage extends StatelessWidget {
  final ChannelMessage message;
  final Channel channel;
  final Color? senderColor;
  final ValueChanged<LatLng>? onLocate;

  const _PaneMessage({
    super.key,
    required this.message,
    required this.channel,
    this.senderColor,
    this.onLocate,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final m = message;
    final out = m.isOutgoing;
    final env = VoxVoiceEnvelope.tryParse(m.text);
    final item = env == null ? parseWatchMessage(channel, m) : null;
    final pos = item != null && item.hasPosition
        ? LatLng(item.lat!, item.lon!)
        : null;
    final bg = out ? scheme.primaryContainer : scheme.surfaceContainerHighest;
    final fg = out ? scheme.onPrimaryContainer : scheme.onSurface;

    final header = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!out && senderColor != null) ...[
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: senderColor,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 4),
        ],
        Flexible(
          child: Text(
            out ? 'You' : m.senderName,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: fg.withValues(alpha: 0.85),
            ),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          _hhmm(m.timestamp),
          style: TextStyle(fontSize: 11, color: fg.withValues(alpha: 0.6)),
        ),
        if (out && m.status == ChannelMessageStatus.pending) ...[
          const SizedBox(width: 4),
          Icon(Icons.schedule, size: 12, color: fg.withValues(alpha: 0.6)),
        ],
        if (out && m.status == ChannelMessageStatus.failed) ...[
          const SizedBox(width: 4),
          Icon(Icons.error_outline, size: 12, color: scheme.error),
        ],
      ],
    );

    Widget body;
    if (env != null) {
      body = VoxVoiceMessageContent(
        envelope: env,
        isOutgoing: out,
        textColor: fg,
        channelIndex: channel.index,
        sender: out
            ? null
            : context.read<VoxVoiceService>().contactByName(m.senderName),
      );
    } else {
      body = Text(m.text, style: TextStyle(color: fg));
    }

    return Align(
      alignment: out ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 300),
        child: Card(
          margin: const EdgeInsets.symmetric(vertical: 3),
          color: bg,
          elevation: 0,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: pos != null && onLocate != null
                ? () => onLocate!(pos)
                : null,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  header,
                  const SizedBox(height: 2),
                  body,
                  if (pos != null && onLocate != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.place, size: 14, color: scheme.primary),
                          const SizedBox(width: 2),
                          Text(
                            'Show on map',
                            style: TextStyle(
                              fontSize: 12,
                              color: scheme.primary,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Chat button with an unread badge, for the map toolbar.
class MapChatButton extends StatelessWidget {
  final bool open;
  final VoidCallback onPressed;
  const MapChatButton({super.key, required this.open, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final connector = context.watch<MeshCoreConnector>();
    final unread = connector.getTotalChannelsUnreadCount();
    return IconButton(
      tooltip: open ? 'Hide chat' : 'Chat',
      isSelected: open,
      onPressed: onPressed,
      icon: Badge(
        isLabelVisible: unread > 0 && !open,
        label: Text(unread > 99 ? '99+' : '$unread'),
        child: Icon(open ? Icons.forum : Icons.forum_outlined),
      ),
    );
  }
}
