// MeshCore Open TAK - drawing tools on the map (lines, freehand, polygons,
// rectangles, circles, routes, geofences), the shape editor and shape sheet.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import 'team_forms.dart';
import 'team_service.dart';
import 'team_wire.dart';

IconData shapeKindIcon(ShapeKind k, {bool geofence = false}) {
  if (geofence) return Icons.fence;
  return switch (k) {
    ShapeKind.line => Icons.timeline,
    ShapeKind.freehand => Icons.gesture,
    ShapeKind.polygon => Icons.pentagon_outlined,
    ShapeKind.rectangle => Icons.crop_square,
    ShapeKind.circle => Icons.circle_outlined,
    ShapeKind.route => Icons.route,
  };
}

// --------------------------------------------------------------- controller

/// The shape being drawn. Owned by the map screen.
class TeamDrawController extends ChangeNotifier {
  ShapeKind? _tool;
  bool _geofence = false;
  bool _measure = false;
  final List<LatLng> points = [];

  ShapeKind? get tool => _tool;
  bool get active => _tool != null;
  bool get freehand => _tool == ShapeKind.freehand;
  bool get geofence => _geofence;

  /// Range & bearing: a line that is only measured, not shared (unless the
  /// user saves it).
  bool get measure => _measure;

  void start(ShapeKind kind, {bool geofence = false, bool measure = false}) {
    _tool = kind;
    _geofence = geofence && kind.closed;
    _measure = measure && kind == ShapeKind.line;
    points.clear();
    notifyListeners();
  }

  /// Starts Range & Bearing, optionally from a point (e.g. your position).
  void startMeasure({LatLng? from}) {
    start(ShapeKind.line, measure: true);
    if (from != null) {
      points.add(from);
      notifyListeners();
    }
  }

  /// Each leg as (metres, bearing degrees).
  List<(double, double)> get legs => [
    for (var i = 1; i < points.length; i++)
      (
        teamDistanceMeters(
          points[i - 1].latitude,
          points[i - 1].longitude,
          points[i].latitude,
          points[i].longitude,
        ),
        teamBearingDeg(
          points[i - 1].latitude,
          points[i - 1].longitude,
          points[i].latitude,
          points[i].longitude,
        ),
      ),
  ];

  /// "1.2 km total · last leg 350 m 045° NE"
  String get measureSummary {
    final l = legs;
    if (l.isEmpty) {
      return points.isEmpty ? 'Tap the start point' : 'Tap the next point';
    }
    final total = l.fold<double>(0, (a, b) => a + b.$1);
    final last = l.last;
    if (l.length == 1) return teamRangeBearing(last.$1, last.$2);
    return '${teamFormatLength(total)} total · last '
        '${teamRangeBearing(last.$1, last.$2)}';
  }

  void cancel() {
    _tool = null;
    _measure = false;
    points.clear();
    notifyListeners();
  }

  void tap(LatLng p) {
    final t = _tool;
    if (t == null || t == ShapeKind.freehand) return;
    if ((t == ShapeKind.rectangle || t == ShapeKind.circle) &&
        points.length >= 2) {
      points[1] = p; // move the second corner / edge
    } else {
      points.add(p);
    }
    notifyListeners();
  }

  void undo() {
    if (points.isEmpty) return;
    if (freehand) {
      points.clear();
    } else {
      points.removeLast();
    }
    notifyListeners();
  }

  void freehandStart(LatLng p) {
    points
      ..clear()
      ..add(p);
    notifyListeners();
  }

  void freehandAdd(LatLng p) {
    points.add(p);
    notifyListeners();
  }

  bool get canFinish => switch (_tool) {
    null => false,
    ShapeKind.polygon => points.length >= 3,
    ShapeKind.rectangle || ShapeKind.circle => points.length == 2,
    _ => points.length >= 2,
  };

