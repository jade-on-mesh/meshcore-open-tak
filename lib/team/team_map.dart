// MeshCore Open TAK - team layer on the map: members, trails, pins, SALUTE
// reports, TAK units, alerts, plus the SOS button and Bloodhound panel.

import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../vox/image_message_bubble.dart' show voxRgbToUiImage;
import '../vox/voice_message_bubble.dart';
import '../vox/voice_service.dart';
import '../vox/voice_wire.dart';
import 'tak/cot.dart';
import 'tak/tak_service.dart';
import 'team_forms.dart';
import 'team_screen.dart';
import 'team_service.dart';
import 'team_wire.dart';

// ------------------------------------------------------------------ styling

IconData teamRoleIcon(TeamRole r) => switch (r) {
  TeamRole.member => Icons.person,
  TeamRole.lead => Icons.star,
  TeamRole.medic => Icons.medical_services,
  TeamRole.navigator => Icons.explore,
  TeamRole.comms => Icons.cell_tower,
  TeamRole.driver => Icons.directions_car,
  TeamRole.k9 => Icons.pets,
  TeamRole.observer => Icons.visibility,
  TeamRole.command => Icons.account_balance,
};

IconData markerKindIcon(MarkerKind k) => switch (k) {
  MarkerKind.point => Icons.place,
  MarkerKind.lastKnown => Icons.person_pin_circle,
  MarkerKind.staging => Icons.flag,
  MarkerKind.clue => Icons.search,
  MarkerKind.hazard => Icons.warning_amber,
  MarkerKind.landingZone => Icons.flight_land,
  MarkerKind.medical => Icons.local_hospital,
  MarkerKind.subjectFound => Icons.emoji_people,
  MarkerKind.water => Icons.water_drop,
  MarkerKind.searched => Icons.check_circle_outline,
};

Color markerKindColor(MarkerKind k) => Color(takMarkerArgb(k));

Color affiliationColor(TeamAffiliation a) => switch (a) {
  TeamAffiliation.hostile => const Color(0xFFE53935),
  TeamAffiliation.unknown => const Color(0xFFFDD835),
  TeamAffiliation.neutral => const Color(0xFF43A047),
  TeamAffiliation.friendly => const Color(0xFF1E88E5),
};

Color urgencyColor(TeamUrgency u) => switch (u) {
  TeamUrgency.critical => const Color(0xFFE53935),
  TeamUrgency.active => const Color(0xFFFDD835),
  TeamUrgency.observed => const Color(0xFF43A047),
  TeamUrgency.other => const Color(0xFF1E88E5),
};

String teamAgo(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inSeconds < 60) return '${max(0, d.inSeconds)}s ago';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 24) return '${d.inHours} h ago';
  return '${d.inDays} d ago';
}

/// Envelope for a pin/report attachment, so the voice/photo bubble can fetch
/// and show it.
VoxVoiceEnvelope? teamAttachmentEnvelope(TeamAttachment a) {
  final mode = VoxVoiceMode.fromWireId(a.modeWireId);
  if (mode == null) return null;
  return VoxVoiceEnvelope(
    sessionId: a.sessionId,
    mode: mode,
    totalPackets: a.packets,
    durationSeconds: a.extra,
  );
}

String? _rangeFromMe(TeamService t, double lat, double lon) {
  final f = t.fix;
  if (f == null) return null;
  return teamRangeBearing(
    teamDistanceMeters(f.lat, f.lon, lat, lon),
    teamBearingDeg(f.lat, f.lon, lat, lon),
  );
}

Widget _label(String text, {Color? color}) => Container(
  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
  decoration: BoxDecoration(
    color: Colors.black.withValues(alpha: 0.65),
    borderRadius: BorderRadius.circular(4),
  ),
  child: Text(
    text,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: TextStyle(color: color ?? Colors.white, fontSize: 10),
  ),
);

// --------------------------------------------------------------- the layer

/// Polylines and markers for the team. Put it in FlutterMap's children.
class TeamMapLayer extends StatelessWidget {
  const TeamMapLayer({super.key});

