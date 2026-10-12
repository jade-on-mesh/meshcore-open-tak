// MeshCore Open TAK - Data Package tool: export the team map as an ATAK
// data package, or import one (map items, or a TAK Server connection).

import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import 'tak/cot.dart';
import 'tak/data_package.dart';
import 'tak/tak_service.dart';
import 'team_service.dart';
import 'team_wire.dart';

/// Every team item as (uid, CoT XML).
List<(String, String)> teamCotItems(TeamService team) {
  final xml = <String>[
    for (final m in team.markers) cotForMarker(m),
    for (final r in team.reports) cotForReport(r),
    for (final c in team.casevacs) cotForCasevac(c),
    for (final s in team.shapes) cotForShape(s),
  ];
  return [
    for (final x in xml)
      if (parseCot(x) case final e?) (e.uid, x),
  ];
}

Future<void> showDataPackageSheet(BuildContext context) =>
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              title: Text('Data packages'),
              subtitle: Text('Swap map items with ATAK, WinTAK and iTAK.'),
            ),
            ListTile(
              leading: const Icon(Icons.unarchive_outlined),
              title: const Text('Export team map'),
              subtitle: const Text(
                'Pins, reports, CASEVACs, routes and drawings as a .zip '
                'that TAK apps import.',
              ),
              onTap: () {
                Navigator.pop(c);
                unawaited(_export(context));
              },
            ),
            ListTile(
              leading: const Icon(Icons.archive_outlined),
              title: const Text('Import a data package'),
              subtitle: const Text(
                'Map items, or a TAK Server connection package.',
              ),
              onTap: () {
                Navigator.pop(c);
                unawaited(_import(context));
              },
            ),
          ],
        ),
      ),
    );

Future<void> _export(BuildContext context) async {
  final team = context.read<TeamService>();
  final messenger = ScaffoldMessenger.of(context);
  final items = teamCotItems(team);
  if (items.isEmpty) {
    messenger.showSnackBar(
      const SnackBar(content: Text('Nothing on the team map to export')),
    );
    return;
  }
  try {
    final stamp = DateTime.now()
        .toIso8601String()
        .substring(0, 16)
        .replaceAll(':', '');
    final zip = buildTakDataPackage(
      packageUid: 'VOX-DP-${team.selfKey4}-$stamp',
      name: 'MeshCore TAK $stamp',
      items: items,
    );
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/MeshCore-TAK-$stamp.zip');
    await f.writeAsBytes(zip, flush: true);
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(f.path, mimeType: 'application/zip')],
        subject: 'MeshCore Open TAK data package',
      ),
    );
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Export failed: $e')));
  }
}

Future<void> _import(BuildContext context) async {
  final team = context.read<TeamService>();
  final tak = context.read<TakService>();
  final messenger = ScaffoldMessenger.of(context);
  final f = await openFile(
    acceptedTypeGroups: const [
      XTypeGroup(label: 'TAK data package', extensions: ['zip', 'dpk']),
    ],
  );
  if (f == null) return;
  try {
    final bytes = await f.readAsBytes();
    final pkg = readTakDataPackage(bytes);
    if (pkg.isConnection) {
      final what = await tak.importDataPackage(bytes);
      messenger.showSnackBar(
        SnackBar(content: Text('TAK Server set up: $what')),
      );
      return;
    }
    final markers = <TeamMarker>[];
    final shapes = <TeamShape>[];
    var skipped = 0;
    for (final e in pkg.events) {
      final s = teamShapeFromCot(
        e,
        authorKey4: team.selfKey4,
        shapeId: team.newItemId(),
      );
      if (s != null) {
        shapes.add(s);
        continue;
      }
      final m = teamMarkerFromCot(
        e,
        authorKey4: team.selfKey4,
        markerId: team.newItemId(),
      );
      if (m != null) {
        markers.add(m);
      } else {
        skipped++;
      }
    }
    if (!context.mounted) return;
    if (markers.isEmpty && shapes.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('No map items found in that package')),
      );
      return;
    }
    final n = markers.length + shapes.length;
    final choice = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(pkg.name ?? 'Data package'),
        content: Text(
          [
            if (markers.isNotEmpty)
              '${markers.length} point${markers.length == 1 ? '' : 's'}',
            if (shapes.isNotEmpty)
              '${shapes.length} drawing${shapes.length == 1 ? '' : 's'} '
                  'or route${shapes.length == 1 ? '' : 's'}',
            if (skipped > 0) '$skipped other item${skipped == 1 ? '' : 's'} '
                'skipped',
          ].join(', ') +
              '.\n\nSharing sends one team message per item '
                  '(about ${n * 3} s of spacing).',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, 'local'),
            child: const Text('My map only'),
          ),
          FilledButton(
            onPressed: team.active ? () => Navigator.pop(c, 'share') : null,
            child: const Text('Share with team'),
          ),
        ],
      ),
    );
    if (choice == null) return;
    if (choice == 'local') {
      for (final m in markers) {
        team.putExternalMarker(m);
      }
      for (final s in shapes) {
        team.putExternalShape(s);
      }
      messenger.showSnackBar(
        SnackBar(content: Text('Added $n items to your map')),
      );
      return;
    }
    messenger.showSnackBar(
      SnackBar(content: Text('Sharing $n items with your team…')),
    );
    for (final m in markers) {
      await team.putMarker(
        kind: m.kind,
        lat: m.lat,
        lon: m.lon,
        label: m.label,
        note: m.note,
      );
      await Future<void>.delayed(const Duration(seconds: 3));
    }
    for (final s in shapes) {
      await team.putShape(
        kind: s.kind,
        points: s.points,
        color: s.color,
        label: s.label,
        geofence: s.geofence,
        routeMethod: s.routeMethod,
        radiusM: s.radiusM,
      );
      await Future<void>.delayed(const Duration(seconds: 3));
    }
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Import failed: $e')));
  }
}
