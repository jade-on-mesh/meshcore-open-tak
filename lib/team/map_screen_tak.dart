// MeshCore Open TAK - everything the fork adds to the Map screen.
//
// lib/screens/map_screen.dart is MeshCore Open's file, and upstream changes it
// often. Every line the fork adds there is a line an upstream release can
// conflict with (issue #8), so the fork's map features live here instead and
// map_screen.dart only calls in at a handful of one-line hooks:
//
//   state       final _tak = MapScreenTak(...)        dispose: _tak.dispose()
//   app bar     ..._tak.appBarActions(context)
//   gestures    flags: _tak.interactionFlags(...)
//               onTap: if (_tak.onTap(latLng)) return;
//               onLongPress: if (_tak.drawing) return;
//               long-press sheet: if (_tak.contextPress(...)) return;
//   layers      ..._tak.layers(onGoToTap: ...)
//   overlays    ..._tak.overlays(context, showTeamOverlay: ...)
//               if (_tak.chatOpen) _tak.chatPane()
//   conditions  !_tak.drawing (top overlay), !_tak.chatOpen (filter FAB)
//
// Keep it that way: new map features go in here (or another lib/team file),
// not in map_screen.dart.

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import 'map_chat_pane.dart';
import 'map_tools.dart';
import 'team_draw.dart';
import 'team_map.dart';
import 'team_service.dart';

class MapScreenTak {
  final MapController mapController;

  /// Rebuilds the map screen (its setState).
  final VoidCallback onChanged;

  final TeamDrawController draw = TeamDrawController();

  bool _chatOpen = false;
  LatLng? _goTo;

  MapScreenTak({required this.mapController, required this.onChanged}) {
    draw.addListener(onChanged);
  }

  void dispose() {
    draw
      ..removeListener(onChanged)
      ..dispose();
  }

  bool get chatOpen => _chatOpen;

  /// Drawing or measuring: the map's own gestures and overlays step aside.
  bool get drawing => draw.active;

  void toggleChat() {
    _chatOpen = !_chatOpen;
    onChanged();
  }

  /// Freehand drawing takes the drag gesture away from the map.
  int interactionFlags(int normal) =>
      draw.freehand ? InteractiveFlag.none : normal;

  /// A map tap the fork handles. True means the screen should do nothing more.
  bool onTap(LatLng at) {
    if (draw.active) {
      draw.tap(at);
      return true;
    }
    if (_goTo != null) {
      _goTo = null;
      onChanged();
    }
    return false;
  }

  /// Long press / right click: with Team on, the team action sheet (which
  /// still offers the screen's own "share marker"). True if it was shown.
  bool contextPress(
    BuildContext context,
    LatLng at, {
    required VoidCallback shareMarker,
  }) {
    bool enabled;
    try {
      enabled = context.read<TeamService>().enabled;
    } on ProviderNotFoundException {
      enabled = false;
    }
    if (!enabled) return false;
    showTeamMapActions(context, at, shareMarker: shareMarker);
    return true;
  }

  List<Widget> appBarActions(BuildContext context) => [
    MapChatButton(open: _chatOpen, onPressed: toggleChat),
    IconButton(
      tooltip: 'Tools',
      icon: const Icon(Icons.apps),
      onPressed: () => showMapTools(
        context,
        onChat: () {
          if (!_chatOpen) toggleChat();
        },
        onDraw: (kind, geofence) => draw.start(kind, geofence: geofence),
        onMeasure: () => _startMeasure(context),
        onGoTo: (p) {
          _goTo = p;
          onChanged();
          mapController.move(p, max(mapController.camera.zoom, 15.0));
        },
        mapCenter: mapController.camera.center,
        mapArea: mapController.camera.visibleBounds,
      ),
    ),
  ];

  /// Map layers: team positions, shapes, drones and watch pins; the drawing
  /// in progress; the "Go to" target.
  List<Widget> layers({required ValueChanged<LatLng> onGoToTap}) {
    final goTo = _goTo;
    return [
      const TeamMapLayer(),
      TeamDrawLayer(controller: draw),
      if (goTo != null)
        MarkerLayer(
          markers: [
            Marker(
              point: goTo,
              width: 48,
              height: 48,
              child: GestureDetector(
                onTap: () => onGoToTap(goTo),
                child: const Icon(
                  Icons.gps_fixed,
                  size: 40,
                  color: Color(0xFFFF6D00),
                ),
              ),
            ),
          ],
        ),
    ];
  }

  /// Widgets over the map: the team overlay and the drawing toolbar and
  /// capture surface.
  List<Widget> overlays(BuildContext context, {required bool showTeamOverlay}) {
    return [
      if (showTeamOverlay && !draw.active) const TeamMapOverlay(),
      if (draw.freehand)
        Positioned.fill(
          child: TeamFreehandCapture(
            controller: draw,
            toLatLng: (o) => mapController.camera.screenOffsetToLatLng(o),
          ),
        ),
      if (draw.active)
        Positioned(
          left: 8,
          right: 8,
          top: 8,
          child: TeamDrawToolbar(
            controller: draw,
            onDone: () => _finishDraw(context),
          ),
        ),
    ];
  }

  /// The chat pane, over everything else: docked at the side in landscape and
  /// along the bottom in portrait, like ATAK's chat drawer. It floats over
  /// the map rather than shrinking it, so map_screen.dart's layout stays
  /// upstream's.
  Widget chatPane() => Positioned.fill(child: _chatPaneBody());

  Widget _chatPaneBody() => LayoutBuilder(
    builder: (context, box) {
      final side = box.maxWidth > box.maxHeight || box.maxWidth >= 720;
      final pane = Material(
        elevation: 8,
        color: Theme.of(context).colorScheme.surface,
        child: MapChatPane(
          side: side,
          onClose: toggleChat,
          onLocate: (p) =>
              mapController.move(p, max(mapController.camera.zoom, 15.0)),
        ),
      );
      return Align(
        alignment: side ? Alignment.centerRight : Alignment.bottomCenter,
        child: SizedBox(
          width: side ? min(400.0, box.maxWidth * 0.42) : box.maxWidth,
          height: side ? box.maxHeight : box.maxHeight * 0.45,
          child: pane,
        ),
      );
    },
  );

  void _startMeasure(BuildContext context) {
    LatLng? from;
    try {
      final f = context.read<TeamService>().fix;
      if (f != null) from = LatLng(f.lat, f.lon);
    } on ProviderNotFoundException {
      from = null;
    }
    draw.startMeasure(from: from);
  }

  void _finishDraw(BuildContext context) {
    final kind = draw.tool;
    if (kind == null || !draw.canFinish) return;
    final (points, radius) = draw.geometry();
    final geofence = draw.geofence;
    draw.cancel();
    showTeamShapeEditor(
      context,
      kind: kind,
      points: points,
      radiusM: radius,
      geofence: geofence,
    );
  }
}