  @override
  Widget build(BuildContext context) {
    final team = context.watch<TeamService>();
    final tak = context.watch<TakService>();
    if (!team.enabled && tak.entities.isEmpty) return const SizedBox.shrink();
    final fix = team.fix;
    final hound = team.bloodhound;

    final lines = <Polyline>[
      for (final m in team.members)
        if (m.trail.length > 1)
          Polyline(
            points: [for (final p in m.trail) LatLng(p.$1, p.$2)],
            color: Color(m.position.color.argb).withValues(
              alpha: m.freshness == TeamFreshness.live ? 0.7 : 0.3,
            ),
            strokeWidth: 3,
          ),
      if (hound != null && fix != null)
        Polyline(
          points: [LatLng(fix.lat, fix.lon), LatLng(hound.lat, hound.lon)],
          color: const Color(0xFFFF6D00),
          strokeWidth: 3,
          pattern: StrokePattern.dashed(segments: const [12, 8]),
        ),
    ];

    final markers = <Marker>[
      // TAK units and markers (under the mesh team).
      for (final e in tak.entities) _takMarker(context, e),
      for (final r in team.reports) _reportMarker(context, r),
      for (final m in team.markers) _pinMarker(context, team, m),
      for (final m in team.members) _memberMarker(context, m),
      for (final a in team.activeAlerts)
        if (a.lat != null && a.lon != null)
          Marker(
            point: LatLng(a.lat!, a.lon!),
            width: 120,
            height: 120,
            child: IgnorePointer(child: _AlertPulse(label: a.type.label)),
          ),
      if (fix != null && team.enabled)
        Marker(
          point: LatLng(fix.lat, fix.lon),
          width: 34,
          height: 34,
          child: IgnorePointer(
            child: _SelfDot(
              heading: fix.heading,
              color: Color(team.color.argb),
              sos: team.activeOwnAlert != null,
            ),
          ),
        ),
    ];

    return Stack(
      children: [
        if (lines.isNotEmpty) PolylineLayer(polylines: lines),
        MarkerLayer(markers: markers),
      ],
    );
  }

  Marker _memberMarker(BuildContext context, TeamMember m) {
    final p = m.position;
    final color = Color(p.color.argb);
    final fade = switch (m.freshness) {
      TeamFreshness.live => 1.0,
      TeamFreshness.stale => 0.6,
      TeamFreshness.lost => 0.35,
    };
    return Marker(
      point: LatLng(p.lat, p.lon),
      width: 96,
      height: 64,
      child: GestureDetector(
        onTap: () => showTeamMemberSheet(context, m.key4),
        child: Opacity(
          opacity: fade,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 40,
                height: 40,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    if (p.headingDeg != null)
                      Transform.rotate(
                        angle: p.headingDeg! * pi / 180,
                        child: const Align(
                          alignment: Alignment.topCenter,
                          child: Icon(Icons.navigation, size: 14, color: Colors.white),
                        ),
                      ),
                    Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: p.sosActive ? Colors.red : Colors.black87,
                          width: p.sosActive ? 3 : 2,
                        ),
                      ),
                      child: Icon(
                        teamRoleIcon(p.role),
                        size: 16,
                        color: color.computeLuminance() > 0.5
                            ? Colors.black
                            : Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
              _label(
                p.relayed ? '${m.callsign} (TAK)' : m.callsign,
                color: m.freshness == TeamFreshness.live ? null : Colors.white70,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Marker _pinMarker(BuildContext context, TeamService team, TeamMarker m) {
    final c = markerKindColor(m.kind);
    final env = m.attachment == null ? null : teamAttachmentEnvelope(m.attachment!);
    return Marker(
      point: LatLng(m.lat, m.lon),
      width: 110,
      height: env != null && env.isImage ? 120 : 62,
      alignment: Alignment.topCenter,
      child: GestureDetector(
        onTap: () => showTeamPinSheet(context, m),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            if (env != null && env.isImage)
              _PinThumb(envelope: env, authorKey4: m.authorKey4),
            Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: c, width: 2),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(markerKindIcon(m.kind), color: c, size: 18),
                  if (env != null && !env.isImage)
                    const Icon(Icons.mic, color: Colors.white70, size: 12),
                ],
              ),
            ),
            _label(m.label.isEmpty ? m.kind.label : m.label),
          ],
        ),
      ),
    );
  }

  Marker _reportMarker(BuildContext context, TeamReport r) {
    final c = affiliationColor(r.affiliation);
    return Marker(
      point: LatLng(r.lat, r.lon),
      width: 110,
      height: 60,
      child: GestureDetector(
        onTap: () => showTeamReportSheet(context, r),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Transform.rotate(
              angle: pi / 4,
              child: Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: c,
                  border: Border.all(color: urgencyColor(r.urgency), width: 3),
                ),
              ),
            ),
            const SizedBox(height: 4),
            _label('${r.urgency.dot} ${r.countsLabel.isEmpty ? 'SALUTE' : r.countsLabel}'),
          ],
        ),
      ),
    );
  }

  Marker _takMarker(BuildContext context, TakEntity t) {
    final e = t.event;
    final color = e.colorArgb != null
        ? Color(e.colorArgb! & 0xFFFFFFFF)
        : Color(teamColorFromTakGroup(e.groupName).argb);
    final hostile = e.type.startsWith('a-h');
    return Marker(
      point: LatLng(e.lat, e.lon),
      width: 96,
      height: 56,
      child: GestureDetector(
        onTap: () => showTakEntitySheet(context, t),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: hostile ? Colors.red : color,
                border: Border.all(color: Colors.black87, width: 2),
                shape: e.isUnit ? BoxShape.rectangle : BoxShape.circle,
              ),
              child: Icon(
                e.isAlert ? Icons.sos : (e.isUnit ? Icons.person : Icons.place),
                size: 14,
                color: Colors.black,
              ),
            ),
            _label('${e.callsign ?? e.uid} · TAK'),
          ],
        ),
      ),
    );
  }
}