  String get hint => _measure
      ? measureSummary
      : switch (_tool) {
          null => '',
          ShapeKind.line => 'Tap to add points',
          ShapeKind.freehand =>
            points.isEmpty ? 'Draw with your finger' : 'Draw again to replace',
          ShapeKind.polygon =>
            _geofence ? 'Tap the corners of the geofence' : 'Tap the corners',
          ShapeKind.rectangle =>
            points.isEmpty ? 'Tap one corner' : 'Tap the opposite corner',
          ShapeKind.circle =>
            points.isEmpty
                ? (_geofence
                      ? 'Tap the centre of the geofence'
                      : 'Tap the centre')
                : 'Tap the edge',
          ShapeKind.route =>
            points.isEmpty ? 'Tap the start' : 'Tap the next checkpoint',
        };

  /// The finished geometry: vertices and (for circles) the radius.
  (List<(double, double)>, int) geometry() {
    final t = _tool;
    if (t == ShapeKind.rectangle && points.length == 2) {
      final a = points[0], b = points[1];
      return (
        [
          (a.latitude, a.longitude),
          (a.latitude, b.longitude),
          (b.latitude, b.longitude),
          (b.latitude, a.longitude),
        ],
        0,
      );
    }
    if (t == ShapeKind.circle && points.length == 2) {
      final c = points[0], e = points[1];
      return (
        [(c.latitude, c.longitude)],
        teamDistanceMeters(
          c.latitude,
          c.longitude,
          e.latitude,
          e.longitude,
        ).round().clamp(1, 1 << 24),
      );
    }
    return ([for (final p in points) (p.latitude, p.longitude)], 0);
  }
}

// ---------------------------------------------------------- in-progress layer

/// Shows the shape being drawn. Put it in FlutterMap's children.
class TeamDrawLayer extends StatelessWidget {
  final TeamDrawController controller;
  const TeamDrawLayer({super.key, required this.controller});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final t = controller.tool;
      final pts = controller.points;
      if (t == null || pts.isEmpty) return const SizedBox.shrink();
      final color = controller.measure
          ? const Color(0xFFFF6D00)
          : const Color(0xFFFFEB3B);
      final (geo, radius) = controller.geometry();
      final ll = [for (final p in geo) LatLng(p.$1, p.$2)];
      return Stack(
        children: [
          if (t == ShapeKind.circle && pts.length == 2)
            CircleLayer(
              circles: [
                CircleMarker(
                  point: pts[0],
                  radius: radius.toDouble(),
                  useRadiusInMeter: true,
                  color: color.withValues(alpha: 0.15),
                  borderColor: color,
                  borderStrokeWidth: 2,
                ),
              ],
            )
          else if (t.closed && ll.length >= 3)
            PolygonLayer(
              polygons: [
                Polygon(
                  points: ll,
                  color: color.withValues(alpha: 0.15),
                  borderColor: color,
                  borderStrokeWidth: 2,
                ),
              ],
            )
          else if (ll.length >= 2)
            PolylineLayer(
              polylines: [
                Polyline(
                  points: ll,
                  color: color,
                  strokeWidth: t == ShapeKind.route ? 4 : 3,
                ),
              ],
            ),
          if (controller.measure)
            MarkerLayer(
              markers: [
                for (var i = 1; i < pts.length; i++)
                  Marker(
                    point: LatLng(
                      (pts[i - 1].latitude + pts[i].latitude) / 2,
                      (pts[i - 1].longitude + pts[i].longitude) / 2,
                    ),
                    width: 130,
                    height: 22,
                    child: IgnorePointer(
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black87,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            teamRangeBearing(
                              controller.legs[i - 1].$1,
                              controller.legs[i - 1].$2,
                            ),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          if (!controller.freehand)
            MarkerLayer(
              markers: [
                for (var i = 0; i < pts.length; i++)
                  Marker(
                    point: pts[i],
                    width: 22,
                    height: 22,
                    child: IgnorePointer(
                      child: Container(
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: Colors.black87,
                          shape: BoxShape.circle,
                          border: Border.all(color: color, width: 2),
                        ),
                        child: t == ShapeKind.route
                            ? Text(
                                '${i + 1}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 10,
                                ),
                              )
                            : null,
                      ),
                    ),
                  ),
              ],
            ),
        ],
      );
    },
  );
}

