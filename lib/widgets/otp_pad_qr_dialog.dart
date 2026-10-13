// MeshCore Open TAK - show a one-time pad as QR codes, and scan one in.
//
// A small pad is one plain hex QR code (what every version of this app
// reads). A larger one is a loop of parts (lib/services/otp_pad_qr.dart) that
// the other phone's scanner collects; a Wadamesh-tak radio shows its pads the
// same way.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../services/otp_pad_qr.dart';
import '../services/otp_service.dart';
import 'adaptive_app_bar_title.dart';
import 'qr_scanner_widget.dart';

class OtpPadQrDialog extends StatefulWidget {
  final String padHex;
  final String title;
  final String instructions;

  const OtpPadQrDialog({
    super.key,
    required this.padHex,
    required this.title,
    required this.instructions,
  });

  static Future<void> show(
    BuildContext context, {
    required String padHex,
    String title = 'Scan on the other device',
    required String instructions,
  }) => showDialog<void>(
    context: context,
    builder: (_) => OtpPadQrDialog(
      padHex: padHex,
      title: title,
      instructions: instructions,
    ),
  );

  @override
  State<OtpPadQrDialog> createState() => _OtpPadQrDialogState();
}

class _OtpPadQrDialogState extends State<OtpPadQrDialog> {
  late final List<String> _codes;
  int _i = 0;
  bool _paused = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    final bytes = widget.padHex.length ~/ 2;
    // Uppercase hex is all QR alphanumeric characters (denser than bytes);
    // every import path reads hex in either case.
    _codes = bytes <= OtpService.maxQrShareablePadBytes
        ? [widget.padHex.toUpperCase()]
        : otpPadQrParts(widget.padHex);
    if (_codes.length > 1) {
      _timer = Timer.periodic(const Duration(milliseconds: 1200), (_) {
        if (!_paused && mounted) setState(() => _i = (_i + 1) % _codes.length);
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final multi = _codes.length > 1;
    final size = (MediaQuery.sizeOf(context).width - 112).clamp(200.0, 320.0);
    return Dialog(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.title,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            GestureDetector(
              onTap: multi ? () => setState(() => _paused = !_paused) : null,
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: QrImageView(
                  data: _codes[_i],
                  version: QrVersions.auto,
                  size: size,
                  backgroundColor: Colors.white,
                  errorCorrectionLevel: QrErrorCorrectLevel.L,
                  gapless: true,
                ),
              ),
            ),
            if (multi) ...[
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    tooltip: 'Previous part',
                    icon: const Icon(Icons.chevron_left),
                    onPressed: () => setState(() {
                      _paused = true;
                      _i = (_i - 1 + _codes.length) % _codes.length;
                    }),
                  ),
                  Text(
                    'Part ${_i + 1} of ${_codes.length}',
                    style: theme.textTheme.titleSmall,
                  ),
                  IconButton(
                    tooltip: _paused ? 'Play' : 'Pause',
                    icon: Icon(_paused ? Icons.play_arrow : Icons.pause),
                    onPressed: () => setState(() => _paused = !_paused),
                  ),
                  IconButton(
                    tooltip: 'Next part',
                    icon: const Icon(Icons.chevron_right),
                    onPressed: () => setState(() {
                      _paused = true;
                      _i = (_i + 1) % _codes.length;
                    }),
                  ),
                ],
              ),
              Text(
                'The parts play in turn: keep the other phone pointed at '
                'the code until it has them all.',
                style: theme.textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ],
            const SizedBox(height: 12),
            Text(
              widget.instructions,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Done'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Scans a pad shown as QR (one plain code, or every part of a series) and
/// returns it as lowercase hex.
class OtpPadQrScanScreen extends StatefulWidget {
  const OtpPadQrScanScreen({super.key});

  @override
  State<OtpPadQrScanScreen> createState() => _OtpPadQrScanScreenState();
}

class _OtpPadQrScanScreenState extends State<OtpPadQrScanScreen> {
  final _pad = OtpPadQrAssembler();
  bool _done = false;
  DateTime _lastWarning = DateTime.fromMillisecondsSinceEpoch(0);

  void _warn(String text) {
    final now = DateTime.now();
    if (now.difference(_lastWarning) < const Duration(seconds: 3)) return;
    _lastWarning = now;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  void _onScanned(String data) {
    if (_done) return;
    switch (_pad.add(data)) {
      case OtpPadQrScan.complete:
        _done = true;
        Navigator.of(context).pop(_pad.result);
      case OtpPadQrScan.added:
        setState(() {});
      case OtpPadQrScan.repeat:
        break;
      case OtpPadQrScan.corrupt:
        setState(() {});
        _warn('The parts didn\'t check out. Starting over: scan them again.');
      case OtpPadQrScan.invalid:
        _warn('That QR code doesn\'t look like pad data');
    }
  }

  @override
  Widget build(BuildContext context) {
    final n = _pad.count;
    final String instructions;
    if (n <= 1) {
      instructions = 'Point the camera at the pad QR shown on the other device';
    } else {
      final missing = _pad.missing;
      instructions =
          'Got ${_pad.have} of $n parts. Keep the camera on the code'
          '${missing.length <= 6 ? ' (still need ${missing.join(', ')})' : ''}.';
    }
    return Scaffold(
      appBar: AppBar(
        title: const AdaptiveAppBarTitle('Scan OTP Pad'),
        centerTitle: true,
      ),
      body: Stack(
        children: [
          QrScannerWidget(
            onScanned: _onScanned,
            continuousScanning: true,
            debounceDuration: const Duration(seconds: 2),
            instructions: instructions,
          ),
          if (n > 1)
            Positioned(
              left: 24,
              right: 24,
              top: 16,
              child: LinearProgressIndicator(
                value: _pad.have / n,
                minHeight: 6,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
        ],
      ),
    );
  }
}
