import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

class VoxClipStore {
  Directory? _dir;

  Future<Directory> _ensureDir() async {
    if (_dir != null) return _dir!;
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}vox_voice');
    if (!await dir.exists()) await dir.create(recursive: true);
    return _dir = dir;
  }

  bool _validId(String sid) => RegExp(r'^[0-9a-f]{8}$').hasMatch(sid);

  Future<void> save(String sessionId, Uint8List codecBytes) async {
    if (!_validId(sessionId)) return;
    final dir = await _ensureDir();
    await File('${dir.path}${Platform.pathSeparator}$sessionId.c2')
        .writeAsBytes(codecBytes, flush: true);
  }

  Future<Uint8List?> load(String sessionId) async {
    if (!_validId(sessionId)) return null;
    final dir = await _ensureDir();
    final f = File('${dir.path}${Platform.pathSeparator}$sessionId.c2');
    if (!await f.exists()) return null;
    return f.readAsBytes();
  }
}
