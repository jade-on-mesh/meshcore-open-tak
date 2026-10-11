// MeshCore Open TAK - team screen: roster, pins, SALUTE reports, setup and
// TAK Server settings.

import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'tak/tak_service.dart';
import 'team_forms.dart';
import 'team_map.dart';
import 'team_service.dart';
import 'team_wire.dart';

class TeamScreen extends StatelessWidget {
  const TeamScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final team = context.watch<TeamService>();
    return DefaultTabController(
      length: 4,
      initialIndex: team.enabled ? 0 : 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Team'),
          bottom: const TabBar(
            isScrollable: true,
            tabs: [
              Tab(text: 'Roster'),
              Tab(text: 'Pins'),
              Tab(text: 'Reports'),
              Tab(text: 'Setup'),
            ],
          ),
        ),
        body: const TabBarView(
          children: [_RosterTab(), _PinsTab(), _ReportsTab(), _SetupTab()],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ roster

class _RosterTab extends StatelessWidget {
  const _RosterTab();

  @override
  Widget build(BuildContext context) {
    final team = context.watch<TeamService>();
    final tak = context.watch<TakService>();
    final fix = team.fix;
    if (!team.enabled) {
      return const _Empty('Team mode is off. Turn it on in Setup.');
    }
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        if (team.inactiveReason != null)
          Card(
            color: Theme.of(context).colorScheme.errorContainer,
            child: ListTile(
              leading: const Icon(Icons.info_outline),
              title: Text(team.inactiveReason!),
            ),
          ),
        Card(
          child: Column(
            children: [
              ListTile(
                leading: CircleAvatar(
                  backgroundColor: Color(team.color.argb),
                  child: Icon(teamRoleIcon(team.role), color: Colors.black),
                ),
                title: Text('${team.callsign} (you)'),
                subtitle: Text(
                  [
                    team.role.label,
                    if (fix == null)
                      'no position'
                    else
                      fix.source == TeamFixSource.phone
                          ? 'phone GPS ±${fix.accuracy.round()} m'
                          : 'radio GPS',
                    if (team.lastBeacon != null)
                      'sent ${teamAgo(team.lastBeacon!)}',
                    if (team.gpsProblem != null) team.gpsProblem!,
                  ].join(' · '),
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.send),
                  tooltip: 'Send my position now',
                  onPressed: team.active
                      ? () => unawaited(team.sendPosition())
                      : null,
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final s in TeamStatus.values.skip(1))
                      ChoiceChip(
                        label: Text(s.label),
                        selected: team.status == s,
                        onSelected: (sel) => unawaited(
                          team.setStatus(sel ? s : TeamStatus.none),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        for (final a in team.activeAlerts)
          Card(
            color: Colors.red.shade800,
            child: ListTile(
              leading: const Icon(Icons.sos, color: Colors.white),
              title: Text(
                '${a.type.label}: ${a.callsign}',
                style: const TextStyle(color: Colors.white),
              ),
              subtitle: Text(
                a.note,
                style: const TextStyle(color: Colors.white70),
              ),
              onTap: a.lat == null
                  ? null
                  : () {
                      team.houndPoint(
                        a.lat!,
                        a.lon!,
                        '${a.type.label} ${a.callsign}',
                      );
                      Navigator.pop(context);
                    },
            ),
          ),
        if (team.members.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'No teammates heard yet. Everyone on the team needs MeshCore Open TAK with '
              'team mode on, using the same team channel.',
              textAlign: TextAlign.center,
            ),
          ),
        for (final m in team.members)
          ListTile(
            leading: CircleAvatar(
              backgroundColor: Color(
                m.position.color.argb,
              ).withValues(alpha: m.freshness == TeamFreshness.live ? 1 : 0.4),
              child: Icon(teamRoleIcon(m.position.role), color: Colors.black),
            ),
            title: Text(
              '${m.callsign}${m.position.relayed ? ' (TAK)' : ''}'
              '${m.position.sosActive ? '  · SOS' : ''}',
            ),
            subtitle: Text(
              [
                m.position.role.label,
                if (m.position.status != TeamStatus.none)
                  m.position.status.label,
                teamAgo(m.heard),
                if (fix != null)
                  teamRangeBearing(
                    teamDistanceMeters(
                      fix.lat,
                      fix.lon,
                      m.position.lat,
                      m.position.lon,
                    ),
                    teamBearingDeg(
                      fix.lat,
                      fix.lon,
                      m.position.lat,
                      m.position.lon,
                    ),
                  ),
                if (m.position.batteryPct != null)
                  '🔋${m.position.batteryPct}%',
              ].join(' · '),
            ),
            onTap: () => showTeamMemberSheet(context, m.key4),
          ),
        if (tak.entities.where((e) => e.event.isUnit).isNotEmpty) ...[
          const Divider(),
          const ListTile(title: Text('From TAK')),
          for (final e in tak.entities.where((e) => e.event.isUnit))
            ListTile(
              leading: const Icon(Icons.public),
              title: Text(e.event.callsign ?? e.event.uid),
              subtitle: Text(
                '${e.event.groupRole ?? e.event.type} · ${teamAgo(e.event.time)}',
              ),
              onTap: () => showTakEntitySheet(context, e),
            ),
        ],
      ],
    );
  }
}

class _Empty extends StatelessWidget {
  final String text;
  const _Empty(this.text);
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Text(text, textAlign: TextAlign.center),
    ),
  );
}

// -------------------------------------------------------------------- pins

class _PinsTab extends StatelessWidget {
  const _PinsTab();

  @override
  Widget build(BuildContext context) {
    final team = context.watch<TeamService>();
    final fix = team.fix;
    return Scaffold(
      body: team.markers.isEmpty
          ? const _Empty('No pins yet. Long-press the map to drop one.')
          : ListView(
              children: [
                for (final m in team.markers)
                  ListTile(
                    leading: Icon(
                      markerKindIcon(m.kind),
                      color: markerKindColor(m.kind),
                    ),
                    title: Text(m.label.isEmpty ? m.kind.label : m.label),
                    subtitle: Text(
                      [
                        m.kind.label,
                        teamAgo(m.time),
                        if (m.attachment != null) 'attachment',
                        if (fix != null)
                          teamRangeBearing(
                            teamDistanceMeters(fix.lat, fix.lon, m.lat, m.lon),
                            teamBearingDeg(fix.lat, fix.lon, m.lat, m.lon),
                          ),
                      ].join(' · '),
                    ),
                    onTap: () => showTeamPinSheet(context, m),
                  ),
              ],
            ),
      floatingActionButton: team.active
          ? FloatingActionButton.extended(
              icon: const Icon(Icons.add_location_alt),
              label: const Text('Pin at my position'),
              onPressed: fix == null
                  ? null
                  : () =>
                        showTeamPinEditor(context, lat: fix.lat, lon: fix.lon),
            )
          : null,
    );
  }
}

// ----------------------------------------------------------------- reports

class _ReportsTab extends StatelessWidget {
  const _ReportsTab();

  @override
  Widget build(BuildContext context) {
    final team = context.watch<TeamService>();
    final fix = team.fix;
    return Scaffold(
      body: team.reports.isEmpty
          ? const _Empty(
              'No SALUTE reports yet. Long-press the map where you saw it, or '
              'file one at your position.',
            )
          : ListView(
              padding: const EdgeInsets.all(8),
              children: [
                for (final r in team.reports)
                  Card(
                    child: InkWell(
                      onTap: () => showTeamReportSheet(context, r),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: TeamReportCard(report: r),
                      ),
                    ),
                  ),
              ],
            ),
      floatingActionButton: team.active
          ? FloatingActionButton.extended(
              icon: const Icon(Icons.report_outlined),
              label: const Text('SALUTE at my position'),
              onPressed: fix == null
                  ? null
                  : () => showSaluteForm(context, lat: fix.lat, lon: fix.lon),
            )
          : null,
    );
  }
}

// ------------------------------------------------------------------- setup

class _SetupTab extends StatefulWidget {
  const _SetupTab();
  @override
  State<_SetupTab> createState() => _SetupTabState();
}

class _SetupTabState extends State<_SetupTab> {
  late final TextEditingController _callsign = TextEditingController(
    text: context.read<TeamService>().callsignSetting,
  );

