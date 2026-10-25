// MeshCore Open TAK - "who got it": one of my channel messages on a map, as a
// fan of lines from me to the repeaters that re-flooded it and the teammates
// who said they heard it (documentation/message-reach.md).

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../connector/meshcore_connector.dart';
import '../helpers/path_hop_resolver.dart';
import '../l10n/l10n.dart';
import '../models/channel.dart';
import '../models/channel_message.dart';
import '../models/contact.dart';
import '../services/map_tile_cache_service.dart';
import '../widgets/path_map_scaffold.dart' show plausibleSelfPoint;
import 'team_service.dart';

/// A repeater that re-flooded the message: [hops] is how far down the flood
/// it was (1: heard me directly).
class ReachRepeater {
  final Contact? contact;
  final String label;
  final int hops;
  final LatLng? at;
  final LatLng? from; // the hop before it, for the line
  const ReachRepeater({
    required this.contact,
    required this.label,
    required this.hops,
    this.at,
    this.from,
  });
}

/// The repeaters in [m]'s echoes, nearest hop first, each once.
List<ReachRepeater> reachRepeaters(
  ChannelMessage m,
  List<Contact> contacts,
  LatLng? self,
  int hashWidth,
) {
  final variants = [
    ...m.pathVariants,
    if (m.pathVariants.isEmpty && m.pathBytes.isNotEmpty) m.pathBytes,
  ];
  final seen = <String, ReachRepeater>{};
  for (final v in variants) {
    final resolved = PathHopResolver.resolve(
      pathBytes: v,
      contacts: contacts,
      endpoint: self,
      pathHashByteWidth: hashWidth,
    );
    LatLng? prev = self;
    for (var i = 0; i < resolved.length; i++) {
      final c = resolved[i];
      final start = i * hashWidth;
      final hex = v
          .sublist(start, (start + hashWidth).clamp(0, v.length))
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join()
          .toUpperCase();
      final at = c != null && c.hasLocation && c.latitude != null
          ? LatLng(c.latitude!, c.longitude!)
          : null;
      final key = c == null ? 'hash:$hex' : c.publicKeyHex;
      final old = seen[key];
      if (old == null || i + 1 < old.hops) {
        seen[key] = ReachRepeater(
          contact: c,
          label: c?.name ?? hex,
          hops: i + 1,
          at: at,
          from: prev,
        );
      }
      prev = at ?? prev;
    }
  }
  final out = seen.values.toList()..sort((a, b) => a.hops.compareTo(b.hops));
  return out;
}

class MessageReachScreen extends StatelessWidget {
  final ChannelMessage message;
  final Channel channel;
  const MessageReachScreen({
    super.key,
    required this.message,
    required this.channel,
  });

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final connector = context.watch<MeshCoreConnector>();
    final team = context.watch<TeamService>();
    final tiles = context.read<MapTileCacheService>();
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;

    // The message as stored now (echoes keep arriving).
    var m = message;
    for (final x in connector.getChannelMessages(channel)) {
      if (x.messageId == m.messageId) m = x;
    }
    final teamFix = team.fix;
    final self =
        plausibleSelfPoint(connector) ??
        (teamFix == null ? null : LatLng(teamFix.lat, teamFix.lon));
    final repeaters = reachRepeaters(
      m,
      connector.allContacts,
      self,
      (m.pathHashWidth ?? connector.pathHashByteWidth).clamp(1, 3).toInt(),
    );
    final heard = team.enabled
        ? team.heardBy(m)
        : const <(TeamMember, DateTime)>[];
    final heardKeys = {for (final h in heard) h.$1.key4};
    final notYet = team.enabled
        ? team.members.where((x) => !heardKeys.contains(x.key4)).toList()
        : const <TeamMember>[];

