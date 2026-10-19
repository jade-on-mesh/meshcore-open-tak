import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../services/media_mesh_nearby.dart';

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

  @override
  Widget build(BuildContext context) {
    final at = _nearby.heardAt;
    final ago = at == null ? null : DateTime.now().difference(at);
    final lit = ago != null && ago < MediaMeshNearby.window;
    if (!lit && !_nearby.listening) return const SizedBox.shrink();
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final String message;
    if (lit) {
      final mins = ago!.inMinutes;
      message = mins < 1
          ? l10n.mediaMeshNearby_heardNow
          : l10n.mediaMeshNearby_heardAgo(mins);
    } else {
      message = l10n.mediaMeshNearby_listening;
    }
    final icon = Icon(
      Icons.cell_tower,
      size: widget.compact ? 16 : 20,
      color: lit
          ? scheme.primary
          : scheme.onSurfaceVariant.withValues(alpha: 0.45),
    );
    return Tooltip(
      message: message,
      triggerMode: TooltipTriggerMode.tap,
      child: Semantics(
        label: message,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: widget.compact ? 2 : 6),
          child: icon,
        ),
      ),
    );
  }
}
