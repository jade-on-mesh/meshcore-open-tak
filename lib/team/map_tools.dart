// MeshCore Open TAK - the map's Tools grid, modelled on ATAK's tool menu.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart' show LatLngBounds;
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../screens/map_packs_screen.dart';
import '../vox/image_send_sheet.dart';
import '../vox/voice_service.dart';
import 'team_casevac_ui.dart';
import 'team_draw.dart';
import 'team_forms.dart';
import 'team_coords.dart';
import 'team_gpx.dart';
import 'team_map.dart' show teamAgo, teamRoleIconFor;
import 'team_packages.dart';
import 'team_screen.dart';
import 'team_service.dart';
import 'team_wire.dart';

class _Tool {
  final IconData icon;
  final String label;
  final Color? color;
  final bool needsTeam;
  final void Function(BuildContext context) run;
  const _Tool(
    this.icon,
    this.label,
    this.run, {
    this.color,
    this.needsTeam = false,
  });
}

/// Where a tool acts: your position, else the centre of the map.
(double, double, bool) _here(TeamService team, LatLng mapCenter) {
  final f = team.fix;
  if (f != null) return (f.lat, f.lon, true);
  return (mapCenter.latitude, mapCenter.longitude, false);
}

void _openTactical(BuildContext context, int tab) => Navigator.push(
  context,
  MaterialPageRoute(
    builder: (_) => TeamScreen(initialTab: tab, fromMap: true),
  ),
);