  @override
  void dispose() {
    _callsign.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final team = context.watch<TeamService>();
    final channels = team.candidateChannels;
    final current = team.teamChannel;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        SwitchListTile(
          title: const Text('Team mode'),
          subtitle: const Text(
            'Share your position, pins, reports and alerts on a private team '
            'channel.',
          ),
          value: team.enabled,
          onChanged: (v) => unawaited(team.configure(enabled: v)),
        ),
        ListTile(
          title: const Text('Team channel'),
          subtitle: channels.isEmpty
              ? const Text(
                  'Create a private channel first (Channels → add). Everyone on '
                  'the team adds the same one.',
                )
              : null,
          trailing: channels.isEmpty
              ? null
              : DropdownButton<int>(
                  value: current?.index,
                  hint: const Text('Choose'),
                  items: [
                    for (final c in channels)
                      DropdownMenuItem(value: c.index, child: Text(c.name)),
                  ],
                  onChanged: (i) {
                    final c = channels.firstWhere((c) => c.index == i);
                    unawaited(team.configure(channel: c));
                  },
                ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextField(
            controller: _callsign,
            maxLength: teamMaxCallsignBytes,
            decoration: InputDecoration(
              labelText: 'Callsign',
              hintText: team.callsign,
            ),
            onSubmitted: (v) => unawaited(team.configure(callsign: v)),
            onTapOutside: (_) {
              if (_callsign.text.trim() != team.callsignSetting) {
                unawaited(team.configure(callsign: _callsign.text));
              }
            },
          ),
        ),
        ListTile(
          title: const Text('Role'),
          trailing: DropdownButton<TeamRole>(
            value: team.role,
            items: [
              for (final r in TeamRole.values)
                DropdownMenuItem(
                  value: r,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(teamRoleIcon(r), size: 18),
                      const SizedBox(width: 6),
                      Text(r.label),
                    ],
                  ),
                ),
            ],
            onChanged: (r) => unawaited(team.configure(role: r)),
          ),
        ),
        ListTile(
          title: const Text('Team colour'),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final c in TeamColor.values)
                  Tooltip(
                    message: c.label,
                    child: InkWell(
                      onTap: () => unawaited(team.configure(color: c)),
                      child: Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                          color: Color(c.argb),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: team.color == c
                                ? Theme.of(context).colorScheme.primary
                                : Colors.black26,
                            width: team.color == c ? 3 : 1,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        SwitchListTile(
          title: const Text('Share my position'),
          subtitle: Text(
            team.gpsProblem ??
                'Phone GPS (radio GPS if the phone has no fix). Sent about '
                    'every 90 s while moving, every 10 min when still, and at '
                    'once on a sharp turn.',
          ),
          value: team.sharePosition,
          onChanged: (v) => unawaited(team.configure(sharePosition: v)),
        ),
        ListTile(
          leading: const Icon(Icons.replay),
          title: const Text('Resend my pins'),
          subtitle: const Text(
            'For teammates who joined after you dropped them.',
          ),
          onTap: team.active
              ? () async {
                  final n = await team.resendMyMarkers();
                  if (context.mounted) {
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(SnackBar(content: Text('Resent $n pins')));
                  }
                }
              : null,
        ),
        const Divider(height: 32),
        const _TakSettings(),
      ],
    );
  }
}

