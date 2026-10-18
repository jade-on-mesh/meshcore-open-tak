// MeshCore Open TAK - pins shared in chat, for the Tactical Pins list.
//
// The map shows pins from several places: team pins (TeamService.markers),
// ATAK points relayed over the mesh (TeamService.points), TAK Server markers
// (TakService.entities) and `m:lat,lon|label|flags` pins anyone shares in a
// chat or channel (MeshCore Open's "share location"). This collects the last
// one, the same way the map does (map_screen.dart's _collectSharedMarkers),
// so the Pins list can show every pin, whoever put it down.

import '../connector/meshcore_connector.dart';
import '../screens/map_screen.dart' show buildSharedMarkerKey, parseMarkerText;

/// A pin someone shared in a chat or channel; the newest position of each.
class ChatPin {
  final String id;
  final double lat, lon;
  final String label;
  final String fromName;

  /// The contact or channel it was shared in.
  final String source;
  final DateTime time;
  final bool isChannel;

  const ChatPin({
    required this.id,
    required this.lat,
    required this.lon,
    required this.label,
    required this.fromName,
    required this.source,
    required this.time,
    required this.isChannel,
  });
}

/// Changes when any conversation gains or loses messages: a cheap check for
/// `context.select`, so the Pins list rescans only then.
int chatPinsSignature(MeshCoreConnector c) {
  final parts = <Object?>[c.selfName];
  for (final contact in c.contacts) {
    final m = c.getMessages(contact);
    parts.add(
      Object.hash(
        contact.publicKeyHex,
        contact.name,
        m.length,
        m.isEmpty ? null : m.last.messageId,
      ),
    );
  }
  for (final ch in c.channels) {
    final m = c.getChannelMessages(ch);
    parts.add(
      Object.hash(
        ch.index,
        ch.name,
        m.length,
        m.isEmpty ? null : m.last.messageId,
      ),
    );
  }
  return Object.hashAll(parts);
}

int? _cacheSig;
List<ChatPin> _cache = const [];

/// Every pin shared in chat, newest first. [selfName] names my own.
List<ChatPin> collectChatPins(MeshCoreConnector c, {required String selfName}) {
  final sig = Object.hash(chatPinsSignature(c), selfName);
  if (sig == _cacheSig) return _cache;
  final latest = <String, ChatPin>{};
  void add(ChatPin p) {
    final cur = latest[p.id];
    if (cur == null || !p.time.isBefore(cur.time)) latest[p.id] = p;
  }

  for (final contact in c.contacts) {
    for (final m in c.getMessages(contact)) {
      final p = parseMarkerText(m.text);
      if (p == null) continue;
      final from = m.isOutgoing ? selfName : contact.name;
      add(
        ChatPin(
          id: buildSharedMarkerKey(
            sourceId: contact.publicKeyHex,
            label: p.label,
            fromName: from,
            flags: p.flags,
            isChannel: false,
          ),
          lat: p.position.latitude,
          lon: p.position.longitude,
          label: p.label,
          fromName: from,
          source: contact.name,
          time: m.timestamp,
          isChannel: false,
        ),
      );
    }
  }
  for (final ch in c.channels.where((ch) => !ch.isEmpty)) {
    for (final m in c.getChannelMessages(ch)) {
      final p = parseMarkerText(m.text);
      if (p == null) continue;
      add(
        ChatPin(
          id: buildSharedMarkerKey(
            sourceId: 'channel:${ch.index}',
            label: p.label,
            fromName: m.senderName,
            flags: p.flags,
            isChannel: true,
          ),
          lat: p.position.latitude,
          lon: p.position.longitude,
          label: p.label,
          fromName: m.isOutgoing ? selfName : m.senderName,
          source: ch.name.isEmpty ? 'Channel ${ch.index}' : ch.name,
          time: m.timestamp,
          isChannel: true,
        ),
      );
    }
  }
  final out = latest.values.toList()..sort((a, b) => b.time.compareTo(a.time));
  _cacheSig = sig;
  _cache = List.unmodifiable(out);
  return _cache;
}