class _SelfDot extends StatelessWidget {
  final double? heading;
  final Color color;
  final bool sos;
  const _SelfDot({required this.heading, required this.color, required this.sos});

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        if (heading != null)
          Transform.rotate(
            angle: heading! * pi / 180,
            child: const Icon(Icons.navigation, size: 34, color: Color(0x992196F3)),
          ),
        Container(
          width: 16,
          height: 16,
          decoration: BoxDecoration(
            color: const Color(0xFF2196F3),
            shape: BoxShape.circle,
            border: Border.all(color: sos ? Colors.red : color, width: 3),
          ),
        ),
      ],
    );
  }
}

class _AlertPulse extends StatefulWidget {
  final String label;
  const _AlertPulse({required this.label});
  @override
  State<_AlertPulse> createState() => _AlertPulseState();
}

class _AlertPulseState extends State<_AlertPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) => Stack(
        alignment: Alignment.center,
        children: [
          Container(
            width: 40 + 70 * _c.value,
            height: 40 + 70 * _c.value,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.red.withValues(alpha: 0.35 * (1 - _c.value)),
              border: Border.all(color: Colors.red, width: 2),
            ),
          ),
          _label(widget.label, color: Colors.redAccent),
        ],
      ),
    );
  }
}

/// A pin's photo shown on the map once it has been downloaded.
class _PinThumb extends StatefulWidget {
  final VoxVoiceEnvelope envelope;
  final String authorKey4;
  const _PinThumb({required this.envelope, required this.authorKey4});
  @override
  State<_PinThumb> createState() => _PinThumbState();
}

class _PinThumbState extends State<_PinThumb> {
  ui.Image? _img;
  VoxVoiceService? _voice;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final v = context.read<VoxVoiceService>();
    if (v != _voice) {
      _voice?.removeListener(_check);
      _voice = v..addListener(_check);
      final team = context.read<TeamService>();
      unawaited(
        v
            .warmUp(
              widget.envelope,
              sender: v.contactByKeyPrefix(widget.authorKey4),
              channelIndex: team.teamChannel?.index,
            )
            .then((_) => _check()),
      );
    }
  }

  void _check() {
    final v = _voice;
    if (v == null || _img != null || !mounted) return;
    if (v.stateFor(widget.envelope).status != VoxClipStatus.complete) return;
    unawaited(() async {
      final rgb = await v.imageFor(widget.envelope);
      if (rgb == null || !mounted) return;
      final img = await voxRgbToUiImage(rgb);
      if (!mounted) {
        img.dispose();
        return;
      }
      setState(() => _img = img);
    }());
  }

  @override
  void dispose() {
    _voice?.removeListener(_check);
    _img?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final img = _img;
    return Container(
      width: 64,
      height: 52,
      margin: const EdgeInsets.only(bottom: 2),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.white, width: 2),
      ),
      clipBehavior: Clip.antiAlias,
      child: img == null
          ? const Icon(Icons.photo_camera, color: Colors.white70, size: 20)
          : RawImage(image: img, fit: BoxFit.cover),
    );
  }
}

// ------------------------------------------------------------------ sheets

