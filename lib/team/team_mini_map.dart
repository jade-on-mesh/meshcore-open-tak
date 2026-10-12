// MeshCore Open TAK - a small team map for the Pins and Reports tabs, so pins
// and reports can be seen and dropped without leaving the list.

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../screens/map_screen.dart';
import '../services/map_tile_cache_service.dart';
import '../storage/prefs_manager.dart';
import 'team_map.dart';
import 'team_service.dart';

/// Map with the team layer (teammates, pins, reports, alerts) that frames
/// [points] (plus my position) and calls [onDrop] for a long-press or the
/// crosshair button. Control it with [controller] to show a list item.
class TeamMiniMap extends StatefulWidget {
  final MapController controller;
  final List<LatLng> points;
  final String dropLabel;
  final IconData dropIcon;
  final void Function(LatLng at) onDrop;

  const TeamMiniMap({
    super.key,
    required this.controller,
    required this.points,
    required this.dropLabel,
    required this.dropIcon,
    required this.onDrop,
  });

  @override
  State<TeamMiniMap> createState() => _TeamMiniMapState();
}

class _TeamMiniMapState extends State<TeamMiniMap> {
  bool _ready = false;
  bool _framed = false; // framed the points at least once
  bool _userMoved = false;

  List<LatLng> _frame(TeamService team) {
    final fix = team.fix;
    return [...widget.points, if (fix != null) LatLng(fix.lat, fix.lon)];
  }

  ({LatLng center, double zoom}) _fallback() {
    // Where the big map was last left, else the whole world.
    final saved = PrefsManager.instance.getStringList('map_last_camera');
    if (saved != null && saved.length == 3) {
      final v = saved.map(double.tryParse).toList();
      if (!v.contains(null)) {
        return (center: LatLng(v[0]!, v[1]!), zoom: v[2]!);
      }
    }
    return (center: const LatLng(20, 0), zoom: 2);
  }

  CameraFit? _fitFor(List<LatLng> pts) {
    if (pts.isEmpty) return null;
    if (pts.length == 1) {
      return CameraFit.coordinates(
        coordinates: [pts.first, pts.first],
        maxZoom: 15,
      );
    }
    return CameraFit.coordinates(
      coordinates: pts,
      padding: const EdgeInsets.all(36),
      maxZoom: 16,
    );
  }

  void _reframe(TeamService team) {
    final fit = _fitFor(_frame(team));
    if (fit == null || !_ready) return;
    widget.controller.fitCamera(fit);
    _framed = true;
    _userMoved = false;
  }

  void _drop(BuildContext context, LatLng at) {
    final team = context.read<TeamService>();
    if (!team.active) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Turn on team mode and pick a team channel in Setup.'),
        ),
      );
      return;
    }
    widget.onDrop(at);
  }

  @override
  Widget build(BuildContext context) {
    final team = context.watch<TeamService>();
    final tiles = context.read<MapTileCacheService>();
    final pts = _frame(team);
    final fit = _fitFor(pts);
    final fb = _fallback();
    final scheme = Theme.of(context).colorScheme;

    // The list was empty when the map opened and now has something: frame it,
    // unless the user has already moved the map themselves.
    if (_ready && !_framed && !_userMoved && fit != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_framed && !_userMoved) _reframe(team);
      });
    }

    return ClipRect(
      child: Stack(
        children: [
          FlutterMap(
            mapController: widget.controller,
            options: MapOptions(
              initialCenter: fb.center,
              initialZoom: fb.zoom,
              initialCameraFit: fit,
              minZoom: 2,
              maxZoom: 18,
              interactionOptions: const InteractionOptions(
                flags: ~InteractiveFlag.rotate,
              ),
              onMapReady: () {
                _ready = true;
                _framed = fit != null;
              },
              onPositionChanged: (_, hasGesture) {
                if (hasGesture) _userMoved = true;
              },
              onLongPress: (_, at) => _drop(context, at),
              onSecondaryTap: (_, at) => _drop(context, at),
            ),
            children: [tiles.buildTileLayer(context), const TeamMapLayer()],
          ),
          // Crosshair at the centre: pan to the spot, then press the button.
          IgnorePointer(
            child: Center(
              child: Icon(
                Icons.add,
                size: 28,
                color: scheme.primary.withValues(alpha: 0.8),
                shadows: const [Shadow(blurRadius: 3, color: Colors.black54)],
              ),
            ),
          ),
          Positioned(
            left: 8,
            top: 8,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: scheme.surface.withValues(alpha: 0.85),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Text(
                    'Hold the map, or aim the + and tap the button',
                    style: TextStyle(fontSize: 11),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            right: 8,
            top: 8,
            child: Column(
              children: [
                _MapIconButton(
                  icon: Icons.open_in_full,
                  tooltip: 'Open full map',
                  onPressed: () {
                    LatLng? c;
                    double? z;
                    try {
                      c = widget.controller.camera.center;
                      z = widget.controller.camera.zoom;
                    } catch (_) {}
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) =>
                            MapScreen(focusPosition: c, focusZoom: z ?? 15),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 6),
                _MapIconButton(
                  icon: Icons.fit_screen_outlined,
                  tooltip: 'Show everything',
                  onPressed: pts.isEmpty ? null : () => _reframe(team),
                ),
                const SizedBox(height: 6),
                _MapIconButton(
                  icon: Icons.my_location,
                  tooltip: 'My position',
                  onPressed: team.fix == null
                      ? null
                      : () {
                          _userMoved = true;
                          widget.controller.move(
                            LatLng(team.fix!.lat, team.fix!.lon),
                            15,
                          );
                        },
                ),
              ],
            ),
          ),
          Positioned(
            right: 8,
            bottom: 8,
            child: FilledButton.icon(
              icon: Icon(widget.dropIcon),
              label: Text(widget.dropLabel),
              onPressed: () {
                try {
                  _drop(context, widget.controller.camera.center);
                } catch (_) {}
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _MapIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  const _MapIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.9),
    shape: const CircleBorder(),
    elevation: 2,
    child: IconButton(
      visualDensity: VisualDensity.compact,
      icon: Icon(icon, size: 20),
      tooltip: tooltip,
      onPressed: onPressed,
    ),
  );
}

/// The map's height on the Pins and Reports tabs: a good share of the screen,
/// leaving room for the list underneath.
double teamMiniMapHeight(BuildContext context) {
  final h = MediaQuery.sizeOf(context).height;
  return (h * 0.38).clamp(200.0, 360.0);
}

/// Pan the mini map to a list item without changing a closer zoom.
void teamMiniMapShow(MapController c, double lat, double lon) {
  try {
    c.move(LatLng(lat, lon), c.camera.zoom < 14 ? 14 : c.camera.zoom);
  } catch (_) {}
}
