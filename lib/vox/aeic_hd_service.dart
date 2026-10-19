// MeshCore Open TAK - "AI sketch HD": AEIC-SE at the ft2 rate point, run by
// mikecarper/AEIC's ncnn codec (https://github.com/mikecarper/AEIC/tree/main/mobile).
//
// The third photo option, next to Mesh photos (the default) and AI sketch
// (AEIC ft32 on ONNX Runtime). Around 1-2 KB on air instead of ~150 B, so a
// much more faithful picture, and it runs in bounded memory (~550 MiB peak to
// decode rather than ~2.2 GiB) because the codec loads one model stage at a
// time. The price is time: decoding takes minutes, not a second.
//
// Wire format: unchanged image messages (GRP_DATA 0xAE1C on channels, OTP
// chunks in DMs). The chunk-0 metadata byte's rate field says "hd"
// (kImageRateWireHd), which is how a receiver picks this decoder, and how an
// older build knows to say "unsupported format" instead of mis-decoding. The
// payload is the AEIC practical bitstream without the reference codec's
// 12-byte (height, width, length) header, which the metadata already implies.
//
// Pieces:
//   * the codec program, built by tool/build_aeic_hd_android.sh into the APK;
//   * the ~2 GB model pack, a GitHub release made by
//     .github/workflows/aeic-ncnn-models.yml, downloaded here on request;
//   * aeic_hd_runner_io.dart, which downloads, and runs the program.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/image_codec_support.dart';
import '../services/received_image_store.dart';
import '../widgets/image_send_codec_binding.dart';
import 'aeic_hd_runner_stub.dart' if (dart.library.io) 'aeic_hd_runner_io.dart';

/// Where the model pack is published.
const String kAeicHdPackTag = 'aeic-ncnn-ft2-512-v1';
const String kAeicHdPackBaseUrl =
    'https://github.com/jade-on-mesh/meshcore-open-tak/releases/download/'
    '$kAeicHdPackTag/';

/// Approximate download size, for the setup screen before the manifest is in.
const int kAeicHdPackApproxBytes = 2000 * 1024 * 1024;

/// Payload sizes (bytes, header excluded) for the send preview before an
/// encode has finished. One measured photo at 512 px was 1,351 B; the upper
/// figure is what the channel transport can carry (15 data chunks).
const int kAeicHdTypicalBytes = 1350;

enum AeicHdState {
  /// Not Android: there is no codec program for this platform.
  unsupported,
  notInstalled,
  downloading,
  ready,
}

class AeicHdException implements Exception {
  final String message;
  const AeicHdException(this.message);
  @override
  String toString() => message;
}

class AeicHdService extends ChangeNotifier {
  AeicHdService._();
  static final AeicHdService instance = AeicHdService._();

  final AeicHdRunner _runner = AeicHdRunner(kAeicHdPackBaseUrl);

  AeicHdState _state = AeicHdState.notInstalled;
  AeicHdState get state => _state;

  bool get isReady => _state == AeicHdState.ready;

  double _progress = 0;

  /// Download progress, 0..1, while [state] is downloading.
  double get progress => _progress;

  int _packBytes = kAeicHdPackApproxBytes;
  int get packBytes => _packBytes;

  String? _error;

  /// Why the last download or job failed, until the next one starts.
  String? get error => _error;

  bool _busy = false;

  /// An encode or decode is running (only one at a time).
  bool get isBusy => _busy;

  /// What the running job is doing, for progress text.
  String? _jobLabel;
  String? get jobLabel => _jobLabel;
  double _jobProgress = 0;
  double get jobProgress => _jobProgress;

  /// Phone RAM in bytes, or null when unknown.
  int? totalMemory;

  bool _initialised = false;

  Future<void> init() async {
    if (_initialised) return;
    _initialised = true;
    if (!_runner.supported) {
      _state = AeicHdState.unsupported;
      notifyListeners();
      return;
    }
    try {
      totalMemory = await _runner.totalMemory();
      _state = await _runner.installed()
          ? AeicHdState.ready
          : AeicHdState.notInstalled;
    } catch (e) {
      _state = AeicHdState.notInstalled;
      _error = '$e';
    }
    notifyListeners();
  }

  /// Downloads (or resumes) the model pack. Safe to call again after a
  /// failure: files already downloaded and checked are kept.
  Future<void> install() async {
    await init();
    if (_state == AeicHdState.unsupported ||
        _state == AeicHdState.downloading ||
        _state == AeicHdState.ready) {
      return;
    }
    _state = AeicHdState.downloading;
    _error = null;
    _progress = 0;
    notifyListeners();
    try {
      await _runner.install(
        onTotal: (bytes) {
          _packBytes = bytes;
          notifyListeners();
        },
        onProgress: (p) {
          _progress = p;
          notifyListeners();
        },
      );
      _state = AeicHdState.ready;
    } catch (e) {
      _error = e is AeicHdDownloadCancelled ? null : '$e';
      _state = AeicHdState.notInstalled;
    }
    notifyListeners();
  }