Widget _attachmentView(BuildContext context, TeamAttachment a, String authorKey4) {
  final env = teamAttachmentEnvelope(a);
  if (env == null) return const SizedBox.shrink();
  final voice = context.read<VoxVoiceService>();
  final team = context.read<TeamService>();
  return VoxVoiceMessageContent(
    envelope: env,
    isOutgoing: authorKey4 == team.selfKey4,
    textColor: Theme.of(context).colorScheme.onSurface,
    sender: voice.contactByKeyPrefix(authorKey4),
    channelIndex: team.teamChannel?.index,
  );
}

Widget _houndButton(BuildContext context, VoidCallback start) => FilledButton.tonalIcon(
  icon: const Icon(Icons.track_changes),
  label: const Text('Bloodhound'),
  onPressed: () {
    start();
    Navigator.pop(context);
  },
);

Future<void> showTeamMemberSheet(BuildContext context, String key4) =>
    showModalBottomSheet<void>(
      context: context,
      builder: (context) {
        final team = context.watch<TeamService>();
        final m = team.memberByKey(key4);
        if (m == null) return const SizedBox(height: 120);
        final p = m.position;
        final range = _rangeFromMe(team, p.lat, p.lon);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    CircleAvatar(
                      backgroundColor: Color(p.color.argb),
                      child: Icon(teamRoleIcon(p.role), color: Colors.black),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(m.callsign, style: Theme.of(context).textTheme.titleLarge),
                          Text(
                            '${p.role.label} · ${p.color.label} team'
                            '${p.relayed ? ' · via TAK' : ''}',
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (p.sosActive)
                  const Text('SOS ACTIVE', style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
                if (p.status != TeamStatus.none) Text('Status: ${p.status.label}'),
                Text('Heard ${teamAgo(m.heard)}${p.fromRadio ? ' · radio GPS' : ''}'),
                if (range != null) Text('From you: $range'),
                if (p.speedMps != null && p.speedMps! > 0.3)
                  Text(
                    'Moving ${(p.speedMps! * 3.6).toStringAsFixed(1)} km/h, '
                    'heading ${p.headingDeg!.round()}°',
                  ),
                if (p.altitudeM != null) Text('Altitude ${p.altitudeM} m'),
                if (p.batteryPct != null) Text('Battery ${p.batteryPct}%'),
                Text(
                  '${p.lat.toStringAsFixed(5)}, ${p.lon.toStringAsFixed(5)}'
                  '${p.accuracyM > 0 ? ' ±${p.accuracyM} m' : ''}',
                ),
                const SizedBox(height: 12),
                _houndButton(context, () => team.houndMember(key4)),
              ],
            ),
          ),
        );
      },
    );

Future<void> showTeamPinSheet(BuildContext context, TeamMarker m) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        final team = context.watch<TeamService>();
        final author = team.memberByKey(m.authorKey4)?.callsign ??
            (team.isMine(m) ? 'You' : m.authorKey4.toUpperCase());
        final range = _rangeFromMe(team, m.lat, m.lon);
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(markerKindIcon(m.kind), color: markerKindColor(m.kind), size: 32),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        m.label.isEmpty ? m.kind.label : m.label,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                  ],
                ),
                Text('${m.kind.label} · by $author · ${teamAgo(m.time)}'),
                if (range != null) Text('From you: $range'),
                Text('${m.lat.toStringAsFixed(5)}, ${m.lon.toStringAsFixed(5)}'),
                if (m.note.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(m.note),
                ],
                if (m.attachment != null) ...[
                  const SizedBox(height: 12),
                  _attachmentView(context, m.attachment!, m.authorKey4),
                ],
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _houndButton(
                      context,
                      () => team.houndPoint(m.lat, m.lon, m.label.isEmpty ? m.kind.label : m.label),
                    ),
                    if (team.isMine(m))
                      OutlinedButton.icon(
                        icon: const Icon(Icons.edit),
                        label: const Text('Edit'),
                        onPressed: () {
                          Navigator.pop(context);
                          showTeamPinEditor(context, lat: m.lat, lon: m.lon, existing: m);
                        },
                      ),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.delete_outline),
                      label: Text(team.isMine(m) ? 'Delete for team' : 'Hide'),
                      onPressed: () {
                        unawaited(team.deleteMarker(m));
                        Navigator.pop(context);
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

/// The condensed SALUTE card (also used in lists).
class TeamReportCard extends StatelessWidget {
  final TeamReport report;
  const TeamReportCard({super.key, required this.report});

  @override
  Widget build(BuildContext context) {
    final r = report;
    final lines = r.condensedLines();
    final t = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 16,
              height: 16,
              decoration: BoxDecoration(
                color: urgencyColor(r.urgency),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            Text(r.urgency.label, style: t.titleMedium),
            const Spacer(),
            Text(r.affiliation.label, style: TextStyle(color: affiliationColor(r.affiliation))),
          ],
        ),
        for (final l in lines.skip(1)) Text(l, style: t.bodyLarge),
      ],
    );
  }
}