/// Opens the Tools grid. [onChat] toggles the chat pane; [onDraw] starts a
/// drawing tool on the map; [mapCenter] is used for tools that place
/// something when there is no position fix.
Future<void> showMapTools(
  BuildContext context, {
  required VoidCallback onChat,
  required void Function(ShapeKind kind, bool geofence) onDraw,
  required VoidCallback onMeasure,
  required ValueChanged<LatLng> onGoTo,
  required LatLng mapCenter,
  LatLngBounds? mapArea,
}) {
  final team = context.read<TeamService>();
  final tools = <_Tool>[
    _Tool(Icons.forum_outlined, 'Chat', (_) => onChat()),
    _Tool(
      Icons.campaign_outlined,
      'Alert',
      (c) => _showAlertPicker(c, team),
      color: Colors.red,
      needsTeam: true,
    ),
    _Tool(Icons.edit_note, 'Report', (c) {
      final (lat, lon, _) = _here(team, mapCenter);
      showGeneralReportForm(c, lat: lat, lon: lon);
    }, needsTeam: true),
    _Tool(
      Icons.local_hospital_outlined,
      'CASEVAC',
      (c) {
        final (lat, lon, _) = _here(team, mapCenter);
        showCasevacForm(c, lat: lat, lon: lon);
      },
      color: casevacRed,
      needsTeam: true,
    ),
    _Tool(Icons.add_location_alt_outlined, 'Drop Pin', (c) {
      final (lat, lon, _) = _here(team, mapCenter);
      showTeamPinEditor(c, lat: lat, lon: lon);
    }, needsTeam: true),
    _Tool(
      Icons.add_a_photo_outlined,
      'Quick Pic',
      (c) => _quickPic(c, team, mapCenter),
      needsTeam: true,
    ),
    _Tool(Icons.assignment_outlined, 'SALUTE', (c) {
      final (lat, lon, _) = _here(team, mapCenter);
      showSaluteForm(c, lat: lat, lon: lon);
    }, needsTeam: true),
    _Tool(Icons.draw_outlined, 'Draw', (c) async {
      final k = await showDrawToolPicker(c);
      if (k != null) onDraw(k, false);
    }, needsTeam: true),
    _Tool(
      Icons.route,
      'Route',
      (_) => onDraw(ShapeKind.route, false),
      needsTeam: true,
    ),
    _Tool(Icons.fence, 'Geofence', (c) async {
      final k = await _pickFenceShape(c);
      if (k != null) onDraw(k, true);
    }, needsTeam: true),
    _Tool(Icons.straighten, 'Range & Bearing', (_) => onMeasure()),
    _Tool(Icons.my_location, 'Go To', (c) => _showGoTo(c, team, onGoTo)),
    _Tool(Icons.timeline, 'Track History', (c) => _showTrackHistory(c)),
    _Tool(
      Icons.download_for_offline_outlined,
      'Offline Maps',
      (c) => Navigator.of(c).push(
        MaterialPageRoute<void>(builder: (_) => MapPacksScreen(area: mapArea)),
      ),
    ),
    _Tool(
      Icons.track_changes,
      'Bloodhound',
      (c) => _showHoundPicker(c, team, mapCenter),
      color: const Color(0xFFFF6D00),
      needsTeam: true,
    ),
    _Tool(Icons.groups_outlined, 'Team', (c) => _openTactical(c, 0)),
    _Tool(Icons.place_outlined, 'Pins', (c) => _openTactical(c, 2)),
    _Tool(Icons.assignment_turned_in_outlined, 'Reports', (c) {
      _openTactical(c, 3);
    }),
    _Tool(Icons.visibility_outlined, 'Watch', (c) => _openTactical(c, 1)),
    _Tool(Icons.hub_outlined, 'TAK Server', (c) => _openTactical(c, 4)),
    _Tool(
      Icons.emoji_people_outlined,
      'Status',
      (c) => _showStatusPicker(c, team),
      needsTeam: true,
    ),
    _Tool(
      Icons.inventory_2_outlined,
      'Data Package',
      (c) => showDataPackageSheet(c),
    ),
    _Tool(Icons.ios_share, 'Export GPX', (c) async {
      final messenger = ScaffoldMessenger.of(c);
      try {
        if (!await shareTeamGpx(team)) {
          messenger.showSnackBar(
            const SnackBar(content: Text('Nothing on the team map to export')),
          );
        }
      } catch (e) {
        messenger.showSnackBar(SnackBar(content: Text('Export failed: $e')));
      }
    }),
  ];

  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (sheet) {
      final scheme = Theme.of(sheet).colorScheme;
      return SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Text('Tools', style: Theme.of(sheet).textTheme.titleMedium),
                    const Spacer(),
                    if (!team.enabled)
                      Text(
                        'Team mode off',
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                GridView.extent(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  maxCrossAxisExtent: 96,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  children: [
                    for (final t in tools)
                      _ToolTile(
                        tool: t,
                        dimmed: t.needsTeam && !team.enabled,
                        onTap: () {
                          Navigator.pop(sheet);
                          if (t.needsTeam && !team.enabled) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Turn on team mode first (Setup tab).',
                                ),
                              ),
                            );
                            _openTactical(context, 4);
                            return;
                          }
                          t.run(context);
                        },
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

Future<ShapeKind?> _pickFenceShape(BuildContext context) =>
    showModalBottomSheet<ShapeKind>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              title: Text('Geofence'),
              subtitle: Text(
                'Alerts every teammate when anyone enters or leaves the area.',
              ),
            ),
            for (final k in [
              ShapeKind.circle,
              ShapeKind.polygon,
              ShapeKind.rectangle,
            ])
              ListTile(
                leading: Icon(shapeKindIcon(k)),
                title: Text(k.label),
                onTap: () => Navigator.pop(c, k),
              ),
          ],
        ),
      ),
    );

