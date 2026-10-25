// MeshCore Open TAK - the drone detector's screen (drone_detector.dart):
// listen on/off, the drones heard, and where to post them. Opened from the
// Watch tab's Drones chip.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart' show LatLng;
import 'package:provider/provider.dart';

import '../connector/meshcore_connector.dart';
import '../helpers/snack_bar_builder.dart';
import '../l10n/l10n.dart';
import '../screens/map_screen.dart';
import 'drone_detector.dart';
import 'remote_id.dart';
import 'watch_feed.dart';

class DroneDetectorScreen extends StatelessWidget {
  const DroneDetectorScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final d = context.watch<DroneDetectorService>();
    final connector = context.watch<MeshCoreConnector>();
    final scheme = Theme.of(context).colorScheme;
    final now = DateTime.now();
    final tracks = d.tracks;
    final usable = [
      for (final c in connector.channels)
        if (c.name.isNotEmpty &&
            !c.isPublicChannel &&
            c.name.toLowerCase() != 'public')
          c,
    ];
    String status;
    if (!d.listening) {
      status = l10n.drones_listenHelp;
    } else if (d.scanning) {
      status = l10n.drones_scanning;
    } else if (connector.state == MeshCoreConnectionState.scanning) {
      status = l10n.drones_paused;
    } else {
      status = d.error ?? l10n.drones_paused;
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.drones_title),
        actions: [
          if (tracks.isNotEmpty)
            IconButton(
              tooltip: l10n.drones_clear,
              icon: const Icon(Icons.clear_all),
              onPressed: d.clear,
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            secondary: Icon(
              d.scanning ? Icons.radar : Icons.radar_outlined,
              color: d.scanning ? scheme.primary : null,
            ),
            title: Text(l10n.drones_listen),
            subtitle: Text(status),
            value: d.listening,
            onChanged: (v) => unawaited(d.setListening(v)),
          ),
          const Divider(),
          if (tracks.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text(l10n.drones_none, textAlign: TextAlign.center),
            ),
          for (final t in tracks) _TrackCard(track: t, now: now),
          const Divider(),
          DropdownButtonFormField<String?>(
            key: ValueKey(d.channelName),
            initialValue: d.channelName,
            decoration: InputDecoration(labelText: l10n.drones_alertChannel),
            items: [
              DropdownMenuItem<String?>(
                value: null,
                child: Text(l10n.drones_noChannel),
              ),
              for (final c in usable)
                DropdownMenuItem<String?>(value: c.name, child: Text(c.name)),
              // The saved channel, when this radio doesn't have it (the
              // default before it's joined, or one deleted since).
              if (d.channelName != null &&
                  !usable.any((c) => c.name == d.channelName))
                DropdownMenuItem<String?>(
                  value: d.channelName,
                  child: Text(l10n.drones_notJoined(d.channelName!)),
                ),
            ],
            onChanged: d.setChannel,
          ),
          if (d.needsJoin)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(Icons.tag),
                label: Text(
                  l10n.drones_joinDefault(DroneDetectorService.defaultChannel),
                ),
                onPressed: () async {
                  final ok = await d.joinDefaultChannel();
                  if (!context.mounted) return;
                  showDismissibleSnackBar(
                    context,
                    content: Text(
                      ok
                          ? l10n.channels_channelAdded(
                              DroneDetectorService.defaultChannel,
                            )
                          : l10n.channels_noFreeSlots,
                    ),
                  );
                },
              ),
            ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(l10n.drones_share),
            subtitle: Text(d.shareError ?? l10n.drones_shareHelp),
            value: d.share,
            onChanged: d.channelName == null ? null : d.setShare,
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(l10n.drones_sound),
            value: d.sound,
            onChanged: d.setSound,
          ),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              l10n.drones_counts(d.heard, d.posted),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _TrackCard extends StatelessWidget {
  const _TrackCard({required this.track, required this.now});

  final RemoteIdTrack track;
  final DateTime now;

  String _ago(BuildContext context, DateTime t) {
    final l10n = context.l10n;
    final s = now.difference(t).inSeconds;
    return s < 60
        ? l10n.drones_secondsAgo(s < 0 ? 0 : s)
        : l10n.drones_minutesAgo(s ~/ 60);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final t = track;
    final stale = t.isStale(now);
    final where = t.hasPosition
        ? '${t.lat!.toStringAsFixed(5)}, ${t.lon!.toStringAsFixed(5)}'
        : l10n.drones_noPosition;
    final facts = [
      if (t.heightAglM != 0) 'h${t.heightAglM}m',
      remoteIdSpeed(t.speedCms),
      if (t.speedCms >= 50) '${t.headingDeg}°',
      '${t.rssi} dBm',
      _ago(context, t.lastSeen),
    ].join(' · ');
    return Card(
      child: ExpansionTile(
        leading: Icon(
          Icons.flight,
          color: stale ? Theme.of(context).disabledColor : Colors.orange,
        ),
        title: Text(t.uasId, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          stale ? '$facts · ${l10n.drones_stale}' : '$where\n$facts',
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _row(l10n.drones_type, remoteIdUaTypeName(t.uaType)),
          if (t.description != null)
            _row(l10n.drones_description, t.description!),
          if (t.heightAglM != 0) _row(l10n.drones_height, '${t.heightAglM} m'),
          if (t.altGeoM != 0) _row(l10n.drones_altitude, '${t.altGeoM} m'),
          _row(l10n.drones_speed, remoteIdSpeed(t.speedCms)),
          if (t.speedCms >= 50) _row(l10n.drones_heading, '${t.headingDeg}°'),
          if (t.operatorId != null) _row(l10n.drones_operatorId, t.operatorId!),
          if (t.hasOperator)
            _row(
              l10n.drones_operator,
              '${t.opLat!.toStringAsFixed(5)}, ${t.opLon!.toStringAsFixed(5)}',
            ),
          _row(l10n.drones_signal, '${t.rssi} dBm'),
          _row(l10n.drones_lastHeard, _ago(context, t.lastSeen)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              if (t.hasPosition)
                OutlinedButton.icon(
                  icon: const Icon(Icons.map_outlined),
                  label: Text(l10n.drones_showOnMap),
                  onPressed: () => _showOnMap(context),
                ),
              if (t.hasPosition)
                FilledButton.tonalIcon(
                  icon: const Icon(Icons.campaign_outlined),
                  label: Text(l10n.drones_post),
                  onPressed: () async {
                    final why = await context.read<DroneDetectorService>().post(
                      t,
                    );
                    if (!context.mounted) return;
                    showDismissibleSnackBar(
                      context,
                      content: Text(why ?? l10n.drones_posted),
                    );
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _row(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 110, child: Text(label)),
        Expanded(child: SelectableText(value)),
      ],
    ),
  );

  void _showOnMap(BuildContext context) {
    final t = track;
    final feed = context.read<WatchFeedService>();
    final item = feed.localItem('drone:${t.uasId}');
    if (item != null) feed.focusOnMap(item);
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => MapScreen(
            focusPosition: LatLng(t.lat!, t.lon!),
            focusZoom: 16,
            focusAlso: t.hasOperator ? LatLng(t.opLat!, t.opLon!) : null,
          ),
        ),
      ),
    );
  }
}