Future<void> showTeamReportSheet(BuildContext context, TeamReport r) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        final team = context.watch<TeamService>();
        final author = team.memberByKey(r.authorKey4)?.callsign ??
            (r.authorKey4 == team.selfKey4 ? 'You' : r.authorKey4.toUpperCase());
        final range = _rangeFromMe(team, r.lat, r.lon);
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('SALUTE report', style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: 6),
                TeamReportCard(report: r),
                const SizedBox(height: 8),
                Text('By $author${range == null ? '' : ' · $range from you'}'),
                if (r.attachment != null) ...[
                  const SizedBox(height: 12),
                  _attachmentView(context, r.attachment!, r.authorKey4),
                ],
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  children: [
                    _houndButton(
                      context,
                      () => team.houndPoint(r.lat, r.lon, 'SALUTE @${r.placeLabel}'),
                    ),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('Remove from my map'),
                      onPressed: () {
                        unawaited(team.deleteReport(r));
                        Navigator.pop(context);
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

Future<void> showTakEntitySheet(BuildContext context, TakEntity t) =>
    showModalBottomSheet<void>(
      context: context,
      builder: (context) {
        final team = context.read<TeamService>();
        final e = t.event;
        final range = _rangeFromMe(team, e.lat, e.lon);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(e.callsign ?? e.uid, style: Theme.of(context).textTheme.titleLarge),
                Text('From TAK · ${e.type}${e.groupRole == null ? '' : ' · ${e.groupRole}'}'
                    '${e.groupName == null ? '' : ' · ${e.groupName}'}'),
                Text('Updated ${teamAgo(e.time)}'),
                if (range != null) Text('From you: $range'),
                if (e.emergencyType != null) Text('Alert: ${e.emergencyType}',
                    style: const TextStyle(color: Colors.red)),
                if ((e.remarks ?? '').isNotEmpty) Text(e.remarks!),
                const SizedBox(height: 12),
                _houndButton(context, () => team.houndPoint(e.lat, e.lon, e.callsign ?? 'TAK')),
              ],
            ),
          ),
        );
      },
    );

/// Long-press on the map with team mode on.
Future<void> showTeamMapActions(
  BuildContext context,
  LatLng at, {
  required VoidCallback shareMarker,
}) => showModalBottomSheet<void>(
  context: context,
  builder: (context) {
    final team = context.read<TeamService>();
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            title: Text('${at.latitude.toStringAsFixed(5)}, ${at.longitude.toStringAsFixed(5)}'),
            subtitle: Text(_rangeFromMe(team, at.latitude, at.longitude) ?? ''),
          ),
          ListTile(
            leading: const Icon(Icons.add_location_alt),
            title: const Text('Drop tactical pin'),
            onTap: () {
              Navigator.pop(context);
              showTeamPinEditor(context, lat: at.latitude, lon: at.longitude);
            },
          ),
          ListTile(
            leading: const Icon(Icons.report_outlined),
            title: const Text('SALUTE report here'),
            onTap: () {
              Navigator.pop(context);
              showSaluteForm(context, lat: at.latitude, lon: at.longitude);
            },
          ),
          ListTile(
            leading: const Icon(Icons.track_changes),
            title: const Text('Bloodhound to here'),
            onTap: () {
              team.houndPoint(at.latitude, at.longitude, 'Map point');
              Navigator.pop(context);
            },
          ),
          ListTile(
            leading: const Icon(Icons.share_location),
            title: const Text('Share as chat marker'),
            onTap: () {
              Navigator.pop(context);
              shareMarker();
            },
          ),
        ],
      ),
    );
  },
);

// ---------------------------------------------------------------- overlay

