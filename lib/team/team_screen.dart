// MeshCore Open TAK - team screen: roster, pins, SALUTE reports, setup and
// TAK Server settings.

import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart' show MapController;
import 'package:latlong2/latlong.dart' show LatLng;
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'tak/atak_plugin_bridge.dart';
import 'tak/tak_service.dart';
import 'team_casevac_ui.dart';
import 'team_draw.dart';
import 'team_forms.dart';
import 'team_map.dart';
import 'team_mini_map.dart';
import 'team_roles_screen.dart';
import 'team_service.dart';
import 'team_wire.dart';
import 'watch_feed.dart';

class TeamScreen extends StatelessWidget {
  /// 0 Team, 1 Watch, 2 Pins, 3 Reports, 4 Setup.
  final int? initialTab;

  /// A watched report to scroll to and highlight on the Watch tab
  /// ([WatchItem.key]), e.g. the pin tapped on the map.
  final String? watchFocusKey;
  const TeamScreen({super.key, this.initialTab, this.watchFocusKey});

  @override
  Widget build(BuildContext context) {
    final team = context.watch<TeamService>();
    final watch = context.watch<WatchFeedService>();
    final tak = context.watch<TakService>();
    final ch = team.teamChannel;
    final live = team.members
        .where((m) => m.freshness == TeamFreshness.live)
        .length;
    return DefaultTabController(
      length: 5,
      initialIndex: initialTab ?? (team.enabled ? 0 : 4),
      child: Scaffold(
        appBar: AppBar(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Tactical'),
              Text(
                [
                  if (!team.enabled)
                    'Team mode off'
                  else if (ch == null)
                    'No team channel'
                  else
                    '${ch.name} · $live live',
                  if (tak.state == TakState.connected) 'TAK connected',
                  if (tak.state == TakState.error) 'TAK offline',
                ].join(' · '),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
          bottom: TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              const Tab(icon: Icon(Icons.groups_outlined), text: 'Team'),
              Tab(
                icon: Badge(
                  isLabelVisible: watch.unseenCount > 0,
                  label: Text('${watch.unseenCount}'),
                  child: const Icon(Icons.visibility_outlined),
                ),
                text: 'Watch',
              ),
              const Tab(icon: Icon(Icons.place_outlined), text: 'Pins'),
              const Tab(icon: Icon(Icons.assignment_outlined), text: 'Reports'),
              const Tab(icon: Icon(Icons.tune), text: 'Setup'),
            ],
          ),
        ),
        // No swipe between tabs: the Pins and Reports maps pan sideways.
        body: TabBarView(
          physics: const NeverScrollableScrollPhysics(),
          children: [
            const _RosterTab(),
            WatchTab(focusKey: watchFocusKey),
            const _PinsTab(),
            const _ReportsTab(),
            const _SetupTab(),
          ],
        ),
      ),
    );
  }
}

/// Shown on the Team tab until team mode is set up.
class _Onboarding extends StatelessWidget {
  const _Onboarding();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    Widget step(IconData i, String title, String body) => ListTile(
      leading: CircleAvatar(
        backgroundColor: scheme.primaryContainer,
        child: Icon(i, color: scheme.onPrimaryContainer),
      ),
      title: Text(title),
      subtitle: Text(body),
    );
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Icon(Icons.groups, size: 72, color: scheme.primary),
        const SizedBox(height: 12),
        Text(
          'Work as a team over the mesh',
          style: t.headlineSmall,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        const Text(
          'See each other on the map, drop pins, file SALUTE reports and raise '
          'SOS alerts, with no cell service.',
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        step(
          Icons.lock_outline,
          'Agree on a private channel',
          'Everyone on the team adds the same private channel.',
        ),
        step(
          Icons.badge_outlined,
          'Pick a callsign, role and colour',
          'This is how teammates (and TAK users) see you.',
        ),
        step(
          Icons.my_location,
          'Turn on team mode',
          'Your position goes out about every 90 s while moving.',
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          icon: const Icon(Icons.arrow_forward),
          label: const Text('Set up team'),
          onPressed: () => DefaultTabController.of(context).animateTo(4),
        ),
      ],
    );
  }
}