  void cancelInstall() => _runner.cancelDownload();

  Future<void> remove() async {
    if (_busy || _state == AeicHdState.downloading) return;
    await _runner.remove();
    _state = AeicHdState.notInstalled;
    notifyListeners();
  }

  bool _encodeCancelled = false;

  /// Encodes a 512x512 packed-RGB square. Returns the payload to send.
  Future<Uint8List> encode(Uint8List rgb512) {
    _encodeCancelled = false;
    return _job(_encoding, (onProgress) => _runner.encode(rgb512, onProgress));
  }

  /// Stops an encode, running or still waiting for a decode to finish, and
  /// leaves any decode alone.
  void cancelEncode() {
    _encodeCancelled = true;
    if (_jobLabel == _encoding) _runner.cancelJob();
  }

  static const _encoding = 'Encoding';

  /// Decodes a received payload into a 512x512 PNG.
  Future<Uint8List> decode(Uint8List payload) =>
      _job('Drawing', (onProgress) => _runner.decode(payload, onProgress));

  /// Runs the phone check (see AeicHdRunner.selfTest): a few minutes.
  Future<String> selfTest() async {
    final report = await _job(
      'Checking',
      (onProgress) async =>
          Uint8List.fromList((await _runner.selfTest(onProgress)).codeUnits),
    );
    return String.fromCharCodes(report);
  }

  /// Stops the running encode or decode.
  void cancelJob() => _runner.cancelJob();

  Future<Uint8List> _job(
    String label,
    Future<Uint8List> Function(void Function(double) onProgress) run,
  ) async {
    await init();
    if (!isReady) {
      throw const AeicHdException(
        'The AI sketch HD model isn\'t downloaded on this phone.',
      );
    }
    // One at a time: two would each want hundreds of MB.
    while (_busy) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    if (label == _encoding && _encodeCancelled) {
      throw const AeicHdJobCancelled();
    }
    _busy = true;
    _jobLabel = label;
    _jobProgress = 0;
    _error = null;
    notifyListeners();
    try {
      return await run((p) {
        _jobProgress = p;
        notifyListeners();
      });
    } catch (e) {
      _error = '$e';
      rethrow;
    } finally {
      _busy = false;
      _jobLabel = null;
      notifyListeners();
    }
  }
}

/// Sends `ft2` images to [AeicHdService] and everything else to [inner] (the
/// ONNX AEIC decoder), so a received photo is drawn by whichever codec made
/// it. Installed in main.dart around the store's decoder.
class AeicHdRoutingDecoder implements ReceivedImageDecoder {
  final ReceivedImageDecoder inner;
  final AeicHdService hd;

  AeicHdRoutingDecoder(this.inner, {AeicHdService? hd})
    : hd = hd ?? AeicHdService.instance {
    unawaited(this.hd.init());
  }

  @override
  ImageCodecAvailability get availability =>
      hd.isReady ? ImageCodecAvailability.ready : inner.availability;

  @override
  bool get isBusy => inner.isBusy || hd.isBusy;

  @override
  Future<ImageCodecResult?> decodeBitstream({
    required Uint8List bitstream,
    required AeicRatePoint ratePoint,
    required int resolution,
  }) async {
    if (ratePoint != AeicRatePoint.ft2) {
      if (inner.availability != ImageCodecAvailability.ready) return null;
      return inner.decodeBitstream(
        bitstream: bitstream,
        ratePoint: ratePoint,
        resolution: resolution,
      );
    }
    await hd.init();
    if (!hd.isReady) return null; // "decoder unavailable": retried later
    final started = DateTime.now();
    try {
      final png = await hd.decode(bitstream);
      return ImageCodecResult(
        ratePoint: ratePoint,
        resolution: resolution,
        durationMs: DateTime.now().difference(started).inMilliseconds,
        status: ImageCodecStatus.completed,
        pngBytes: png,
      );
    } on AeicHdJobCancelled {
      return ImageCodecResult(
        ratePoint: ratePoint,
        resolution: resolution,
        durationMs: DateTime.now().difference(started).inMilliseconds,
        status: ImageCodecStatus.failed,
      );
    } catch (e) {
      debugPrint('AEIC HD decode failed: $e');
      return ImageCodecResult(
        ratePoint: ratePoint,
        resolution: resolution,
        durationMs: DateTime.now().difference(started).inMilliseconds,
        status: ImageCodecStatus.failed,
      );
    }
  }

  /// The store cancels when the app goes to the background or memory runs
  /// low. That suits the ONNX decoder, which is back in a second. An HD
  /// decode takes minutes and runs in its own process with its memory
  /// bounded, so it is left to finish: cancelling would restart it from
  /// scratch every time the user switched apps.
  @override
  void cancelCodecJob() => inner.cancelCodecJob();
}
