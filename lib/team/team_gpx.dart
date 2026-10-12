// MeshCore Open TAK - export the tactical picture as GPX: pins, SALUTE
// reports and CASEVACs as waypoints, routes as routes, drawings and
// teammates' trails as tracks.

import 'dart:io';

import 'package:gpx/gpx.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'team_service.dart';
import 'team_wire.dart';

/// Builds the GPX document (pure, for tests).
String buildTeamGpx({
  List<TeamMarker> markers = const [],
  List<TeamReport> reports = const [],
  List<TeamCasevac> casevacs = const [],
  List<TeamShape> shapes = const [],
  List<TeamMember> members = const [],
  DateTime? now,
}) {
  final gpx = Gpx()
    ..version = '1.1'
    ..creator = 'MeshCore Open TAK'
    ..metadata = Metadata(
      name: 'MeshCore Open TAK export',
      time: (now ?? DateTime.now()).toUtc(),
    );

  gpx.wpts = [
    for (final m in markers)
      Wpt(
        lat: m.lat,
        lon: m.lon,
        name: m.label.isEmpty ? m.kind.label : m.label,
        desc: m.note.isEmpty ? null : m.note,
        type: m.kind.label,
        time: m.time.toUtc(),
      ),
    for (final r in reports)
      Wpt(
        lat: r.lat,
        lon: r.lon,
        name: 'SALUTE ${r.timeLabel}',
        desc: r.summary(),
        type: 'SALUTE',
        time: r.observed.toUtc(),
      ),
    for (final c in casevacs)
      Wpt(
        lat: c.lat,
        lon: c.lon,
        name: 'CASEVAC ${c.precedenceLabel} ${c.timeLabel}',
        desc: [
          ...c.nineLines(),
          if (c.remarks.isNotEmpty) c.remarks,
        ].join('\n'),
        type: 'CASEVAC',
        time: c.time.toUtc(),
      ),
  ];

  gpx.rtes = [
    for (final s in shapes)
      if (s.kind == ShapeKind.route)
        Rte(
          name: s.title,
          desc: '${s.routeMethod.label} · ${teamFormatLength(s.lengthM)}',
          rtepts: [
            for (var i = 0; i < s.points.length; i++)
              Wpt(lat: s.points[i].$1, lon: s.points[i].$2, name: 'CP${i + 1}'),
          ],
        ),
  ];

  gpx.trks = [
    for (final s in shapes)
      if (s.kind != ShapeKind.route)
        Trk(
          name: s.title,
          type: s.isGeofence ? 'Geofence' : s.kind.label,
          trksegs: [
            Trkseg(
              trkpts: [
                for (final p
                    in s.kind.closed
                        ? [
                            ...s.outline(),
                            if (s.kind != ShapeKind.circle) s.points.first,
                          ]
                        : s.points)
                  Wpt(lat: p.$1, lon: p.$2),
              ],
            ),
          ],
        ),
    for (final m in members)
      if (m.trail.length > 1)
        Trk(
          name: '${m.callsign} track',
          type: 'Track',
          trksegs: [
            Trkseg(
              trkpts: [
                for (final p in m.trail)
                  Wpt(lat: p.$1, lon: p.$2, time: p.$3.toUtc()),
              ],
            ),
          ],
        ),
  ];

  return GpxWriter().asString(gpx, pretty: true);
}

/// Writes the team's tactical picture to a GPX file and opens the share
/// sheet. Returns false if there was nothing to export.
Future<bool> shareTeamGpx(TeamService team) async {
  if (team.markers.isEmpty &&
      team.reports.isEmpty &&
      team.casevacs.isEmpty &&
      team.shapes.isEmpty &&
      team.members.every((m) => m.trail.length < 2)) {
    return false;
  }
  final xml = buildTeamGpx(
    markers: team.markers,
    reports: team.reports,
    casevacs: team.casevacs,
    shapes: team.shapes,
    members: team.members,
  );
  final stamp = DateTime.now()
      .toIso8601String()
      .substring(0, 16)
      .replaceAll(':', '');
  final dir = await getTemporaryDirectory();
  final file = File('${dir.path}/meshcore-tak-$stamp.gpx');
  await file.writeAsString(xml);
  await SharePlus.instance.share(
    ShareParams(
      files: [XFile(file.path, mimeType: 'application/gpx+xml')],
      subject: 'MeshCore Open TAK export',
    ),
  );
  return true;
}
