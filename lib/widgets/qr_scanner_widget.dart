import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../helpers/snack_bar_builder.dart';
import '../l10n/l10n.dart';
import '../services/qr_image_decoder.dart';
import '../theme/mesh_theme.dart';
import '../utils/platform_info.dart';
import 'desktop_qr_camera.dart';

/// Size of the square scan window cut out of the overlay.
const double _scanWindowSize = 250;

/// Full-screen spinner shown in place of the scanner while a scanned code is
/// being processed (stops the camera and prevents duplicate detections).
class QrScannerProcessingBody extends StatelessWidget {
  const QrScannerProcessingBody({super.key});

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Theme.of(context).colorScheme.surface,
      child: const Center(child: CircularProgressIndicator()),
    );
  }
}

/// Short warning snackbar for a QR code that isn't the expected kind.
void showInvalidQrSnackBar(BuildContext context, String message) {
  showDismissibleSnackBar(
    context,
    content: Text(message),
    backgroundColor: MeshPalette.warn,
    duration: const Duration(seconds: 2),
  );
}

/// A reusable QR code scanner widget that can be embedded anywhere.
///
/// Features:
/// - Configurable scan window overlay
/// - Flash toggle button
/// - Camera switch button (front/back)
/// - Customizable callbacks for scan results
/// - Optional validation function for QR data
/// - Automatic pause when not visible
/// - Debouncing to prevent duplicate scans
class QrScannerWidget extends StatefulWidget {
  /// Called when a valid QR code is scanned
  final void Function(String data) onScanned;

  /// Optional validator - return true if the QR data is valid
  final bool Function(String data)? validator;

  /// Optional error callback when validation fails
  final void Function(String data)? onValidationFailed;

  /// Whether to show the flash toggle button
  final bool showFlashButton;

  /// Whether to show the camera switch button
  final bool showCameraSwitchButton;

  /// Custom overlay widget (defaults to scan window frame)
  final Widget? overlay;

  /// Use the app-themed overlay (accent corner brackets and a high-contrast
  /// instructions pill) instead of the plain default. Ignored when [overlay]
  /// is given.
  final bool themed;

  /// Instructions text shown below the scan window
  final String? instructions;

  /// Whether to continue scanning after first successful scan
  final bool continuousScanning;

  /// Debounce duration to prevent duplicate scans
  final Duration debounceDuration;

  const QrScannerWidget({
    super.key,
    required this.onScanned,
    this.validator,
    this.onValidationFailed,
    this.showFlashButton = true,
    this.showCameraSwitchButton = true,
    this.overlay,
    this.themed = false,
    this.instructions,
    this.continuousScanning = false,
    this.debounceDuration = const Duration(milliseconds: 500),
  });

  @override
  State<QrScannerWidget> createState() => _QrScannerWidgetState();
}

