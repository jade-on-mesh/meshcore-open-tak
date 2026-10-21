// MeshCore Open TAK - auto-zoom: the map follows the newest watched report.
//
// With auto-zoom on (WatchFeedService.autoZoom: the map's app-bar button or
// the Watch tab's chip), each watched report with a position that arrives
// live moves the map to it, zoomed in, and lights it up like "Show on map".
// History (a channel's backlog, reports older than 30 minutes or past the map
// time) never moves the map.

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import 'watch_feed.dart';

/// The closest the map zooms out to when it jumps to a report.
const double watchAutoZoomLevel = 15;

/// Moves [mapController] to [item] (zoomed in) and lights it up.
void watchZoomTo(
  MapController mapController,
  WatchFeedService feed,
  WatchItem item,
) {
  if (!item.hasPosition) return;
  try {
    final zoom = max(mapController.camera.zoom, watchAutoZoomLevel);
    mapController.move(LatLng(item.lat!, item.lon!), zoom);
  } catch (_) {
    return; // the map isn't laid out yet
  }
  feed.focusOnMap(item);
}

/// Invisible: listens for new watched reports while the map is open.
class WatchAutoZoom extends StatefulWidget {
  final MapController mapController;

  /// True while the map shouldn't move (drawing or measuring).
  final bool Function() paused;

  const WatchAutoZoom({
    super.key,
    required this.mapController,
    required this.paused,
  });

  @override
  State<WatchAutoZoom> createState() => _WatchAutoZoomState();
}

class _WatchAutoZoomState extends State<WatchAutoZoom> {
  WatchFeedService? _feed;

  @override
  void initState() {
    super.initState();
    try {
      _feed = context.read<WatchFeedService>();
      _feed!.latestArrival.addListener(_onArrival);
    } on ProviderNotFoundException {
      _feed = null;
    }
  }

  void _onArrival() {
    final feed = _feed;
    final item = feed?.latestArrival.value;
    if (!mounted || feed == null || item == null) return;
    if (!feed.autoZoom || widget.paused()) return;
    watchZoomTo(widget.mapController, feed, item);
  }

  @override
  void dispose() {
    _feed?.latestArrival.removeListener(_onArrival);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// The map's app-bar toggle, shown while any channel is watched. Turning it
/// on also jumps to the newest report on the map.
class WatchAutoZoomButton extends StatelessWidget {
  final MapController mapController;
  const WatchAutoZoomButton({super.key, required this.mapController});

  @override
  Widget build(BuildContext context) {
    WatchFeedService feed;
    try {
      feed = context.watch<WatchFeedService>();
    } on ProviderNotFoundException {
      return const SizedBox.shrink();
    }
    if (feed.watchedNames.isEmpty) return const SizedBox.shrink();
    final on = feed.autoZoom;
    return IconButton(
      tooltip: on
          ? 'Auto-zoom to new watched reports: on'
          : 'Auto-zoom to new watched reports: off',
      isSelected: on,
      icon: const Icon(Icons.center_focus_weak),
      selectedIcon: Icon(
        Icons.center_focus_strong,
        color: Theme.of(context).colorScheme.primary,
      ),
      onPressed: () {
        final turnOn = !on;
        feed.setAutoZoom(turnOn);
        final messenger = ScaffoldMessenger.of(context);
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 2),
            content: Text(
              turnOn
                  ? 'Auto-zoom on: the map follows new watched reports'
                  : 'Auto-zoom off',
            ),
          ),
        );
        if (turnOn) {
          final items = feed.mapItems;
          if (items.isNotEmpty) watchZoomTo(mapController, feed, items.first);
        }
      },
    );
  }
}