/// SOS button, active-alert banner, Bloodhound readout and team button,
/// drawn over the map.
class TeamMapOverlay extends StatelessWidget {
  const TeamMapOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    final team = context.watch<TeamService>();
    if (!team.enabled) return const SizedBox.shrink();
    final own = team.activeOwnAlert;
    final hound = team.bloodhound;
    final fix = team.fix;
    return Positioned(
      left: 12,
      bottom: 16,
      right: 88,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (own != null)
            Material(
              color: Colors.red,
              borderRadius: BorderRadius.circular(8),
              child: InkWell(
                onTap: () => _confirmCancel(context, team),
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Text(
                    '${own.type.label.toUpperCase()} ACTIVE · tap to cancel',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ),
          if (hound != null)
            Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (fix != null)
                      Transform.rotate(
                        angle: (teamBearingDeg(fix.lat, fix.lon, hound.lat, hound.lon) -
                                (fix.heading ?? 0)) *
                            pi /
                            180,
                        child: const Icon(Icons.navigation, color: Color(0xFFFF6D00)),
                      ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        fix == null
                            ? '${hound.label}: waiting for your position'
                            : '${hound.label}\n${teamRangeBearing(
                                teamDistanceMeters(fix.lat, fix.lon, hound.lat, hound.lon),
                                teamBearingDeg(fix.lat, fix.lon, hound.lat, hound.lon),
                              )}${fix.heading == null ? ' (arrow: north up)' : ''}',
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: team.stopHound,
                      tooltip: 'Stop Bloodhound',
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 6),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _SosButton(team: team),
              const SizedBox(width: 8),
              FloatingActionButton.small(
                heroTag: 'vox-team',
                tooltip: 'Team',
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const TeamScreen()),
                ),
                child: Badge(
                  isLabelVisible: team.members.isNotEmpty,
                  label: Text('${team.members.where((m) => m.freshness == TeamFreshness.live).length}'),
                  child: const Icon(Icons.groups),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _confirmCancel(BuildContext context, TeamService team) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Cancel your alert?'),
        content: const Text('Your team will be told you no longer need help.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep it')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Cancel alert')),
        ],
      ),
    );
    if (ok == true) await team.cancelAlert();
  }
}

/// Hold for 1.5 s to raise an alert (avoids pocket presses).
class _SosButton extends StatefulWidget {
  final TeamService team;
  const _SosButton({required this.team});
  @override
  State<_SosButton> createState() => _SosButtonState();
}

class _SosButtonState extends State<_SosButton> with SingleTickerProviderStateMixin {
  late final AnimationController _hold = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  )..addStatusListener((s) {
      if (s == AnimationStatus.completed) {
        _hold.reset();
        unawaited(_choose());
      }
    });

  Future<void> _choose() async {
    final type = await showModalBottomSheet<TeamAlertType>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(title: Text('Send an alert to your team')),
            for (final t in const [
              TeamAlertType.sos,
              TeamAlertType.inContact,
              TeamAlertType.ringTheBell,
            ])
              ListTile(
                leading: Icon(
                  t == TeamAlertType.sos
                      ? Icons.sos
                      : t == TeamAlertType.inContact
                      ? Icons.warning
                      : Icons.notifications_active,
                  color: Colors.red,
                ),
                title: Text(t.label),
                subtitle: Text(switch (t) {
                  TeamAlertType.sos => 'Emergency: I need help now',
                  TeamAlertType.inContact => 'Encountered a threat or situation',
                  TeamAlertType.ringTheBell => 'All team members: respond / regroup',
                  _ => '',
                }),
                onTap: () => Navigator.pop(c, t),
              ),
          ],
        ),
      ),
    );
    if (type != null) await widget.team.raiseAlert(type);
  }

  @override
  void dispose() {
    _hold.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => _hold.forward(from: 0),
      onTapUp: (_) {
        if (_hold.isAnimating) {
          _hold.reset();
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            const SnackBar(content: Text('Hold the SOS button to send an alert')),
          );
        }
      },
      onTapCancel: () => _hold.reset(),
      child: AnimatedBuilder(
        animation: _hold,
        builder: (_, _) => Stack(
          alignment: Alignment.center,
          children: [
            SizedBox(
              width: 52,
              height: 52,
              child: CircularProgressIndicator(
                value: _hold.value,
                strokeWidth: 4,
                color: Colors.white,
              ),
            ),
            Container(
              width: 44,
              height: 44,
              decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle),
              alignment: Alignment.center,
              child: const Text(
                'SOS',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
