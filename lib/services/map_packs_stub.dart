// MeshCore Open TAK - map packs on the web: none (they need SQLite).

import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';

import 'map_packs.dart';

class MapPackStore {
  bool get supported => false;

  Future<List<MapPackInfo>> open() async => const [];

  Uint8List? tile(String id, int z, int x, int row) => null;

  Future<MapPackInfo> import(XFile file) =>
      throw const FormatException('Map packs need the phone or desktop app.');

  Future<void> remove(String id) async {}
}
