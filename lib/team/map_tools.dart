// MeshCore Open TAK - the map's Tools grid, modelled on ATAK's tool menu.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../vox/image_send_sheet.dart';
import '../vox/voice_service.dart';
import 'team_forms.dart';
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
  MaterialPageRoute(builder: (_) => TeamScreen(initialTab: tab)),
);

/// Opens the Tools grid. [onChat] toggles the chat pane; [mapCenter] is
/// used for tools that place something when there is no position fix.
Future<void> showMapTools(
  BuildContext context, {
  required VoidCallback onChat,
  required LatLng mapCenter,
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
  ];

  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    useSafeArea: true,
    builder: (sheet) {
      final scheme = Theme.of(sheet).colorScheme;
      return SafeArea(
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
      );
    },
  );
}

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
        content: Text('Your alert is already active. Tap the red banner to cancel it.'),
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
            (TeamAlertType.inContact, Icons.warning_amber, 'Under threat, in contact'),
            (TeamAlertType.ringTheBell, Icons.notifications_active, 'Everyone check in'),
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
                  child: const Icon(Icons.person, color: Colors.white),
                ),
                title: Text(m.callsign),
                subtitle: Text(m.position.role.label),
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
