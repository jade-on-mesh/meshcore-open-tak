import 'dart:async';
import 'dart:io';

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../services/qr_image_decoder.dart';
import '../utils/platform_info.dart';

/// Whether the webcam path ([DesktopQrCamera]) scans here: Windows, where
/// mobile_scanner has no implementation but camera_windows does.
bool get desktopQrCameraSupported => PlatformInfo.isWindows;

/// A webcam QR scanner for Windows: the camera's preview, with a still taken
/// and decoded ([decodeQrImageInBackground]) a few times a second. Each code
/// found goes to [onCode]; [paused] stops taking stills (the preview stays).
///
/// camera_windows has no frame stream, so stills it is: about 2-4 a second
/// on a typical webcam, plenty for a code held up to it.
class DesktopQrCamera extends StatefulWidget {
  final void Function(String code) onCode;
  final bool paused;

  /// Shown under the error message when the camera can't be used (e.g. the
  /// "Scan a picture" button).
  final Widget? fallback;

  const DesktopQrCamera({
    super.key,
    required this.onCode,
    this.paused = false,
    this.fallback,
  });

  @override
  State<DesktopQrCamera> createState() => _DesktopQrCameraState();
}

class _DesktopQrCameraState extends State<DesktopQrCamera> {
  List<CameraDescription> _cameras = const [];
  int _cameraIndex = 0;
  int? _cameraId;
  Size? _previewSize;
  String? _error;
  bool _noCamera = false;
  bool _disposed = false;
  bool _busy = false;
  Timer? _timer;
  StreamSubscription<CameraErrorEvent>? _errors;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      final cameras = await CameraPlatform.instance.availableCameras();
      if (_disposed) return;
      if (cameras.isEmpty) {
        setState(() => _noCamera = true);
        return;
      }
      _cameras = cameras;
      await _open(_cameraIndex.clamp(0, cameras.length - 1));
    } catch (e) {
      if (!_disposed) setState(() => _error = '$e');
    }
  }

  Future<void> _open(int index) async {
    await _close();
    final platform = CameraPlatform.instance;
    final id = await platform.createCameraWithSettings(
      _cameras[index],
      const MediaSettings(
        resolutionPreset: ResolutionPreset.high,
        enableAudio: false,
      ),
    );
    if (_disposed) {
      await platform.dispose(id);
      return;
    }
    final initialized = platform.onCameraInitialized(id).first;
    _errors = platform.onCameraError(id).listen((e) {
      if (!_disposed) setState(() => _error = e.description);
    });
    await platform.initializeCamera(id);
    final event = await initialized;
    if (_disposed) {
      await platform.dispose(id);
      return;
    }
    setState(() {
      _cameraIndex = index;
      _cameraId = id;
      _previewSize = Size(event.previewWidth, event.previewHeight);
      _error = null;
    });
    _timer = Timer.periodic(
      const Duration(milliseconds: 300),
      (_) => _scanOnce(),
    );
  }

  Future<void> _scanOnce() async {
    final id = _cameraId;
    if (id == null || _busy || widget.paused || _disposed) return;
    _busy = true;
    try {
      final shot = await CameraPlatform.instance.takePicture(id);
      final bytes = await shot.readAsBytes();
      unawaited(_deleteQuietly(shot.path));
      final code = await decodeQrImageInBackground(bytes);
      if (code != null && !_disposed && !widget.paused) widget.onCode(code);
    } catch (_) {
      // A missed still is fine: the next tick tries again.
    } finally {
      _busy = false;
    }
  }

  static Future<void> _deleteQuietly(String path) async {
    if (path.isEmpty) return;
    try {
      await File(path).delete();
    } catch (_) {}
  }

  Future<void> _close() async {
    _timer?.cancel();
    _timer = null;
    await _errors?.cancel();
    _errors = null;
    final id = _cameraId;
    _cameraId = null;
    if (id != null) {
      try {
        await CameraPlatform.instance.dispose(id);
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final id = _cameraId;
    final size = _previewSize;
    if (_noCamera || _error != null) {
      return ColoredBox(
        color: scheme.surface,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _noCamera ? Icons.videocam_off : Icons.error_outline,
                  size: 64,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(height: 16),
                Text(
                  _noCamera
                      ? l10n.qr_noWebcam
                      : l10n.qr_cameraStartFailed(_error ?? ''),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.onSurface, fontSize: 16),
                ),
                if (widget.fallback != null) ...[
                  const SizedBox(height: 16),
                  widget.fallback!,
                ],
              ],
            ),
          ),
        ),
      );
    }
    if (id == null || size == null) {
      return const ColoredBox(
        color: Colors.black,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(
          color: Colors.black,
          child: FittedBox(
            fit: BoxFit.cover,
            clipBehavior: Clip.hardEdge,
            child: SizedBox(
              width: size.width,
              height: size.height,
              child: CameraPlatform.instance.buildPreview(id),
            ),
          ),
        ),
        if (_cameras.length > 1)
          Positioned(
            top: 12 + MediaQuery.viewPaddingOf(context).top,
            right: 12,
            child: IconButton.filled(
              tooltip: l10n.qr_switchWebcam,
              icon: const Icon(Icons.cameraswitch),
              onPressed: () =>
                  unawaited(_open((_cameraIndex + 1) % _cameras.length)),
            ),
          ),
      ],
    );
  }
}