class _TakSettings extends StatefulWidget {
  const _TakSettings();
  @override
  State<_TakSettings> createState() => _TakSettingsState();
}

class _TakSettingsState extends State<_TakSettings> {
  late TakSettings _s = context.read<TakService>().settings;
  late final _host = TextEditingController(text: _s.host);
  late final _port = TextEditingController(text: '${_s.port}');
  late final _clientPw = TextEditingController(text: _s.clientPassword);
  late final _trustPw = TextEditingController(text: _s.trustPassword);

  @override
  void dispose() {
    for (final c in [_host, _port, _clientPw, _trustPw]) {
      c.dispose();
    }
    super.dispose();
  }

  void _snack(String s) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

  Future<void> _apply(TakSettings s) async {
    setState(() => _s = s);
    await context.read<TakService>().update(s);
  }

  Future<void> _importPackage() async {
    final f = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'TAK data package', extensions: ['zip']),
      ],
    );
    if (f == null || !mounted) return;
    try {
      final what = await context.read<TakService>().importDataPackage(
        await f.readAsBytes(),
      );
      if (!mounted) return;
      final s = context.read<TakService>().settings;
      setState(() {
        _s = s;
        _host.text = s.host;
        _port.text = '${s.port}';
        _clientPw.text = s.clientPassword;
        _trustPw.text = s.trustPassword;
      });
      _snack('Imported: $what');
    } catch (e) {
      _snack('Couldn\'t import: $e');
    }
  }

  Future<void> _pickCert({required bool trust}) async {
    final f = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'PKCS#12 certificate', extensions: ['p12', 'pfx']),
      ],
    );
    if (f == null || !mounted) return;
    final path = await context.read<TakService>().saveCertificate(
      f.name,
      await f.readAsBytes(),
    );
    await _apply(
      trust
          ? _s.copyWith(trustP12Path: path)
          : _s.copyWith(clientP12Path: path),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tak = context.watch<TakService>();
    final t = Theme.of(context).textTheme;
    final stateText = switch (tak.state) {
      TakState.off => 'Off',
      TakState.connecting => 'Connecting…',
      TakState.connected =>
        'Connected · sent ${tak.sentCount}, received ${tak.receivedCount}',
      TakState.error => 'Not connected: ${tak.error ?? ''}',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('TAK interop', style: t.titleMedium),
        const SizedBox(height: 4),
        const Text(
          'Shows your mesh team in ATAK, WinTAK and iTAK, and TAK users on '
          'your map. Only this phone needs internet or Wi-Fi; it acts as the '
          'gateway for the whole team.',
        ),
        SwitchListTile(
          title: const Text('Local ATAK on this Wi-Fi'),
          subtitle: const Text(
            'Standard SA multicast (239.2.3.1:6969). No server.',
          ),
          value: _s.multicastEnabled,
          onChanged: (v) => unawaited(_apply(_s.copyWith(multicastEnabled: v))),
        ),
        SwitchListTile(
          title: const Text('TAK Server'),
          subtitle: Text(stateText),
          value: _s.serverEnabled,
          onChanged: (v) => unawaited(
            _apply(
              _s.copyWith(
                serverEnabled: v,
                host: _host.text.trim(),
                port: int.tryParse(_port.text) ?? _s.port,
                clientPassword: _clientPw.text,
                trustPassword: _trustPw.text,
              ),
            ),
          ),
        ),
        OutlinedButton.icon(
          icon: const Icon(Icons.folder_zip_outlined),
          label: const Text('Import connection data package (.zip)'),
          onPressed: _importPackage,
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              flex: 3,
              child: TextField(
                controller: _host,
                decoration: const InputDecoration(labelText: 'Server address'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _port,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Port'),
              ),
            ),
          ],
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Use TLS (SSL)'),
          subtitle: const Text('Usually port 8089 with TLS, 8087 without.'),
          value: _s.tls,
          onChanged: (v) => setState(() {
            _s = _s.copyWith(tls: v, port: v ? 8089 : 8087);
            _port.text = '${_s.port}';
          }),
        ),
        if (_s.tls) ...[
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Client certificate (.p12)'),
            subtitle: Text(
              _s.clientP12Path.isEmpty
                  ? 'None'
                  : _s.clientP12Path.split('/').last,
            ),
            trailing: TextButton(
              onPressed: () => _pickCert(trust: false),
              child: const Text('Choose'),
            ),
          ),
          TextField(
            controller: _clientPw,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Client certificate password',
            ),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Server trust store (.p12)'),
            subtitle: Text(
              _s.trustP12Path.isEmpty
                  ? 'None'
                  : _s.trustP12Path.split('/').last,
            ),
            trailing: TextButton(
              onPressed: () => _pickCert(trust: true),
              child: const Text('Choose'),
            ),
          ),
          TextField(
            controller: _trustPw,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Trust store password',
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Allow untrusted server certificate'),
            subtitle: const Text(
              'Only for testing; anyone could impersonate the server.',
            ),
            value: _s.allowUntrusted,
            onChanged: (v) =>
                setState(() => _s = _s.copyWith(allowUntrusted: v)),
          ),
        ],
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Relay TAK users onto the mesh'),
          subtitle: const Text(
            'Sends TAK users\' positions to your mesh team (at most one every '
            '30 s, each user at most every 5 min). Uses airtime.',
          ),
          value: _s.relayToMesh,
          onChanged: (v) => setState(() => _s = _s.copyWith(relayToMesh: v)),
        ),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: () => unawaited(
            _apply(
              _s.copyWith(
                host: _host.text.trim(),
                port: int.tryParse(_port.text) ?? _s.port,
                clientPassword: _clientPw.text,
                trustPassword: _trustPw.text,
              ),
            ),
          ),
          child: const Text('Save and reconnect'),
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}