class _QrScannerWidgetState extends State<QrScannerWidget>
    with WidgetsBindingObserver {
  /// mobile_scanner's camera; null on Windows and Linux, which it doesn't
  /// support (Windows scans with [DesktopQrCamera], Linux from a picture).
  MobileScannerController? _controller;
  bool _hasScanned = false;

  static bool get _noMobileScanner =>
      PlatformInfo.isWindows || PlatformInfo.isLinux;
  String? _lastScannedData;
  DateTime? _lastScanTime;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (!_noMobileScanner) {
      _controller = MobileScannerController(
        detectionSpeed: DetectionSpeed.normal,
        facing: CameraFacing.back,
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Handle app lifecycle changes - pause/resume scanner
    final controller = _controller;
    if (controller == null || !controller.value.hasCameraPermission) return;

    switch (state) {
      case AppLifecycleState.resumed:
        controller.start();
        break;
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        controller.stop();
        break;
    }
  }

  void _handleDetection(BarcodeCapture capture) {
    // Prevent duplicate scans
    if (_hasScanned && !widget.continuousScanning) return;

    final List<Barcode> barcodes = capture.barcodes;
    for (final barcode in barcodes) {
      final String? rawValue = barcode.rawValue;
      if (rawValue == null || rawValue.isEmpty) continue;
      if (_handleRaw(rawValue)) return;
    }
  }

  /// One decoded code, from any source (camera, webcam, picture). True when
  /// it was taken.
  bool _handleRaw(String rawValue) {
    if (_hasScanned && !widget.continuousScanning) return false;

    // Debounce - ignore if same data scanned too quickly
    final now = DateTime.now();
    if (_lastScannedData == rawValue &&
        _lastScanTime != null &&
        now.difference(_lastScanTime!) < widget.debounceDuration) {
      return false;
    }

    _lastScannedData = rawValue;
    _lastScanTime = now;

    // Validate if validator provided
    if (widget.validator != null && !widget.validator!(rawValue)) {
      widget.onValidationFailed?.call(rawValue);
      return false;
    }

    // Mark as scanned to prevent duplicates
    if (!widget.continuousScanning) {
      setState(() {
        _hasScanned = true;
      });
      _controller?.stop();
    }

    // Notify callback
    widget.onScanned(rawValue);
    return true;
  }

  /// Windows, Linux and Mac: a QR code from a picture or screenshot on disk.
  Future<void> _scanPicture() async {
    final XFile? file;
    try {
      file = await ImagePicker().pickImage(source: ImageSource.gallery);
    } catch (_) {
      return;
    }
    if (file == null || !mounted) return;
    final code = await decodeQrImageInBackground(await file.readAsBytes());
    if (!mounted) return;
    if (code == null) {
      showInvalidQrSnackBar(context, context.l10n.qr_noCodeInPicture);
      return;
    }
    // A picture is chosen on purpose: no debounce against the last scan.
    _lastScannedData = null;
    _handleRaw(code);
  }

  Widget _pictureButton(BuildContext context) => FilledButton.tonalIcon(
    onPressed: () => unawaited(_scanPicture()),
    icon: const Icon(Icons.image_search),
    label: Text(context.l10n.qr_scanPicture),
  );

  /// The camera view where mobile_scanner has none: the webcam on Windows,
  /// a "scan a picture" panel on Linux.
  Widget _buildDesktopScanner(BuildContext context) {
    if (desktopQrCameraSupported) {
      return DesktopQrCamera(
        onCode: _handleRaw,
        paused: _hasScanned && !widget.continuousScanning,
        fallback: _pictureButton(context),
      );
    }
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.surface,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.qr_code_scanner,
                size: 64,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(height: 16),
              Text(
                context.l10n.qr_pictureOnly,
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurface, fontSize: 16),
              ),
              const SizedBox(height: 16),
              _pictureButton(context),
            ],
          ),
        ),
      ),
    );
  }

  /// Reset the scanner to allow scanning again
  void resetScanner() {
    setState(() {
      _hasScanned = false;
      _lastScannedData = null;
      _lastScanTime = null;
    });
    _controller?.start();
  }

  @override
  Widget build(BuildContext context) {
    // The camera preview is dark, so keep the system bar icons light, and lift
    // the controls above the navigation bar the app draws behind.
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Stack(
        children: [
          // Scanner view
          if (_controller case final controller?)
            MobileScanner(
              controller: controller,
              onDetect: _handleDetection,
              errorBuilder: (context, error) {
                return _buildErrorWidget(context, error);
              },
            )
          else
            _buildDesktopScanner(context),

          // Overlay (Linux has no camera view to frame)
          if (!PlatformInfo.isLinux)
            widget.overlay ?? _buildDefaultOverlay(context),

          // Control buttons
          Positioned(
            bottom: 16 + MediaQuery.viewPaddingOf(context).bottom,
            left: 0,
            right: 0,
            child: _buildControls(context),
          ),
        ],
      ),
    );
  }

  Widget _buildDefaultOverlay(BuildContext context) {
    final instructions = widget.instructions;
    return Stack(
      fit: StackFit.expand,
      children: [
        // Dimmed background with a transparent cutout for the scan window.
        ColorFiltered(
          colorFilter: ColorFilter.mode(
            MeshPalette.bg.withValues(alpha: 0.55),
            BlendMode.srcOut,
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Container(
                decoration: const BoxDecoration(
                  color: MeshPalette.bg,
                  backgroundBlendMode: BlendMode.dstOut,
                ),
              ),
              Center(
                child: Container(
                  height: _scanWindowSize,
                  width: _scanWindowSize,
                  decoration: BoxDecoration(
                    // Any opaque colour: it only defines the cutout shape.
                    color: MeshPalette.ink,
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
              ),
            ],
          ),
        ),
        if (widget.themed)
          const ScannerCornerOverlay(
            scanWindowSize: _scanWindowSize,
            borderColor: MeshPalette.blue,
            borderWidth: 3,
            cornerLength: 28,
          ),
        // Instructions pill below the scan window.
        if (instructions != null)
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: _scanWindowSize + 24),
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 24),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: MeshPalette.bg.withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(
                      widget.themed ? MeshRadii.pill : 8,
                    ),
                  ),
                  child: Text(
                    instructions,
                    style: const TextStyle(
                      color: MeshPalette.ink,
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildControls(BuildContext context) {
    final controller = _controller;
    // Windows: the webcam view has its own switch button; a picture can
    // always be opened instead. Linux's panel holds its own button.
    if (controller == null) {
      return PlatformInfo.isLinux
          ? const SizedBox.shrink()
          : Center(child: _pictureButton(context));
    }
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (widget.showFlashButton)
          ValueListenableBuilder(
            valueListenable: controller,
            builder: (context, state, child) {
              return IconButton.filled(
                onPressed: () => controller.toggleTorch(),
                icon: Icon(
                  state.torchState == TorchState.on
                      ? Icons.flash_on
                      : Icons.flash_off,
                ),
                style: _controlStyle,
              );
            },
          ),
        if (widget.showFlashButton && widget.showCameraSwitchButton)
          const SizedBox(width: 24),
        if (widget.showCameraSwitchButton)
          IconButton.filled(
            onPressed: () => controller.switchCamera(),
            icon: const Icon(Icons.cameraswitch),
            style: _controlStyle,
          ),
        // Mac: the camera works, and a picture or screenshot of a code can
        // be opened too.
        if (PlatformInfo.isMacOS) ...[
          const SizedBox(width: 24),
          _pictureButton(context),
        ],
      ],
    );
  }

  static final ButtonStyle _controlStyle = IconButton.styleFrom(
    backgroundColor: MeshPalette.bg.withValues(alpha: 0.7),
    foregroundColor: MeshPalette.ink,
    minimumSize: const Size(56, 56),
    iconSize: 28,
  );

  Widget _buildErrorWidget(BuildContext context, MobileScannerException error) {
    String message;
    IconData icon;

    switch (error.errorCode) {
      case MobileScannerErrorCode.permissionDenied:
        message = context.l10n.qr_cameraPermissionDenied;
        icon = Icons.no_photography;
        break;
      case MobileScannerErrorCode.unsupported:
        message = context.l10n.qr_cameraUnsupported;
        icon = Icons.videocam_off;
        break;
      default:
        message = context.l10n.qr_cameraStartFailed(
          error.errorDetails?.message ?? '',
        );
        icon = Icons.error_outline;
    }

    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.surface,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 64, color: scheme.onSurfaceVariant),
              const SizedBox(height: 16),
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurface, fontSize: 16),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A simpler scanner overlay with just corner brackets
class ScannerCornerOverlay extends StatelessWidget {
  final double scanWindowSize;
  final Color borderColor;
  final double borderWidth;
  final double cornerLength;