class _ToolTile extends StatelessWidget {
  final _Tool tool;
  final bool dimmed;
  final VoidCallback onTap;
  const _ToolTile({
    required this.tool,
    required this.dimmed,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = dimmed
        ? scheme.onSurface.withValues(alpha: 0.38)
        : (tool.color ?? scheme.onSurface);
    return Material(
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(tool.icon, size: 30, color: fg),
              const SizedBox(height: 6),
              Text(
                tool.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: fg),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ alert

Future<void> _showAlertPicker(BuildContext context, TeamService team) async {
  if (team.activeOwnAlert != null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Your alert is already active. Tap the red banner to cancel it.',
        ),
      ),
    );
    return;
  }
  final type = await showModalBottomSheet<TeamAlertType>(
    context: context,
    showDragHandle: true,
    builder: (c) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const ListTile(
            title: Text('Raise an alert'),
            subtitle: Text('Every teammate gets a full-screen alarm.'),
          ),
          for (final (t, icon, sub) in [
            (TeamAlertType.sos, Icons.sos, 'Emergency, I need help now'),
            (
              TeamAlertType.inContact,
              Icons.warning_amber,
              'Under threat, in contact',
            ),
            (
              TeamAlertType.ringTheBell,
              Icons.notifications_active,
              'Everyone check in',
            ),
          ])
            ListTile(
              leading: Icon(icon, color: Colors.red),
              title: Text(t.label),
              subtitle: Text(sub),
              onTap: () => Navigator.pop(c, t),
            ),
          ListTile(
            leading: const Icon(Icons.close),
            title: const Text('Cancel'),
            onTap: () => Navigator.pop(c),
          ),
        ],
      ),
    ),
  );
  if (type == null || !context.mounted) return;
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text('Send ${type.label}?'),
      content: const Text('Your team will be alerted with your position.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(c, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Colors.red),
          onPressed: () => Navigator.pop(c, true),
          child: const Text('Send alert'),
        ),
      ],
    ),
  );
  if (ok == true) await team.raiseAlert(type);
}

// -------------------------------------------------------------- quick pic

Future<void> _quickPic(
  BuildContext context,
  TeamService team,
  LatLng mapCenter,
) async {
  final voice = context.read<VoxVoiceService>();
  final (lat, lon, mine) = _here(team, mapCenter);
  final messenger = ScaffoldMessenger.of(context);
  await showVoxImagePicker(
    context,
    recipientLabel: mine ? 'a pin at your position' : 'a pin at map centre',
    sendLabel: 'Drop pin',
    onSend: (image) async {
      final env = voice.registerClip(voice.imageClip(image));
      final now = DateTime.now();
      await team.putMarker(
        kind: MarkerKind.point,
        lat: lat,
        lon: lon,
        label:
            'Quick Pic ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}',
        attachment: TeamAttachment(
          env.mode.wireId,
          env.sessionId,
          env.totalPackets,
          env.durationSeconds,
        ),
      );
      messenger.showSnackBar(
        const SnackBar(content: Text('Quick Pic pin shared with your team')),
      );
    },
  );
}

// ------------------------------------------------------------- bloodhound

Future<void> _showHoundPicker(
  BuildContext context,
  TeamService team,
  LatLng mapCenter,
) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (c) {
    final members = team.members;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(c).size.height * 0.6,
        ),
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(
              title: Text('Bloodhound'),
              subtitle: Text('Live range and bearing to a target.'),
            ),
            for (final m in members)
              ListTile(
                leading: CircleAvatar(
                  backgroundColor: Color(m.position.color.argb),
                  child: Icon(
                    teamRoleIconFor(team, m.position.roleId),
                    color: Colors.white,
                  ),
                ),
                title: Text(m.callsign),
                subtitle: Text(team.roleName(m.position.roleId)),
                onTap: () {
                  team.houndMember(m.key4);
                  Navigator.pop(c);
                },
              ),
            if (members.isEmpty)
              const ListTile(
                enabled: false,
                title: Text('No teammates heard yet'),
              ),
            ListTile(
              leading: const Icon(Icons.center_focus_strong),
              title: const Text('Centre of the map'),
              onTap: () {
                team.houndPoint(
                  mapCenter.latitude,
                  mapCenter.longitude,
                  'Map point',
                );
                Navigator.pop(c);
              },
            ),
          ],
        ),
      ),
    );
  },
);

// ----------------------------------------------------------------- status

