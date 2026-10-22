// MeshCore Open TAK - MediaMesh coverage on the map (mediamesh_coverage.dart):
// a dot per sample, coloured by how well MediaMesh reaches there. The same
// colours as Wadamesh TAK's coverage dots.

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../services/mediamesh_coverage.dart';

/// The colour for each reach (shared with Wadamesh TAK).
Color coverageColor(MediaMeshReach r) => switch (r) {
  MediaMeshReach.good => const Color(0xFF22C55E),
  MediaMeshReach.marginal => const Color(0xFFF59E0B),
  MediaMeshReach.out => const Color(0xFFEF4444),
  MediaMeshReach.none => const Color(0xFF6B7280),
};

class MediaMeshCoverageLayer extends StatelessWidget {
  const MediaMeshCoverageLayer({super.key});

  @override
  Widget build(BuildContext context) {
    MediaMeshCoverageService cov;
    try {
      cov = context.watch<MediaMeshCoverageService>();
    } on ProviderNotFoundException {
      return const SizedBox.shrink();
    }
    if (!cov.show || cov.samples.isEmpty) return const SizedBox.shrink();
    return CircleLayer(
      circles: [
        for (final s in cov.samples)
          CircleMarker(
            point: LatLng(s.lat, s.lon),
            radius: 6,
            color: coverageColor(s.reach).withValues(alpha: 0.85),
            borderColor: Colors.black54,
            borderStrokeWidth: 1,
          ),
      ],
    );
  }
}