/// Captures a finger-drawn line. Put it over the map (Positioned.fill)
/// while the freehand tool is active; the map itself must not pan then.
class TeamFreehandCapture extends StatefulWidget {
  final TeamDrawController controller;
  final LatLng Function(Offset local) toLatLng;
  const TeamFreehandCapture({
    super.key,
    required this.controller,
    required this.toLatLng,
  });

  @override
  State<TeamFreehandCapture> createState() => _TeamFreehandCaptureState();
}

class _TeamFreehandCaptureState extends State<TeamFreehandCapture> {
  Offset? _last;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onPanStart: (d) {
      _last = d.localPosition;
      widget.controller.freehandStart(widget.toLatLng(d.localPosition));
    },
    onPanUpdate: (d) {
      final last = _last;
      if (last != null && (d.localPosition - last).distance < 6) return;
      _last = d.localPosition;
      widget.controller.freehandAdd(widget.toLatLng(d.localPosition));
    },
    onPanEnd: (_) => _last = null,
  );
}

/// Toolbar shown at the top of the map while drawing (wrap in Positioned).
class TeamDrawToolbar extends StatelessWidget {
  final TeamDrawController controller;
  final VoidCallback onDone;
  const TeamDrawToolbar({
    super.key,
    required this.controller,
    required this.onDone,
  });

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final t = controller.tool;
      if (t == null) return const SizedBox.shrink();
      final scheme = Theme.of(context).colorScheme;
      return SafeArea(
        bottom: false,
        child: Material(
          elevation: 6,
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
            child: Row(
              children: [
                Icon(
                  controller.measure
                      ? Icons.straighten
                      : shapeKindIcon(t, geofence: controller.geofence),
                  color: scheme.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        controller.measure
                            ? 'Range & bearing'
                            : controller.geofence
                            ? 'Geofence (${t.label.toLowerCase()})'
                            : t.label,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      Text(
                        controller.hint,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Undo',
                  icon: const Icon(Icons.undo),
                  onPressed: controller.points.isEmpty ? null : controller.undo,
                ),
                IconButton(
                  tooltip: controller.measure ? 'Close' : 'Cancel drawing',
                  icon: const Icon(Icons.close),
                  onPressed: controller.cancel,
                ),
                IconButton.filled(
                  tooltip: controller.measure ? 'Share as a line' : 'Done',
                  icon: Icon(
                    controller.measure ? Icons.ios_share : Icons.check,
                  ),
                  onPressed: controller.canFinish ? onDone : null,
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

// ----------------------------------------------------------------- editor

/// Names, colours and shares a drawn (or existing) shape.
Future<void> showTeamShapeEditor(
  BuildContext context, {
  required ShapeKind kind,
  required List<(double, double)> points,
  int radiusM = 0,
  bool geofence = false,
  TeamShape? existing,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  builder: (_) => _ShapeEditor(
    kind: kind,
    points: points,
    radiusM: radiusM,
    geofence: geofence,
    existing: existing,
  ),
);

class _ShapeEditor extends StatefulWidget {
  final ShapeKind kind;
  final List<(double, double)> points;
  final int radiusM;
  final bool geofence;
  final TeamShape? existing;
  const _ShapeEditor({
    required this.kind,
    required this.points,
    required this.radiusM,
    required this.geofence,
    this.existing,
  });

  @override
  State<_ShapeEditor> createState() => _ShapeEditorState();
}

class _ShapeEditorState extends State<_ShapeEditor> {
  late final _label = TextEditingController(text: widget.existing?.label ?? '');
  late TeamColor _color =
      widget.existing?.color ??
      (widget.geofence
          ? TeamColor.red
          : widget.kind == ShapeKind.route
          ? TeamColor.cyan
          : TeamColor.yellow);
  late TeamGeofence _fence =
      widget.existing?.geofence ??
      (widget.geofence ? TeamGeofence.entry : TeamGeofence.off);
  late RouteMethod _method =
      widget.existing?.routeMethod ?? RouteMethod.walking;
  bool _sending = false;

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  TeamShape get _preview => TeamShape(
    authorKey4: '00000000',
    shapeId: 0,
    kind: widget.kind,
    time: DateTime.now(),
    points: widget.points,
    radiusM: widget.radiusM,
  );

  Future<void> _save() async {
    final team = context.read<TeamService>();
    if (!team.active) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(team.inactiveReason ?? 'Team not ready')),
      );
      return;
    }
    setState(() => _sending = true);
    await team.putShape(
      existing: widget.existing,
      kind: widget.kind,
      points: widget.points,
      radiusM: widget.radiusM,
      color: _color,
      label: _label.text.trim(),
      geofence: widget.kind.closed ? _fence : TeamGeofence.off,
      routeMethod: _method,
    );
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final p = _preview;
    final measure = [
      if (widget.kind == ShapeKind.circle)
        'Radius ${teamFormatLength(widget.radiusM.toDouble())}'
      else
        '${widget.kind.closed ? 'Perimeter' : 'Length'} '
            '${teamFormatLength(p.lengthM)}',
      if (widget.kind.closed) 'Area ${teamFormatArea(p.areaM2)}',
      if (widget.kind == ShapeKind.route) '${widget.points.length} checkpoints',
    ].join(' · ');
    final title = widget.existing != null
        ? 'Edit ${widget.kind.label.toLowerCase()}'
        : _fence != TeamGeofence.off && widget.kind.closed
        ? 'New geofence'
        : 'New ${widget.kind.label.toLowerCase()}';
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        bottom: 12 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TeamSheetHeader(
              title: title,
              subtitle: measure,
              onClose: () => Navigator.pop(context),
            ),
            TextField(
              controller: _label,
              maxLength: teamMaxShapeLabelBytes,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            Text('Colour', style: t.labelLarge),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final c in TeamColor.values)
                  InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () => setState(() => _color = c),
                    child: Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        color: Color(c.argb),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: _color == c
                              ? Theme.of(context).colorScheme.primary
                              : Colors.black26,
                          width: _color == c ? 3 : 1,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            if (widget.kind.closed) ...[
              const SizedBox(height: 14),
              Text('Geofence alert', style: t.labelLarge),
              const SizedBox(height: 6),
              SegmentedButton<TeamGeofence>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: TeamGeofence.off, label: Text('Off')),
                  ButtonSegment(
                    value: TeamGeofence.entry,
                    label: Text('Entry'),
                  ),
                  ButtonSegment(value: TeamGeofence.exit, label: Text('Exit')),
                  ButtonSegment(value: TeamGeofence.both, label: Text('Both')),
                ],
                selected: {_fence},
                onSelectionChanged: (s) => setState(() => _fence = s.first),
              ),
              if (_fence != TeamGeofence.off)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'Every teammate\'s phone alerts when anyone on the team '
                    '(including you) ${switch (_fence) {
                      TeamGeofence.entry => 'enters',
                      TeamGeofence.exit => 'leaves',
                      _ => 'enters or leaves',
                    }} this area. No extra airtime.',
                    style: t.bodySmall,
                  ),
                ),
            ],
            if (widget.kind == ShapeKind.route) ...[
              const SizedBox(height: 14),
              Text('Travel', style: t.labelLarge),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                children: [
                  for (final m in RouteMethod.values)
                    ChoiceChip(
                      label: Text(m.label),
                      selected: _method == m,
                      onSelected: (_) => setState(() => _method = m),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 16),
            TeamSheetActions(
              onCancel: () => Navigator.pop(context),
              submitLabel: widget.existing == null
                  ? 'Share with team'
                  : 'Update',
              onSubmit: _sending ? null : _save,
            ),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ sheet

/// Rough travel time for a route.
String routeEta(TeamShape r) {
  final kmh = switch (r.routeMethod) {
    RouteMethod.walking => 4.5,
    RouteMethod.driving => 40.0,
    RouteMethod.flying => 150.0,
    RouteMethod.swimming => 2.0,
    RouteMethod.watercraft => 20.0,
  };
  final minutes = (r.lengthM / 1000 / kmh * 60).round();
  if (minutes < 60) {
    return '≈ $minutes min ${r.routeMethod.label.toLowerCase()}';
  }
  return '≈ ${minutes ~/ 60} h ${minutes % 60} min '
      '${r.routeMethod.label.toLowerCase()}';
}

Future<void> showTeamShapeSheet(BuildContext context, TeamShape s) =>
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (c) {
        final team = c.watch<TeamService>();
        final mine = team.isMyShape(s);
        final author = mine
            ? 'You'
            : team.memberByKey(s.authorKey4)?.callsign ??
                  s.authorKey4.toUpperCase();
        final events = [
          for (final e in team.geofenceEvents)
            if (e.fence == s.title) e,
        ].take(5);
        final fix = team.fix;
        final (alat, alon) = s.anchor;
        return SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ListTile(
                  leading: Icon(
                    shapeKindIcon(s.kind, geofence: s.isGeofence),
                    color: Color(s.color.argb),
                    size: 32,
                  ),
                  title: Text(s.title),
                  subtitle: Text(
                    [
                      s.isGeofence
                          ? 'Geofence · ${s.geofence.label}'
                          : s.kind.label,
                      author,
                      _ago(s.time),
                    ].join(' · '),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    [
                      if (s.kind == ShapeKind.circle)
                        'Radius ${teamFormatLength(s.radiusM.toDouble())}'
                      else
                        '${s.kind.closed ? 'Perimeter' : 'Length'} '
                            '${teamFormatLength(s.lengthM)}',
                      if (s.kind.closed) 'Area ${teamFormatArea(s.areaM2)}',
                      if (s.kind == ShapeKind.route) ...[
                        '${s.points.length} checkpoints',
                        routeEta(s),
                      ],
                      if (fix != null)
                        teamRangeBearing(
                          teamDistanceMeters(fix.lat, fix.lon, alat, alon),
                          teamBearingDeg(fix.lat, fix.lon, alat, alon),
                        ),
                    ].join(' · '),
                  ),
                ),
                if (s.isGeofence && fix != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                    child: Text(
                      s.contains(fix.lat, fix.lon)
                          ? 'You are inside.'
                          : 'You are outside.',
                    ),
                  ),
                for (final e in events)
                  ListTile(
                    dense: true,
                    leading: Icon(e.entered ? Icons.login : Icons.logout),
                    title: Text(e.headline),
                    subtitle: Text(_ago(e.time)),
                  ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (s.kind == ShapeKind.route) ...[
                        FilledButton.icon(
                          icon: const Icon(Icons.navigation),
                          label: const Text('Navigate'),
                          onPressed: () {
                            team.navigateRoute(s);
                            Navigator.pop(c);
                          },
                        ),
                        OutlinedButton.icon(
                          icon: const Icon(Icons.swap_horiz),
                          label: const Text('Navigate reversed'),
                          onPressed: () {
                            team.navigateRoute(s, reverse: true);
                            Navigator.pop(c);
                          },
                        ),
                      ] else
                        OutlinedButton.icon(
                          icon: const Icon(Icons.track_changes),
                          label: const Text('Bloodhound'),
                          onPressed: () {
                            team.houndPoint(alat, alon, s.title);
                            Navigator.pop(c);
                          },
                        ),
                      if (mine)
                        OutlinedButton.icon(
                          icon: const Icon(Icons.edit_outlined),
                          label: const Text('Edit'),
                          onPressed: () {
                            Navigator.pop(c);
                            showTeamShapeEditor(
                              context,
                              kind: s.kind,
                              points: s.points,
                              radiusM: s.radiusM,
                              existing: s,
                            );
                          },
                        ),
                      OutlinedButton.icon(
                        icon: const Icon(Icons.delete_outline),
                        label: Text(mine ? 'Delete for team' : 'Remove here'),
                        onPressed: () {
                          unawaited(team.deleteShape(s));
                          Navigator.pop(c);
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        );
      },
    );

String _ago(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 24) return '${d.inHours} h ago';
  return '${d.inDays} d ago';
}

/// Picks a drawing tool.
Future<ShapeKind?> showDrawToolPicker(BuildContext context) =>
    showModalBottomSheet<ShapeKind>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              title: Text('Draw'),
              subtitle: Text('Shared with your team and TAK.'),
            ),
            for (final k in [
              ShapeKind.line,
              ShapeKind.freehand,
              ShapeKind.polygon,
              ShapeKind.rectangle,
              ShapeKind.circle,
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
