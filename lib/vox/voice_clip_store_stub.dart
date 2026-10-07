import 'dart:typed_data';

class VoxClipStore {
  final Map<String, Uint8List> _mem = {};
  Future<void> save(String sessionId, Uint8List codecBytes) async =>
      _mem[sessionId] = codecBytes;
  Future<Uint8List?> load(String sessionId) async => _mem[sessionId];
}
