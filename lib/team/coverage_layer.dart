// MeshCore Open TAK - MediaMesh coverage on the map (mediamesh_coverage.dart):
// a dot per sample, coloured by how well MediaMesh reaches there. The same
// colours as Wadamesh TAK's coverage dots. Tapping a dot shows the MediaMesh
// repeaters heard there.

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
import '../services/mediamesh_coverage.dart';
import '../widgets/mesh_ui.dart';

/// The colour for each reach (shared with Wadamesh TAK).
Color coverageColor(MediaMeshReach r) => switch (r) {
  MediaMeshReach.good => const Color(0xFF22C55E),
  MediaMeshReach.marginal => const Color(0xFFF59E0B),
  MediaMeshReach.out => const Color(0xFFEF4444),
  MediaMeshReach.none => const Color(0xFF6B7280),
};

/// On a coverage dot, a long press that drops a pin, opens SALUTE and the
/// rest of the map's press menu has to be held this long (counted from the
/// touch): there a shorter press means the dot. Elsewhere the map's usual
/// long press stands.
const Duration coverageDropHold = Duration(milliseconds: 1200);

/// The coverage dot under [point] (on screen, relative to the map) for
/// [camera], nearest first, or null: none shown there.
CoverageSample? coverageSampleAt(
  BuildContext context,
  MapCamera camera,
  Offset point,
) {
  MediaMeshCoverageService cov;
  try {
    cov = context.read<MediaMeshCoverageService>();
  } on ProviderNotFoundException {
    return null;
  }
  if (!cov.show) return null;
  const reach = MediaMeshCoverageLayer.hitRadius;
  CoverageSample? best;
  var bestD = reach * reach;
  for (final s in cov.samples) {
    final at = camera.latLngToScreenOffset(LatLng(s.lat, s.lon));
    final d = (at - point).distanceSquared;
    if (d <= bestD) {
      bestD = d;
      best = s;
    }
  }
  return best;
}

class MediaMeshCoverageLayer extends StatelessWidget {
  const MediaMeshCoverageLayer({super.key});

  /// The dot's size, and the finger-sized area around it that takes a tap.
  static const double _dot = 12;
  static const double _hit = 28;
  static const double hitRadius = _hit / 2;

  @override
  Widget build(BuildContext context) {
    MediaMeshCoverageService cov;
    try {
      cov = context.watch<MediaMeshCoverageService>();
    } on ProviderNotFoundException {
      return const SizedBox.shrink();
    }
    if (!cov.show || cov.samples.isEmpty) return const SizedBox.shrink();
    return MarkerLayer(
      markers: [
        for (final s in cov.samples)
          Marker(
            point: LatLng(s.lat, s.lon),
            width: _hit,
            height: _hit,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => showCoveragePoint(context, s),
              child: Center(
                child: Container(
                  width: _dot,
                  height: _dot,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: coverageColor(s.reach).withValues(alpha: 0.85),
                    border: Border.all(color: Colors.black54),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// What was heard at one coverage point: when, and each MediaMesh repeater
/// that answered there, best first, with its margin and SNRs.
Future<void> showCoveragePoint(BuildContext context, CoverageSample s) {
  return showMeshSheet<void>(
    context,
    builder: (ctx) {
      final l10n = ctx.l10n;
      final theme = Theme.of(ctx);
      final scheme = theme.colorScheme;
      final locale = Localizations.localeOf(ctx).toString();
      final when = DateFormat.yMMMd(locale).add_jm().format(s.time.toLocal());
      final reps = [...s.repeaters]
        ..sort((a, b) => b.margin.compareTo(a.margin));
      String db(double v) => v.toStringAsFixed(1);
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          BottomSheetHeader(
            title: l10n.coverage_pointTitle,
            subtitle: l10n.coverage_pointWhen(when),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              children: [
                if (reps.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      l10n.coverage_pointNone,
                      style: theme.textTheme.bodyMedium,
                    ),
                  )
                else ...[
                  Text(
                    l10n.coverage_pointRepeaters(reps.length),
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: 4),
                  for (final r in reps)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Container(
                        width: 14,
                        height: 14,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: coverageColor(mediaMeshReachFor(r.margin)),
                          border: Border.all(color: Colors.black54),
                        ),
                      ),
                      minLeadingWidth: 14,
                      title: Text(
                        r.name == r.key ? r.key : '${r.name} (${r.key})',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${l10n.coverage_pointMargin(db(r.margin))}\n'
                        '${l10n.coverage_pointSnr(db(r.snr), db(r.remoteSnr))}',
                      ),
                      isThreeLine: true,
                    ),
                  const SizedBox(height: 4),
                  Text(
                    l10n.coverage_pointHelp,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      );
    },
  );
}
