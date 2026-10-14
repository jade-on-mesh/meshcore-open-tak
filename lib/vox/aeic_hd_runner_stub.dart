// MeshCore Open TAK - AEIC HD on platforms without the codec program (web).

import 'dart:typed_data';

class AeicHdDownloadCancelled implements Exception {
  const AeicHdDownloadCancelled();
}

class AeicHdJobCancelled implements Exception {
  const AeicHdJobCancelled();
}

class AeicHdRunner {
  AeicHdRunner(String baseUrl);

  bool get supported => false;

  Future<int?> totalMemory() async => null;

  Future<bool> installed() async => false;

  Future<void> install({
    required void Function(int bytes) onTotal,
    required void Function(double progress) onProgress,
  }) => throw UnsupportedError('AI sketch HD needs the Android app.');

  void cancelDownload() {}

  Future<void> remove() async {}

  Future<Uint8List> encode(
    Uint8List rgb512,
    void Function(double) onProgress,
  ) => throw UnsupportedError('AI sketch HD needs the Android app.');

  Future<Uint8List> decode(
    Uint8List payload,
    void Function(double) onProgress,
  ) => throw UnsupportedError('AI sketch HD needs the Android app.');

  void cancelJob() {}
}
