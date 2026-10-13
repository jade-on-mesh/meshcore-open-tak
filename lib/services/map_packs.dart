// MeshCore Open TAK - offline map packs.
//
// A map pack is an MBTiles file (SQLite, raster tiles: PNG, JPEG or WebP)
// made elsewhere: QGIS, Mobile Atlas Creator, or downloaded ready-made. Packs
// are copied into the app and their tiles are drawn before anything from the
// internet or the tile cache, in every map style, so a phone with no signal
// still has a map. Vector packs (pbf) are refused: the map draws rasters.
//
// The SQLite part lives in map_packs_io.dart (dart:ffi); the web build gets
// map_packs_stub.dart and simply has no packs.

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'map_packs_stub.dart' if (dart.library.ffi) 'map_packs_io.dart' as impl;

/// What a pack's metadata says about it.
class MapPackInfo {
  final String id; // file name in the packs folder
  final String name;
  final String format;
  final int minZoom, maxZoom;

  /// South-west and north-east corners, if the pack says.
  final LatLng? sw, ne;
  final int bytes;
  final bool enabled;

  const MapPackInfo({
    required this.id,
    required this.name,
    required this.format,
    required this.minZoom,
    required this.maxZoom,
    this.sw,
    this.ne,
    required this.bytes,
    this.enabled = true,
  });

  MapPackInfo withEnabled(bool v) => MapPackInfo(
    id: id,
    name: name,
    format: format,
    minZoom: minZoom,
    maxZoom: maxZoom,
    sw: sw,
    ne: ne,
    bytes: bytes,
    enabled: v,
  );

  LatLng? get center => sw == null || ne == null
      ? null
      : LatLng((sw!.latitude + ne!.latitude) / 2, (sw!.longitude + ne!.longitude) / 2);

  /// Whether tile x/y at zoom z can be in this pack (by its stated bounds).
  bool covers(int z, int x, int y) {
    if (z < minZoom || z > maxZoom) return false;
    if (sw == null || ne == null) return true;
    final n = 1 << z;
    final x0 = mapPackTileX(sw!.longitude, n), x1 = mapPackTileX(ne!.longitude, n);
    final y0 = mapPackTileY(ne!.latitude, n), y1 = mapPackTileY(sw!.latitude, n);
    return x >= x0 && x <= x1 && y >= y0 && y <= y1;
  }
}

int mapPackTileX(double lon, int n) =>
    (((lon + 180) / 360) * n).floor().clamp(0, n - 1);

int mapPackTileY(double lat, int n) {
  final r = lat.clamp(-85.0511, 85.0511) * math.pi / 180;
  final y = (1 - math.log(math.tan(r) + 1 / math.cos(r)) / math.pi) / 2 * n;
  return y.floor().clamp(0, n - 1);
}

/// The MBTiles row for an XYZ tile (MBTiles counts rows from the south).
int mbtilesRow(int z, int y) => (1 << z) - 1 - y;

/// Parses MBTiles `bounds` metadata: "left,bottom,right,top".
(LatLng, LatLng)? parseMbtilesBounds(String? s) {
  if (s == null) return null;
  final v = s.split(',').map((e) => double.tryParse(e.trim())).toList();
  if (v.length != 4 || v.contains(null)) return null;
  return (LatLng(v[1]!, v[0]!), LatLng(v[3]!, v[2]!));
}

class MapPackService extends ChangeNotifier {
  MapPackService._();
  static final MapPackService instance = MapPackService._();

  static const _kDisabled = 'map_packs_disabled_v1';

  final impl.MapPackStore _store = impl.MapPackStore();
  List<MapPackInfo> _packs = const [];
  bool _loaded = false;
  Future<void>? _loading;

  /// False on the web: packs need SQLite.
  bool get supported => _store.supported;

  List<MapPackInfo> get packs => _packs;

  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    if (!supported) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final off = (prefs.getStringList(_kDisabled) ?? const []).toSet();
      final found = await _store.open();
      _packs = [for (final p in found) p.withEnabled(!off.contains(p.id))];
    } catch (e) {
      debugPrint('map packs: $e');
    }
    _loaded = true;
    notifyListeners();
  }

  /// A tile from the first enabled pack that has it, or null.
  Uint8List? tile(int z, int x, int y) {
    if (!_loaded || _packs.isEmpty) return null;
    for (final p in _packs) {
      if (!p.enabled || !p.covers(z, x, y)) continue;
      final t = _store.tile(p.id, z, x, mbtilesRow(z, y));
      if (t != null) return t;
    }
    return null;
  }

  /// Asks for an .mbtiles file and adds it. Returns the pack, or null if
  /// nothing was picked. Throws [FormatException] for a file that isn't a
  /// raster MBTiles pack.
  Future<MapPackInfo?> pickAndImport() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Map packs (MBTiles)', extensions: ['mbtiles']),
        // Android pickers often don't know the extension: allow anything.
        XTypeGroup(label: 'All files'),
      ],
    );
    if (file == null) return null;
    await load();
    final info = await _store.import(file);
    _packs = [..._packs.where((p) => p.id != info.id), info];
    notifyListeners();
    return info;
  }

  Future<void> setEnabled(String id, bool v) async {
    _packs = [for (final p in _packs) p.id == id ? p.withEnabled(v) : p];
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_kDisabled, [
        for (final p in _packs)
          if (!p.enabled) p.id,
      ]);
    } catch (_) {}
  }

  Future<void> remove(String id) async {
    _packs = [for (final p in _packs) if (p.id != id) p];
    notifyListeners();
    await _store.remove(id);
  }
}