    const repeaterColor = Color(0xFFFF8F00);
    final lines = <Polyline>[];
    final markers = <Marker>[];
    final pts = <LatLng>[?self];
    for (final r in repeaters) {
      final at = r.at;
      if (at == null) continue;
      pts.add(at);
      final from = r.hops == 1 ? self : r.from;
      if (from != null) {
        lines.add(
          Polyline(
            points: [from, at],
            strokeWidth: r.hops == 1 ? 4 : 2.5,
            color: repeaterColor.withValues(alpha: r.hops == 1 ? 0.95 : 0.6),
            pattern: r.hops == 1
                ? const StrokePattern.solid()
                : StrokePattern.dashed(segments: const [8, 6]),
          ),
        );
      }
      markers.add(
        Marker(
          point: at,
          width: 120,
          height: 44,
          child: _Pin(
            icon: Icons.cell_tower,
            color: repeaterColor,
            label: r.label,
          ),
        ),
      );
    }
    for (final (member, _) in heard) {
      final p = LatLng(member.position.lat, member.position.lon);
      pts.add(p);
      if (self != null) {
        lines.add(
          Polyline(
            points: [self, p],
            strokeWidth: 3,
            color: Color(member.position.color.argb),
            pattern: StrokePattern.dotted(spacingFactor: 2),
          ),
        );
      }
      markers.add(
        Marker(
          point: p,
          width: 120,
          height: 44,
          child: _Pin(
            icon: Icons.person,
            color: Color(member.position.color.argb),
            label: member.callsign,
          ),
        ),
      );
    }
    if (self != null) {
      markers.add(
        Marker(
          point: self,
          width: 28,
          height: 28,
          child: Container(
            decoration: BoxDecoration(
              color: scheme.primary,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 3),
            ),
          ),
        ),
      );
    }

    final fit = pts.length >= 2
        ? CameraFit.coordinates(
            coordinates: pts,
            padding: const EdgeInsets.all(48),
            maxZoom: 15,
          )
        : null;

    String ago(DateTime d) {
      final s = DateTime.now().difference(d);
      if (s.inMinutes < 1) return l.reach_now;
      if (s.inHours < 1) return '${s.inMinutes}m';
      return '${s.inHours}h';
    }

    return Scaffold(
      appBar: AppBar(title: Text(l.reach_title)),
      body: Column(
        children: [
          Expanded(
            flex: 3,
            child: self == null && pts.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        l.reach_noPosition,
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : FlutterMap(
                    options: MapOptions(
                      initialCenter: pts.isNotEmpty
                          ? pts.first
                          : const LatLng(20, 0),
                      initialZoom: pts.isNotEmpty ? 13 : 2,
                      initialCameraFit: fit,
                      interactionOptions: const InteractionOptions(
                        flags: ~InteractiveFlag.rotate,
                      ),
                    ),
                    children: [
                      tiles.buildTileLayer(context),
                      PolylineLayer(polylines: lines),
                      MarkerLayer(markers: markers),
                    ],
                  ),
          ),
          Expanded(
            flex: 2,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              children: [
                Text(
                  m.displayText,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: t.bodyMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  l.reach_summary(repeaters.length, heard.length),
                  style: t.titleSmall,
                ),
                if (repeaters.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(l.reach_noRepeats, style: t.bodySmall),
                  ),
                for (final r in repeaters)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.cell_tower, color: repeaterColor),
                    title: Text(r.label),
                    subtitle: Text(
                      [
                        r.hops == 1 ? l.reach_direct : l.reach_hops(r.hops),
                        if (r.at == null) l.reach_noLocation,
                      ].join(' · '),
                    ),
                  ),
                if (team.enabled) ...[
                  const Divider(),
                  Text(l.reach_teammates, style: t.titleSmall),
                  for (final (member, at) in heard)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        Icons.check_circle,
                        color: Color(member.position.color.argb),
                      ),
                      title: Text(member.callsign),
                      subtitle: Text(l.reach_heardAgo(ago(at))),
                    ),
                  for (final member in notYet)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        Icons.radio_button_unchecked,
                        color: scheme.onSurfaceVariant,
                      ),
                      title: Text(member.callsign),
                      subtitle: Text(l.reach_notYet),
                    ),
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(l.reach_teamHelp, style: t.bodySmall),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Pin extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  const _Pin({required this.icon, required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2),
          ),
          child: Icon(icon, size: 14, color: Colors.black),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white, fontSize: 10),
          ),
        ),
      ],
    );
  }
}