  const ScannerCornerOverlay({
    super.key,
    this.scanWindowSize = 250,
    this.borderColor = MeshPalette.ink,
    this.borderWidth = 3,
    this.cornerLength = 30,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SizedBox(
        width: scanWindowSize,
        height: scanWindowSize,
        child: CustomPaint(
          painter: _CornerPainter(
            color: borderColor,
            strokeWidth: borderWidth,
            cornerLength: cornerLength,
          ),
        ),
      ),
    );
  }
}

class _CornerPainter extends CustomPainter {
  final Color color;
  final double strokeWidth;
  final double cornerLength;

  _CornerPainter({
    required this.color,
    required this.strokeWidth,
    required this.cornerLength,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final path = Path();

    // Top-left corner
    path.moveTo(0, cornerLength);
    path.lineTo(0, 0);
    path.lineTo(cornerLength, 0);

    // Top-right corner
    path.moveTo(size.width - cornerLength, 0);
    path.lineTo(size.width, 0);
    path.lineTo(size.width, cornerLength);

    // Bottom-right corner
    path.moveTo(size.width, size.height - cornerLength);
    path.lineTo(size.width, size.height);
    path.lineTo(size.width - cornerLength, size.height);

    // Bottom-left corner
    path.moveTo(cornerLength, size.height);
    path.lineTo(0, size.height);
    path.lineTo(0, size.height - cornerLength);

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