// ------------------------------------------------------------------- watch

/// Feeds from other channels (#icewatch, #dronewatch, …).
class WatchTab extends StatefulWidget {
  /// Scroll to this report ([WatchItem.key]) and highlight it.
  final String? focusKey;
  const WatchTab({super.key, this.focusKey});
  @override
  State<WatchTab> createState() => _WatchTabState();
}

class _WatchTabState extends State<WatchTab> {
  String? _channel; // null = all
  final Set<WatchLevel> _levels = {};
  bool _quakesOnly = false;
  final Set<String> _expanded = {};
  final _scroll = ScrollController();
  final _focusCard = GlobalKey();
  String? _highlight; // the report opened from the map, lit for a while
  bool _focusPending = false;
  Timer? _highlightTimer;

  @override
  void initState() {
    super.initState();
    final k = widget.focusKey;
    if (k != null) {
      _highlight = k;
      _focusPending = true;
      _expanded.add(k);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(context.read<WatchFeedService>().markSeen());
    });
  }

  @override
  void dispose() {
    _highlightTimer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  /// Brings the focused report into view: jump near it (the list is built
  /// lazily, so it may not exist yet), then centre it once it is built.
  void _scrollToFocus(int index) {
    _focusPending = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      void centre() {
        final c = _focusCard.currentContext;
        if (c != null) {
          unawaited(
            Scrollable.ensureVisible(
              c,
              alignment: 0.3,
              duration: const Duration(milliseconds: 300),
            ),
          );
        }
      }

      if (_focusCard.currentContext == null && _scroll.hasClients) {
        _scroll.jumpTo(
          (index * 76.0).clamp(0.0, _scroll.position.maxScrollExtent),
        );
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) centre();
        });
      } else {
        centre();
      }
      _highlightTimer = Timer(const Duration(seconds: 6), () {
        if (mounted) setState(() => _highlight = null);
      });
    });
  }

  Future<void> _chooseMapTtl(WatchFeedService feed) =>
      showModalBottomSheet<void>(
        context: context,
        builder: (c) => SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const ListTile(
                  title: Text('Keep watched reports on the map for'),
                  subtitle: Text(
                    'Counted from when each report happened. The feed here '
                    'keeps them all.',
                  ),
                ),
                for (final d in watchMapTtlChoices)
                  ListTile(
                    title: Text(watchTtlLabel(d)),
                    trailing: feed.mapTtl == d ? const Icon(Icons.check) : null,
                    onTap: () {
                      unawaited(feed.setMapTtl(d));
                      Navigator.pop(c);
                    },
                  ),
              ],
            ),
          ),
        ),
      );

  Future<void> _chooseChannels() => showModalBottomSheet<void>(
    context: context,
    builder: (context) {
      final feed = context.watch<WatchFeedService>();
      return SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(
              title: Text('Channels to watch'),
              subtitle: Text('Their messages show here as a compact feed.'),
            ),
            for (final c in feed.allChannels)
              CheckboxListTile(
                value: feed.watchedNames.contains(c.name),
                title: Text(c.name),
                onChanged: (v) => unawaited(feed.setWatched(c, v ?? false)),
              ),
          ],
        ),
      );
    },
  );

  @override
  Widget build(BuildContext context) {
    final feed = context.watch<WatchFeedService>();
    final scheme = Theme.of(context).colorScheme;
    if (feed.watchedChannels.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.visibility_outlined, size: 64, color: scheme.primary),
              const SizedBox(height: 12),
              const Text(
                'Watch other channels as a compact report feed. Reports with coordinates also show on '
                'the map.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('Choose channels'),
                onPressed: _chooseChannels,
              ),
            ],
          ),
        ),
      );
    }
    final all = feed.items;
    // Opened from a map pin: make sure no filter hides that report.
    if (_focusPending && all.any((i) => i.key == widget.focusKey)) {
      final f = all.firstWhere((i) => i.key == widget.focusKey);
      if (_channel != null && _channel != f.channel.name) _channel = null;
      if (_levels.isNotEmpty && !_levels.contains(f.level)) _levels.clear();
    }
    final items = [
      for (final i in all)
        if ((_channel == null || i.channel.name == _channel) &&
            (_levels.isEmpty || _levels.contains(i.level)) &&
            (!_quakesOnly || i.isQuake))
          i,
    ];
    if (_focusPending) {
      final at = items.indexWhere((i) => i.key == _highlight);
      if (at >= 0) _scrollToFocus(at);
    }
    final fix = context.watch<TeamService>().fix;
    return Column(
      children: [
        SizedBox(
          height: 48,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            children: [
              ChoiceChip(
                label: Text('All ${all.length}'),
                selected: _channel == null,
                onSelected: (_) => setState(() => _channel = null),
              ),
              for (final c in feed.watchedChannels) ...[
                const SizedBox(width: 6),
                ChoiceChip(
                  label: Text(c.name),
                  selected: _channel == c.name,
                  onSelected: (sel) =>
                      setState(() => _channel = sel ? c.name : null),
                ),
              ],
              const SizedBox(width: 6),
              ActionChip(
                avatar: const Icon(Icons.tune, size: 16),
                label: const Text('Channels'),
                onPressed: _chooseChannels,
              ),
              const SizedBox(width: 6),
              ActionChip(
                avatar: const Icon(Icons.timer_outlined, size: 16),
                label: Text('On map: ${watchTtlLabel(feed.mapTtl)}'),
                onPressed: () => _chooseMapTtl(feed),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            children: [
              for (final l in WatchLevel.values.where(
                (l) => l != WatchLevel.none,
              )) ...[
                FilterChip(
                  avatar: CircleAvatar(
                    backgroundColor: Color(l.argb),
                    radius: 6,
                  ),
                  label: Text(
                    '${l.label[0]}${l.label.substring(1).toLowerCase()} '
                    '${all.where((i) => i.level == l).length}',
                  ),
                  selected: _levels.contains(l),
                  onSelected: (sel) =>
                      setState(() => sel ? _levels.add(l) : _levels.remove(l)),
                ),
                const SizedBox(width: 6),
              ],
              if (all.any((i) => i.isQuake))
                FilterChip(
                  avatar: const Icon(Icons.waves, size: 16),
                  label: Text('Quakes ${all.where((i) => i.isQuake).length}'),
                  selected: _quakesOnly,
                  onSelected: (sel) => setState(() => _quakesOnly = sel),
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: items.isEmpty
              ? const Center(child: Text('Nothing matches these filters.'))
              : ListView.builder(
                  controller: _scroll,
                  itemCount: items.length,
                  itemBuilder: (context, i) {
                    final it = items[i];
                    final open = _expanded.contains(it.key);
                    final lit = it.key == _highlight;
                    return _WatchCard(
                      key: lit ? _focusCard : null,
                      highlighted: lit,
                      item: it,
                      unseen: feed.isUnseen(it),
                      expanded: open,
                      range: fix == null || !it.hasPosition
                          ? null
                          : teamRangeBearing(
                              teamDistanceMeters(
                                fix.lat,
                                fix.lon,
                                it.lat!,
                                it.lon!,
                              ),
                              teamBearingDeg(
                                fix.lat,
                                fix.lon,
                                it.lat!,
                                it.lon!,
                              ),
                            ),
                      onTap: () => setState(
                        () => open
                            ? _expanded.remove(it.key)
                            : _expanded.add(it.key),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _WatchCard extends StatelessWidget {
  final WatchItem item;
  final bool unseen, expanded;
  final bool highlighted; // opened from its pin on the map
  final String? range;
  final VoidCallback onTap;
  const _WatchCard({
    super.key,
    this.highlighted = false,
    required this.item,
    required this.unseen,
    required this.expanded,
    required this.onTap,
    this.range,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final it = item;
    final color = Color(it.level.argb);
    final meta = [
      it.when ?? teamAgo(it.time),
      ?it.detail,
      if (it.counts.isNotEmpty)
        it.counts.map((c) => '${c.$1} ${c.$2}').join('  '),
      if (it.hasSecondPosition)
        '${it.isDrone ? 'operator' : it.label2 ?? '2nd point'} on map',
      it.channel.name,
      ?range,
    ].join(' · ');
    return InkWell(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(color: color, width: 5),
            bottom: BorderSide(color: scheme.outlineVariant, width: 0.5),
          ),
          color: highlighted
              ? color.withValues(alpha: 0.28)
              : unseen
              ? scheme.primaryContainer.withValues(alpha: 0.18)
              : null,
        ),
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (it.statusWord != null) ...[
                  Text(
                    it.statusWord!,
                    style: t.labelMedium?.copyWith(
                      color: color,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Text(
                    it.headline,
                    maxLines: expanded ? 3 : 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.titleSmall,
                  ),
                ),
                if (it.hasPosition)
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.track_changes, size: 20),
                    tooltip: 'Bloodhound',
                    onPressed: () {
                      context.read<TeamService>().houndPoint(
                        it.lat!,
                        it.lon!,
                        it.place ?? it.channel.name,
                      );
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Bloodhound set. Open the map to follow it.',
                          ),
                        ),
                      );
                    },
                  ),
                if (it.url != null)
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.open_in_new, size: 20),
                    tooltip: 'Open link',
                    onPressed: () => unawaited(
                      launchUrl(
                        Uri.parse(it.url!),
                        mode: LaunchMode.externalApplication,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              meta,
              style: t.bodySmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            if (expanded) ...[
              const SizedBox(height: 6),
              Text(it.message.text, style: t.bodyMedium),
              const SizedBox(height: 4),
              Text(
                'From ${it.message.senderName} · ${teamAgo(it.time)}',
                style: t.bodySmall,
              ),
            ],
          ],
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
    if (!team.enabled) return const _Onboarding();
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
                  child: Icon(
                    teamRoleIconFor(team, team.roleId),
                    color: Colors.black,
                  ),
                ),
                title: Text('${team.callsign} (you)'),
                subtitle: Text(
                  [
                    team.roleName(team.roleId),
                    if (fix == null)
                      'no position'
                    else
                      switch (fix.source) {
                        TeamFixSource.phone =>
                          'phone GPS ±${fix.accuracy.round()} m',
                        TeamFixSource.atak => 'ATAK position',
                        _ => 'radio GPS',
                      },
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
              child: Icon(
                teamRoleIconFor(team, m.position.roleId),
                color: Colors.black,
              ),
            ),
            title: Text(
              '${m.callsign}${m.position.relayed ? ' (TAK)' : ''}'
              '${m.position.sosActive ? '  · SOS' : ''}',
            ),
            subtitle: Text(
              [
                team.roleName(m.position.roleId),
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

/// "N hidden on this phone · Show again", when anything is hidden.
Widget? _hiddenRow(BuildContext context, TeamService team) {
  if (team.hiddenCount == 0) return null;
  return ListTile(
    dense: true,
    leading: const Icon(Icons.visibility_off_outlined),
    title: Text(
      '${team.hiddenCount} hidden on this phone (pins and reports others '
      'placed)',
    ),
    trailing: TextButton(
      onPressed: team.unhideAll,
      child: const Text('Show again'),
    ),
  );
}

/// The mini map above (or beside, on wide screens) a list.
class _MapAndList extends StatelessWidget {
  final Widget map;
  final Widget list;
  const _MapAndList({required this.map, required this.list});

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      if (box.maxWidth >= 840) {
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(flex: 3, child: map),
            const VerticalDivider(width: 1),
            Expanded(flex: 2, child: list),
          ],
        );
      }
      return Column(
        children: [
          SizedBox(height: teamMiniMapHeight(context), child: map),
          const Divider(height: 1),
          Expanded(child: list),
        ],
      );
    },
  );
}

class _PinsTab extends StatefulWidget {
  const _PinsTab();
  @override
  State<_PinsTab> createState() => _PinsTabState();
}

class _PinsTabState extends State<_PinsTab> {
  final _map = MapController();

  @override
  void dispose() {
    _map.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final team = context.watch<TeamService>();
    final fix = team.fix;
    final map = TeamMiniMap(
      controller: _map,
      points: [
        for (final m in team.markers) LatLng(m.lat, m.lon),
        for (final sh in team.shapes)
          for (final pt in sh.points) LatLng(pt.$1, pt.$2),
      ],
      dropLabel: 'Pin here',
      dropIcon: Icons.add_location_alt,
      onDrop: (at) =>
          showTeamPinEditor(context, lat: at.latitude, lon: at.longitude),
    );
    final hidden = _hiddenRow(context, team);
    final list = team.markers.isEmpty && team.shapes.isEmpty
        ? Column(
            children: [
              const Expanded(
                child: _Empty(
                  'No pins or drawings yet. Hold the map above to drop a pin, '
                  'or use Tools on the full map to draw, plan a route or set '
                  'a geofence.',
                ),
              ),
              ?hidden,
            ],
          )
        : ListView(
            padding: const EdgeInsets.only(bottom: 88),
            children: [
              if (team.shapes.isNotEmpty)
                const ListTile(
                  dense: true,
                  title: Text('Routes, drawings and geofences'),
                ),
              for (final sh in team.shapes)
                ListTile(
                  leading: Icon(
                    shapeKindIcon(sh.kind, geofence: sh.isGeofence),
                    color: Color(sh.color.argb),
                  ),
                  title: Text(sh.title),
                  subtitle: Text(
                    [
                      sh.isGeofence
                          ? 'Geofence · ${sh.geofence.label}'
                          : sh.kind.label,
                      if (sh.kind == ShapeKind.route)
                        '${teamFormatLength(sh.lengthM)} · ${routeEta(sh)}',
                      teamAgo(sh.time),
                    ].join(' · '),
                  ),
                  trailing: IconButton(
                    icon: team.navRoute?.key == sh.key
                        ? const Icon(Icons.navigation, color: Color(0xFFFF6D00))
                        : const Icon(Icons.info_outline),
                    tooltip: 'Details',
                    onPressed: () => showTeamShapeSheet(context, sh),
                  ),
                  onTap: () {
                    if (sh.points.isNotEmpty) {
                      teamMiniMapShow(
                        _map,
                        sh.points.first.$1,
                        sh.points.first.$2,
                      );
                    }
                  },
                ),
              if (team.shapes.isNotEmpty && team.markers.isNotEmpty)
                const ListTile(dense: true, title: Text('Pins')),
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
                  trailing: IconButton(
                    icon: const Icon(Icons.info_outline),
                    tooltip: 'Details',
                    onPressed: () => showTeamPinSheet(context, m),
                  ),
                  onTap: () => teamMiniMapShow(_map, m.lat, m.lon),
                ),
              ?hidden,
            ],
          );
    return Scaffold(
      body: _MapAndList(map: map, list: list),
      floatingActionButton: team.active
          ? FloatingActionButton.extended(
              icon: const Icon(Icons.person_pin_circle_outlined),
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

/// A report (general, SALUTE or CASEVAC) at [lat], [lon].
Future<void> _reportAt(BuildContext context, double lat, double lon) =>
    showModalBottomSheet<void>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_note),
              title: const Text('Report here'),
              subtitle: const Text('Anything the team should know'),
              onTap: () {
                Navigator.pop(c);
                showGeneralReportForm(context, lat: lat, lon: lon);
              },
            ),
            ListTile(
              leading: const Icon(Icons.report_outlined),
              title: const Text('SALUTE report here'),
              onTap: () {
                Navigator.pop(c);
                showSaluteForm(context, lat: lat, lon: lon);
              },
            ),
            ListTile(
              leading: const Icon(Icons.local_hospital, color: casevacRed),
              title: const Text('CASEVAC 9-line here'),
              onTap: () {
                Navigator.pop(c);
                showCasevacForm(context, lat: lat, lon: lon);
              },
            ),
          ],
        ),
      ),
    );

class _ReportsTab extends StatefulWidget {
  const _ReportsTab();
  @override
  State<_ReportsTab> createState() => _ReportsTabState();
}

class _ReportsTabState extends State<_ReportsTab> {
  final _map = MapController();

  @override
  void dispose() {
    _map.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final team = context.watch<TeamService>();
    final fix = team.fix;
    final map = TeamMiniMap(
      controller: _map,
      points: [
        for (final c in team.casevacs)
          if (c.lat != 0 || c.lon != 0) LatLng(c.lat, c.lon),
        for (final r in team.reports)
          if (r.lat != 0 || r.lon != 0) LatLng(r.lat, r.lon),
      ],
      dropLabel: 'Report here',
      dropIcon: Icons.report_outlined,
      onDrop: (at) => _reportAt(context, at.latitude, at.longitude),
    );
    final hidden = _hiddenRow(context, team);
    final list = team.reports.isEmpty && team.casevacs.isEmpty
        ? Column(
            children: [
              const Expanded(
                child: _Empty(
                  'No reports yet. Hold the map above where you saw it to file '
                  'a report, SALUTE or CASEVAC request.',
                ),
              ),
              ?hidden,
            ],
          )
        : ListView(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 88),
            children: [
              for (final c in team.casevacs)
                Card(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(color: casevacColor(c), width: 2),
                  ),
                  child: InkWell(
                    onTap: () {
                      if (c.lat != 0 || c.lon != 0) {
                        teamMiniMapShow(_map, c.lat, c.lon);
                      }
                      showCasevacSheet(context, c);
                    },
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: CasevacCard(request: c),
                    ),
                  ),
                ),
              for (final r in team.reports)
                Card(
                  child: InkWell(
                    onTap: () {
                      if (r.lat != 0 || r.lon != 0) {
                        teamMiniMapShow(_map, r.lat, r.lon);
                      }
                      showTeamReportSheet(context, r);
                    },
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: TeamReportCard(report: r),
                    ),
                  ),
                ),
              ?hidden,
            ],
          );
    return Scaffold(
      body: _MapAndList(map: map, list: list),
      floatingActionButton: team.active
          ? FloatingActionButton.extended(
              icon: const Icon(Icons.person_pin_circle_outlined),
              label: const Text('Report at my position'),
              onPressed: fix == null
                  ? null
                  : () => _reportAt(context, fix.lat, fix.lon),
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

  Widget _section(
    BuildContext context,
    int n,
    String title,
    List<Widget> children, {
    bool done = false,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const SizedBox(width: 8),
                CircleAvatar(
                  radius: 13,
                  backgroundColor: done ? Colors.green : scheme.primary,
                  child: done
                      ? const Icon(Icons.check, size: 16, color: Colors.white)
                      : Text(
                          '$n',
                          style: TextStyle(
                            color: scheme.onPrimary,
                            fontSize: 13,
                          ),
                        ),
                ),
                const SizedBox(width: 10),
                Text(title, style: Theme.of(context).textTheme.titleMedium),
              ],
            ),
            ...children,
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final team = context.watch<TeamService>();
    final channels = team.candidateChannels;
    final current = team.teamChannel;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        _section(context, 1, 'Team channel', done: current != null, [
          if (channels.isEmpty)
            const ListTile(
              leading: Icon(Icons.info_outline),
              title: Text('No private channels yet'),
              subtitle: Text(
                'Create one under Channels and share it with your team. Public '
                'and # channels can\'t be used: positions would go to everyone.',
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: DropdownButtonFormField<int>(
                initialValue: current?.index,
                decoration: const InputDecoration(
                  labelText: 'Private channel your team shares',
                  border: OutlineInputBorder(),
                ),
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
        ]),
        _section(context, 2, 'You', done: team.callsignSetting.isNotEmpty, [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: TextField(
              controller: _callsign,
              maxLength: teamMaxCallsignBytes,
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(
                labelText: 'Callsign',
                hintText: team.callsign,
                border: const OutlineInputBorder(),
              ),
              onSubmitted: (v) => unawaited(team.configure(callsign: v)),
              onTapOutside: (_) {
                if (_callsign.text.trim() != team.callsignSetting) {
                  unawaited(team.configure(callsign: _callsign.text));
                }
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final r in team.roleIds)
                  ChoiceChip(
                    avatar: Icon(teamRoleIconFor(team, r), size: 16),
                    label: Text(team.roleName(r)),
                    selected: team.roleId == r,
                    onSelected: (_) => unawaited(team.configure(roleId: r)),
                  ),
                ActionChip(
                  avatar: const Icon(Icons.edit_outlined, size: 16),
                  label: const Text('Edit roles'),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const TeamRolesScreen(),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final c in TeamColor.values)
                  Tooltip(
                    message: c.label,
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () => unawaited(team.configure(color: c)),
                      child: Container(
                        width: 32,
                        height: 32,
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
                        child: team.color == c
                            ? Icon(
                                Icons.check,
                                size: 18,
                                color: Color(c.argb).computeLuminance() > 0.5
                                    ? Colors.black
                                    : Colors.white,
                              )
                            : null,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ]),
        _section(context, 3, 'Go live', done: team.active, [
          SwitchListTile(
            title: const Text('Team mode'),
            subtitle: Text(
              team.enabled
                  ? (team.inactiveReason ??
                        'On. Your team sees you on the map.')
                  : 'Share your position, pins, reports and alerts with the team.',
            ),
            value: team.enabled,
            onChanged: current == null && !team.enabled
                ? null
                : (v) => unawaited(team.configure(enabled: v)),
          ),
          SwitchListTile(
            title: const Text('Share my position'),
            subtitle: Text(
              team.gpsProblem ??
                  'Phone GPS (radio GPS as a fallback). About every 90 s while '
                      'moving, every 10 min when still, and at once on a sharp turn.',
            ),
            value: team.sharePosition,
            onChanged: (v) => unawaited(team.configure(sharePosition: v)),
          ),
          ListTile(
            leading: const Icon(Icons.replay),
            title: const Text('Resend my pins and drawings'),
            subtitle: const Text(
              'For teammates who joined after you dropped them.',
            ),
            onTap: team.active
                ? () async {
                    final n = await team.resendMyMarkers();
                    final d = await team.resendMyShapes();
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Resent $n pins and $d drawings'),
                        ),
                      );
                    }
                  }
                : null,
          ),
        ]),
        const Card(
          child: Padding(padding: EdgeInsets.all(12), child: _TakSettings()),
        ),
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
        const _AtakPluginTile(),
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
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Team chat to TAK GeoChat'),
          subtitle: const Text(
            'Team channel messages appear in TAK\'s All Chat Rooms. TAK chat '
            'shows in the map chat pane.',
          ),
          value: _s.geoChat,
          onChanged: (v) => setState(() => _s = _s.copyWith(geoChat: v)),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Post TAK chat on the team channel'),
          subtitle: const Text(
            'Relays TAK All Chat Rooms messages to your mesh team as text '
            '(at most one every 15 s). Uses airtime.',
          ),
          value: _s.chatToMesh,
          onChanged: (v) => setState(() => _s = _s.copyWith(chatToMesh: v)),
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

/// Lets the MeshCore ATAK plugin on this phone use this app's radio.
class _AtakPluginTile extends StatefulWidget {
  const _AtakPluginTile();

  @override
  State<_AtakPluginTile> createState() => _AtakPluginTileState();
}

class _AtakPluginTileState extends State<_AtakPluginTile> {
  @override
  Widget build(BuildContext context) {
    final bridge = context.read<AtakPluginBridge>();
    return SwitchListTile(
      title: const Text('ATAK plugin on this phone'),
      subtitle: const Text(
        'Lets the MeshCore ATAK plugin use this radio, your team channel and '
        'voice and photo codecs. Only ATAK can connect.',
      ),
      value: bridge.enabled,
      onChanged: (v) async {
        await bridge.setEnabled(v);
        if (mounted) setState(() {});
      },
    );
  }
}
