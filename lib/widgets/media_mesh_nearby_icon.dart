import 'dart:async';

import 'package:flutter/material.dart';

import 'package:provider/provider.dart';

import '../connector/meshcore_connector.dart';
import '../l10n/l10n.dart';
import '../services/media_mesh_nearby.dart';
import 'media_mesh_settings_dialog.dart';

/// A small antenna: lit when a MediaMesh was heard here in the last two
/// hours, dim while the radio's radio2 listens, hidden otherwise.
class MediaMeshNearbyIcon extends StatefulWidget {
  final bool compact;

  const MediaMeshNearbyIcon({super.key, this.compact = false});

  @override
  State<MediaMeshNearbyIcon> createState() => _MediaMeshNearbyIconState();
}

class _MediaMeshNearbyIconState extends State<MediaMeshNearbyIcon> {
  final MediaMeshNearby _nearby = MediaMeshNearby.instance;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _nearby.addListener(_changed);
    // Ages the "heard N min ago" text and goes dark when two hours pass.
    _tick = Timer.periodic(const Duration(minutes: 1), (_) => _changed());
  }

  @override
  void dispose() {
    _tick?.cancel();
    _nearby.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _open() {
    final connector = context.read<MeshCoreConnector>();
    if (!connector.isConnected) return;
    showDialog<void>(
      context: context,
      builder: (_) => MediaMeshSettingsDialog(connector: connector),
    );
  }

  @override
  Widget build(BuildContext context) {
    final at = _nearby.heardAt;
    final ago = at == null ? null : DateTime.now().difference(at);
    final lit = ago != null && ago < MediaMeshNearby.window;
    // Shown whenever the radio has MediaMesh (so it can be found and tapped),
    // or a MediaMesh was heard in the last two hours.
    if (!lit && !_nearby.supported) return const SizedBox.shrink();
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final String message;
    final Color color;
    if (lit) {
      final mins = ago!.inMinutes;
      message = mins < 1
          ? l10n.mediaMeshNearby_heardNow
          : l10n.mediaMeshNearby_heardAgo(mins);
      color = scheme.primary;
    } else if (_nearby.listening) {
      message = l10n.mediaMeshNearby_listening;
      color = scheme.onSurface.withValues(alpha: 0.55);
    } else {
      message = l10n.mediaMeshNearby_off;
      color = scheme.onSurface.withValues(alpha: 0.3);
    }
    return Tooltip(
      message: message,
      child: Semantics(
        label: message,
        button: true,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: _open,
          child: Padding(
            padding: EdgeInsets.all(widget.compact ? 2 : 8),
            child: Icon(
              Icons.cell_tower,
              size: widget.compact ? 16 : 22,
              color: color,
            ),
          ),
        ),
      ),
    );
  }
}
