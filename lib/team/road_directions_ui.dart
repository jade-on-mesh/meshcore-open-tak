// MeshCore Open TAK - road directions on the map: the sheet that starts them
// and the next-turn card (the logic is in road_directions.dart and
// TeamService).

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import 'road_directions.dart';
import 'team_service.dart';

/// Valhalla maneuver types as Material icons.
IconData roadManeuverIcon(int type) {
  switch (type) {
    case 1:
    case 2:
    case 3:
      return Icons.trip_origin;
    case 4:
    case 5:
    case 6:
      return Icons.flag;
    case 9:
    case 23:
      return Icons.turn_slight_right;
    case 10:
      return Icons.turn_right;
    case 11:
      return Icons.turn_sharp_right;
    case 12:
      return Icons.u_turn_right;
    case 13:
      return Icons.u_turn_left;
    case 14:
      return Icons.turn_sharp_left;
    case 15:
      return Icons.turn_left;
    case 16:
    case 24:
      return Icons.turn_slight_left;
    case 18:
    case 20:
      return Icons.ramp_right;
    case 19:
    case 21:
      return Icons.ramp_left;
    case 25:
    case 37:
    case 38:
      return Icons.merge;
    case 26:
    case 27:
      return Icons.roundabout_right;
    case 28:
    case 29:
      return Icons.directions_boat;
    default:
      return Icons.straight;
  }
}

String _modeLabel(BuildContext context, RoadMode m) {
  final l10n = context.l10n;
  switch (m) {
    case RoadMode.drive:
      return l10n.road_drive;
    case RoadMode.walk:
      return l10n.road_walk;
    case RoadMode.bike:
      return l10n.road_bike;
  }
}

IconData _modeIcon(RoadMode m) => switch (m) {
  RoadMode.drive => Icons.directions_car,
  RoadMode.walk => Icons.directions_walk,
  RoadMode.bike => Icons.directions_bike,
};

/// Picks how to travel (and the server) and starts directions.
Future<void> showRoadDirectionsSheet(BuildContext context, TeamService team) {
  final server = TextEditingController(text: team.routingServer);
  final language = Localizations.localeOf(context).toLanguageTag();
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (c) {
      final l10n = c.l10n;
      final target = team.bloodhound;
      return SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            16,
            0,
            16,
            16 + MediaQuery.of(c).viewInsets.bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                target == null
                    ? l10n.road_directions
                    : l10n.road_directionsTo(target.label),
                style: Theme.of(c).textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Text(l10n.road_help, style: Theme.of(c).textTheme.bodySmall),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final m in RoadMode.values)
                    FilledButton.tonalIcon(
                      onPressed: () async {
                        Navigator.pop(c);
                        if (server.text.trim() != team.routingServer) {
                          await team.setRoutingServer(server.text);
                        }
                        await team.startDirections(m, language: language);
                      },
                      icon: Icon(_modeIcon(m)),
                      label: Text(_modeLabel(c, m)),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: server,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: l10n.road_server,
                  hintText: defaultRoutingServer,
                  helperText: l10n.road_serverHelp,
                  helperMaxLines: 3,
                ),
              ),
            ],
          ),
        ),
      );
    },
  ).whenComplete(server.dispose);
}

/// The next turn, what is left, and the route's controls.
class RoadDirectionsCard extends StatelessWidget {
  final TeamService team;
  const RoadDirectionsCard({super.key, required this.team});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final mode = team.roadMode;
    if (mode == null) return const SizedBox.shrink();
    final route = team.roadRoute;
    final pr = team.roadProgress;
    final error = team.roadError;

    Widget body;
    if (route == null) {
      body = Row(
        children: [
          if (team.roadBusy)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            Icon(Icons.error_outline, color: theme.colorScheme.error),
          const SizedBox(width: 10),
          Expanded(child: Text(team.roadBusy ? l10n.road_finding : (error ?? ''))),
          if (!team.roadBusy)
            TextButton(
              onPressed: () => team.startDirections(mode),
              child: Text(l10n.road_retry),
            ),
        ],
      );
    } else if (pr != null && pr.arrived) {
      body = Row(
        children: [
          const Icon(Icons.flag, size: 32),
          const SizedBox(width: 10),
          Expanded(
            child: Text(l10n.road_arrived, style: theme.textTheme.titleMedium),
          ),
        ],
      );
    } else {
      final m = pr != null && pr.next >= 0 && pr.next < route.maneuvers.length
          ? route.maneuvers[pr.next]
          : (route.maneuvers.isEmpty ? null : route.maneuvers.first);
      final remaining = pr?.remainingM ?? route.lengthM;
      final time = route.lengthM > 0
          ? route.timeS * remaining / route.lengthM
          : route.timeS;
      body = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(roadManeuverIcon(m?.type ?? 8), size: 36),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (pr != null)
                  Text(
                    l10n.road_then(roadDistance(pr.toNextM)),
                    style: theme.textTheme.titleMedium,
                  ),
                if (m != null) Text(m.instruction),
                Text(
                  l10n.road_left(roadDistance(remaining), roadDuration(time)),
                  style: theme.textTheme.bodySmall,
                ),
                if (error != null)
                  Text(
                    error,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
              ],
            ),
          ),
          if (team.roadBusy)
            const Padding(
              padding: EdgeInsets.all(4),
              child: SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
        ],
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 2),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            body,
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(_modeIcon(mode), size: 16),
                const SizedBox(width: 4),
                Text(_modeLabel(context, mode), style: theme.textTheme.bodySmall),
                const SizedBox(width: 8),
                if (route != null && team.enabled)
                  TextButton.icon(
                    onPressed: () async {
                      final messenger = ScaffoldMessenger.of(context);
                      final text = l10n.road_shared;
                      await team.shareRoad();
                      messenger.showSnackBar(SnackBar(content: Text(text)));
                    },
                    icon: const Icon(Icons.share, size: 18),
                    label: Text(l10n.road_share),
                  ),
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: l10n.road_stop,
                  onPressed: team.stopDirections,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
