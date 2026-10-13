// MeshCore Open TAK - offline maps: import map packs, and download the area
// on screen (through the Offline Map Cache screen).

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

import '../services/map_packs.dart';
import 'map_cache_screen.dart';
import 'map_screen.dart';

class MapPacksScreen extends StatelessWidget {
  /// The map's visible area, for "Download this area".
  final LatLngBounds? area;

  const MapPacksScreen({super.key, this.area});

  static String _size(int b) {
    if (b >= 1 << 30) return '${(b / (1 << 30)).toStringAsFixed(1)} GB';
    if (b >= 1 << 20) return '${(b / (1 << 20)).toStringAsFixed(0)} MB';
    return '${(b / 1024).ceil()} KB';
  }

  Future<void> _import(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final p = await MapPackService.instance.pickAndImport();
      if (p != null) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              'Added ${p.name} (zoom ${p.minZoom}-${p.maxZoom})',
            ),
          ),
        );
      }
    } on FormatException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Import failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final svc = MapPackService.instance;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Offline Maps')),
      body: ListenableBuilder(
        listenable: svc,
        builder: (context, _) {
          return ListView(
            padding: const EdgeInsets.only(bottom: 96),
            children: [
              ListTile(
                leading: const Icon(Icons.download_for_offline_outlined),
                title: const Text('Download this area'),
                subtitle: const Text(
                  'Saves the map you were looking at, for the zoom levels '
                  'you pick. Needs a map style that allows downloads '
                  '(Stadia styles with your own API key in Map settings).',
                ),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => MapCacheScreen(initialBounds: area),
                  ),
                ),
              ),
              const Divider(),
              ListTile(
                title: Text('Map packs', style: theme.textTheme.titleMedium),
                subtitle: const Text(
                  'MBTiles files with raster tiles (PNG, JPEG or WebP), made '
                  'with QGIS or Mobile Atlas Creator, or downloaded ready-made. '
                  'They work with no internet, in every map style, and are '
                  'drawn before anything downloaded.',
                ),
              ),
              if (!svc.supported)
                const ListTile(
                  leading: Icon(Icons.info_outline),
                  title: Text('Map packs need the phone or desktop app.'),
                ),
              if (svc.supported && svc.packs.isEmpty)
                const ListTile(
                  leading: Icon(Icons.map_outlined),
                  title: Text('No map packs yet'),
                ),
              for (final p in svc.packs)
                SwitchListTile(
                  secondary: IconButton(
                    tooltip: 'Remove',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (c) => AlertDialog(
                          title: Text('Remove ${p.name}?'),
                          content: Text(
                            'Frees ${_size(p.bytes)}. You can import it again later.',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(c, false),
                              child: const Text('Cancel'),
                            ),
                            FilledButton(
                              onPressed: () => Navigator.pop(c, true),
                              child: const Text('Remove'),
                            ),
                          ],
                        ),
                      );
                      if (ok == true) await svc.remove(p.id);
                    },
                  ),
                  title: Text(p.name),
                  subtitle: Text(
                    '${p.format.toUpperCase()} · zoom ${p.minZoom}-${p.maxZoom} · '
                    '${_size(p.bytes)}',
                  ),
                  value: p.enabled,
                  onChanged: (v) => svc.setEnabled(p.id, v),
                ),
              if (svc.packs.any((p) => p.center != null)) ...[
                const Divider(),
                for (final p in svc.packs.where((p) => p.center != null))
                  ListTile(
                    leading: const Icon(Icons.travel_explore),
                    title: Text('Show ${p.name} on the map'),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => MapScreen(
                          focusPosition: p.center,
                          focusZoom: p.minZoom.clamp(3, 14).toDouble() + 2,
                        ),
                      ),
                    ),
                  ),
              ],
            ],
          );
        },
      ),
      floatingActionButton: svc.supported
          ? FloatingActionButton.extended(
              onPressed: () => _import(context),
              icon: const Icon(Icons.file_open_outlined),
              label: const Text('Import map pack'),
            )
          : null,
    );
  }
}
