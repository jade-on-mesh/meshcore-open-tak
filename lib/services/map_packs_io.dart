// MeshCore Open TAK - map packs on native platforms: MBTiles files in the
// app's support folder, read with SQLite (package:sqlite3, synchronous FFI:
// a tile lookup is one indexed query, fast enough for the tile layer).

import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import 'map_packs.dart';

class MapPackStore {
  bool get supported => true;

  final Map<String, Database> _dbs = {};
  final Map<String, PreparedStatement> _queries = {};
  Directory? _dir;

  Future<Directory> _folder() async {
    if (_dir != null) return _dir!;
    final base = await getApplicationSupportDirectory();
    final d = Directory('${base.path}/map_packs');
    await d.create(recursive: true);
    return _dir = d;
  }

  Future<List<MapPackInfo>> open() async {
    final d = await _folder();
    final out = <MapPackInfo>[];
    await for (final f in d.list()) {
      if (f is! File || !f.path.endsWith('.mbtiles')) continue;
      if (f.uri.pathSegments.last.startsWith('.')) {
        await f.delete(); // an import that never finished
        continue;
      }
      try {
        out.add(_openFile(f));
      } catch (_) {
        // A damaged pack is skipped, not fatal.
      }
    }
    out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return out;
  }

  MapPackInfo _openFile(File f) {
    final id = f.uri.pathSegments.last;
    final db = sqlite3.open(f.path, mode: OpenMode.readOnly);
    try {
      final meta = <String, String>{};
      for (final r in db.select('SELECT name, value FROM metadata')) {
        meta['${r['name']}'.toLowerCase()] = '${r['value']}';
      }
      final format = (meta['format'] ?? 'png').toLowerCase();
      if (format == 'pbf' || format == 'mvt') {
        throw const FormatException(
          'This is a vector map pack. Only raster packs (PNG, JPEG or WebP '
          'tiles) can be shown.',
        );
      }
      var minZ = int.tryParse(meta['minzoom'] ?? '');
      var maxZ = int.tryParse(meta['maxzoom'] ?? '');
      if (minZ == null || maxZ == null) {
        final r = db
            .select(
              'SELECT MIN(zoom_level) AS a, MAX(zoom_level) AS b FROM tiles',
            )
            .first;
        minZ ??= (r['a'] as int?) ?? 0;
        maxZ ??= (r['b'] as int?) ?? 22;
      }
      final b = parseMbtilesBounds(meta['bounds']);
      _queries[id] = db.prepare(
        'SELECT tile_data FROM tiles '
        'WHERE zoom_level = ? AND tile_column = ? AND tile_row = ?',
      );
      _dbs[id] = db;
      return MapPackInfo(
        id: id,
        name: (meta['name'] ?? '').trim().isNotEmpty
            ? meta['name']!.trim()
            : id.replaceAll('.mbtiles', ''),
        format: format,
        minZoom: minZ,
        maxZoom: maxZ,
        sw: b?.$1,
        ne: b?.$2,
        bytes: f.lengthSync(),
      );
    } catch (_) {
      _queries.remove(id)?.dispose();
      _dbs.remove(id);
      db.dispose();
      rethrow;
    }
  }

  Uint8List? tile(String id, int z, int x, int row) {
    final q = _queries[id];
    if (q == null) return null;
    try {
      final rs = q.select([z, x, row]);
      if (rs.isEmpty) return null;
      final v = rs.first.columnAt(0);
      return v is Uint8List ? v : null;
    } catch (_) {
      return null;
    }
  }

  Future<MapPackInfo> import(XFile file) async {
    final d = await _folder();
    var name = file.name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    if (!name.toLowerCase().endsWith('.mbtiles')) name = '$name.mbtiles';
    final tmp = File('${d.path}/.importing_$name');
    final sink = tmp.openWrite();
    try {
      await sink.addStream(file.openRead());
    } finally {
      await sink.close();
    }
    // Check it before it replaces anything.
    MapPackInfo info;
    try {
      info = _openFile(tmp);
    } on SqliteException {
      await tmp.delete();
      throw const FormatException('That file is not an MBTiles map pack.');
    } catch (_) {
      await tmp.delete();
      rethrow;
    }
    final tmpId = info.id;
    _queries.remove(tmpId)?.dispose();
    _dbs.remove(tmpId)?.dispose();
    await remove(name);
    final dest = await tmp.rename('${d.path}/$name');
    return _openFile(dest);
  }

  Future<void> remove(String id) async {
    _queries.remove(id)?.dispose();
    _dbs.remove(id)?.dispose();
    final d = await _folder();
    final f = File('${d.path}/$id');
    if (await f.exists()) await f.delete();
  }
}
