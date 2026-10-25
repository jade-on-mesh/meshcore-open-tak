// MeshCore Open TAK - the MediaMesh coverage controls (MediaMesh settings):
// record, show on the map, export, clear (mediamesh_coverage.dart).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
import '../services/mediamesh_coverage.dart';
import '../team/coverage_layer.dart';

class MediaMeshCoverageTile extends StatelessWidget {
  const MediaMeshCoverageTile({super.key});

  @override
  Widget build(BuildContext context) {
    MediaMeshCoverageService cov;
    try {
      cov = context.watch<MediaMeshCoverageService>();
    } on ProviderNotFoundException {
      return const SizedBox.shrink();
    }
    final l10n = context.l10n;
    final small = Theme.of(context).textTheme.bodySmall;
    final labels = {
      MediaMeshReach.good: l10n.coverage_good,
      MediaMeshReach.marginal: l10n.coverage_marginal,
      MediaMeshReach.out: l10n.coverage_out,
      MediaMeshReach.none: l10n.coverage_none,
    };
    final counts = {for (final r in MediaMeshReach.values) r: 0};
    for (final s in cov.samples) {
      counts[s.reach] = counts[s.reach]! + 1;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          l10n.coverage_title,
          style: Theme.of(context).textTheme.titleSmall,
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: Icon(
            cov.recording ? Icons.fiber_manual_record : Icons.route_outlined,
            color: cov.recording ? Colors.red : null,
          ),
          title: Text(l10n.coverage_record),
          subtitle: Text(
            cov.problem ??
                (cov.asking ? l10n.coverage_asking : l10n.coverage_recordHelp),
          ),
          value: cov.recording,
          onChanged: (v) => unawaited(cov.setRecording(v)),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: const Icon(Icons.layers_outlined),
          title: Text(l10n.coverage_show),
          subtitle: Text(l10n.coverage_points(cov.samples.length)),
          value: cov.show,
          onChanged: (v) => unawaited(cov.setShow(v)),
        ),
        Wrap(
          spacing: 12,
          runSpacing: 4,
          children: [
            for (final r in MediaMeshReach.values)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.circle, size: 12, color: coverageColor(r)),
                  const SizedBox(width: 4),
                  Text('${labels[r]} ${counts[r]}', style: small),
                ],
              ),
          ],
        ),
        const SizedBox(height: 4),
        Text(l10n.coverage_help, style: small),
        Row(
          children: [
            TextButton.icon(
              icon: const Icon(Icons.ios_share),
              label: Text(l10n.coverage_export),
              onPressed: cov.samples.isEmpty
                  ? null
                  : () => unawaited(cov.export()),
            ),
            TextButton.icon(
              icon: const Icon(Icons.delete_outline),
              label: Text(l10n.coverage_clear),
              onPressed: cov.samples.isEmpty || cov.recording
                  ? null
                  : () => unawaited(cov.clear()),
            ),
          ],
        ),
      ],
    );
  }
}