Future<void> _showStatusPicker(BuildContext context, TeamService team) =>
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Your status', style: Theme.of(c).textTheme.titleMedium),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final st in TeamStatus.values.skip(1))
                    ChoiceChip(
                      label: Text(st.label),
                      selected: team.status == st,
                      onSelected: (sel) {
                        unawaited(team.setStatus(sel ? st : TeamStatus.none));
                        Navigator.pop(c);
                      },
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

// ------------------------------------------------------------------ Go To

Future<void> _showGoTo(
  BuildContext context,
  TeamService team,
  ValueChanged<LatLng> onGoTo,
) async {
  final p = await showDialog<LatLng>(
    context: context,
    builder: (_) => _GoToDialog(team: team),
  );
  if (p != null) onGoTo(p);
}

class _GoToDialog extends StatefulWidget {
  final TeamService team;
  const _GoToDialog({required this.team});
  @override
  State<_GoToDialog> createState() => _GoToDialogState();
}

class _GoToDialogState extends State<_GoToDialog> {
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  (double, double)? get _parsed => parseTeamCoord(_text.text);

  @override
  Widget build(BuildContext context) {
    final p = _parsed;
    final fix = widget.team.fix;
    return AlertDialog(
      title: const Text('Go to coordinates'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _text,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: '10T DT 48591 73682  or  47.6062, -122.3321',
            ),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) {
              if (p != null) Navigator.pop(context, LatLng(p.$1, p.$2));
            },
          ),
          const SizedBox(height: 8),
          Text(
            _text.text.trim().isEmpty
                ? 'MGRS, decimal degrees or DMS.'
                : p == null
                ? 'Not a position I can read yet.'
                : [
                    for (final f in CoordFormat.values)
                      teamFormatCoord(p.$1, p.$2, f),
                    if (fix != null)
                      teamRangeBearing(
                        teamDistanceMeters(fix.lat, fix.lon, p.$1, p.$2),
                        teamBearingDeg(fix.lat, fix.lon, p.$1, p.$2),
                      ),
                  ].join('\n'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: p == null
              ? null
              : () => Navigator.pop(context, LatLng(p.$1, p.$2)),
          child: const Text('Go'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------- track history

String _duration(Duration d) => d.inHours > 0
    ? '${d.inHours} h ${d.inMinutes % 60} min'
    : '${d.inMinutes} min';

Future<void> _showTrackHistory(
  BuildContext context,
) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (c) {
    final team = c.watch<TeamService>();
    final mine = team.myTrack;
    final trails = [
      for (final m in team.members)
        if (m.trail.length > 1) m,
    ];
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(c).size.height * 0.75,
        ),
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(title: Text('Track history')),
            SwitchListTile(
              title: const Text('Record my track'),
              subtitle: const Text(
                'Saved on this phone only; nothing extra is sent.',
              ),
              value: team.recordTrack,
              onChanged: (v) => team.setRecordTrack(v),
            ),
            SwitchListTile(
              title: const Text('Show tracks on the map'),
              value: team.showTracks,
              onChanged: (v) => team.setShowTracks(v),
            ),
            const Divider(),
            ListTile(
              leading: Icon(
                Icons.person_pin_circle,
                color: Color(team.color.argb),
              ),
              title: const Text('Your track'),
              subtitle: Text(
                mine.length < 2
                    ? 'Nothing recorded yet'
                    : '${teamFormatLength(teamTrackLength(mine))} · '
                          '${_duration(mine.last.$3.difference(mine.first.$3))} · '
                          'since ${teamAgo(mine.first.$3)}',
              ),
              trailing: mine.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear my track',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => team.clearMyTrack(),
                    ),
            ),
            for (final m in trails)
              ListTile(
                leading: Icon(
                  Icons.person,
                  color: Color(m.position.color.argb),
                ),
                title: Text(m.callsign),
                subtitle: Text(
                  '${teamFormatLength(teamTrackLength(m.trail))} · '
                  '${m.trail.length} points · heard ${teamAgo(m.heard)}',
                ),
                trailing: IconButton(
                  tooltip: 'Clear trail',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => team.clearMemberTrail(m.key4),
                ),
              ),
            if (trails.isEmpty)
              const ListTile(
                enabled: false,
                title: Text('No teammate trails yet'),
              ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: OutlinedButton.icon(
                icon: const Icon(Icons.ios_share),
                label: const Text('Export tracks and map as GPX'),
                onPressed: () async {
                  final messenger = ScaffoldMessenger.of(c);
                  if (!await shareTeamGpx(team)) {
                    messenger.showSnackBar(
                      const SnackBar(content: Text('Nothing to export')),
                    );
                  }
                },
              ),
            ),
          ],
        ),
      ),
    );
  },
);
