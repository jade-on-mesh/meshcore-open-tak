// MeshCore Open TAK - AI sketch HD: the model download screen and the send
// sheet. See aeic_hd_service.dart for what AI sketch HD is.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../connector/meshcore_connector.dart';
import '../services/image_chunk_transport.dart';
import '../utils/lora_airtime.dart';
import '../widgets/image_send_codec_binding.dart';
import '../widgets/image_send_preview_sheet.dart';
import 'aeic_hd_service.dart';

String _mb(int bytes) => '${(bytes / (1024 * 1024)).round()} MB';

/// Download / remove the AI sketch HD model pack.
class AeicHdScreen extends StatelessWidget {
  const AeicHdScreen({super.key});

  static Future<void> open(BuildContext context) => Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => const AeicHdScreen()));

  @override
  Widget build(BuildContext context) {
    final hd = AeicHdService.instance;
    hd.init();
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('AI sketch HD')),
      body: ListenableBuilder(
        listenable: hd,
        builder: (context, _) {
          final ram = hd.totalMemory;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                'A third way to send a photo, next to Mesh photos and AI '
                'sketch. The picture is squeezed to about 1-2 KB (roughly '
                '8-15 packets) and redrawn by an image model on the '
                'receiving phone: far closer to the real photo than an AI '
                'sketch, still about half the airtime of a Mesh photo.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              Text(
                'The model is redrawing, not copying: small details, faces and '
                'text can come out invented. Drawing a received photo takes '
                'a few minutes, and uses about 550 MB of memory. Anyone who '
                'wants to see AI sketch HD photos needs this download too. '
                'Wadamesh radios can\'t show them.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 20),
              ..._status(context, hd),
              if (ram != null) ...[
                const SizedBox(height: 16),
                Text(
                  'This phone has ${(ram / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB of memory.',
                  style: theme.textTheme.bodySmall,
                ),
              ],
              const SizedBox(height: 16),
              Text(
                'AEIC (Shallow Encoder) by Z. Liu et al.; mobile codec by '
                'mikecarper. Model files are downloaded from this app\'s '
                'GitHub releases.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  List<Widget> _status(BuildContext context, AeicHdService hd) {
    switch (hd.state) {
      case AeicHdState.unsupported:
        return [const Text('AI sketch HD needs the Android app.')];
      case AeicHdState.notInstalled:
        return [
          if (hd.error != null) ...[
            Text(
              'Download stopped: ${hd.error}',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            const SizedBox(height: 8),
          ],
          FilledButton.icon(
            icon: const Icon(Icons.download),
            label: Text('Download model (${_mb(hd.packBytes)})'),
            onPressed: hd.install,
          ),
          const SizedBox(height: 6),
          const Text(
            'Use Wi-Fi. An interrupted download picks up where it left off.',
          ),
        ];
      case AeicHdState.downloading:
        return [
          LinearProgressIndicator(value: hd.progress),
          const SizedBox(height: 8),
          Text(
            'Downloading: ${(hd.progress * 100).toStringAsFixed(0)}% of '
            '${_mb(hd.packBytes)}',
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: hd.cancelInstall,
            child: const Text('Stop'),
          ),
        ];
      case AeicHdState.ready:
        return [
          const ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.check_circle_outline),
            title: Text('Installed'),
            subtitle: Text(
              'Choose "AI sketch HD" when you send a photo. Received AI '
              'sketch HD photos are drawn automatically.',
            ),
          ),
          if (hd.isBusy && hd.jobLabel != null) ...[
            LinearProgressIndicator(value: hd.jobProgress),
            const SizedBox(height: 6),
            Text('${hd.jobLabel}…'),
            const SizedBox(height: 8),
          ],
          const _SelfTestButton(),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.delete_outline),
            label: Text('Remove model (${_mb(hd.packBytes)})'),
            onPressed: hd.isBusy
                ? null
                : () async {
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (c) => AlertDialog(
                        title: const Text('Remove AI sketch HD?'),
                        content: const Text(
                          'You won\'t be able to send or see AI sketch HD '
                          'photos until you download it again.',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(c, false),
                            child: const Text('Keep'),
                          ),
                          TextButton(
                            onPressed: () => Navigator.pop(c, true),
                            child: const Text('Remove'),
                          ),
                        ],
                      ),
                    );
                    if (ok == true) await hd.remove();
                  },
          ),
        ];
    }
  }
}

/// Runs the phone check and shows its verdict.
class _SelfTestButton extends StatefulWidget {
  const _SelfTestButton();

  @override
  State<_SelfTestButton> createState() => _SelfTestButtonState();
}

class _SelfTestButtonState extends State<_SelfTestButton> {
  bool _running = false;
  String? _result;

  Future<void> _run() async {
    setState(() {
      _running = true;
      _result = null;
    });
    String result;
    try {
      result = await AeicHdService.instance.selfTest();
    } catch (e) {
      result = 'FAILED: $e';
    }
    if (!mounted) return;
    setState(() {
      _running = false;
      _result = result;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final result = _result;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OutlinedButton.icon(
          icon: const Icon(Icons.fact_check_outlined),
          label: const Text('Check this phone (a few minutes)'),
          onPressed: _running ? null : _run,
        ),
        if (result != null) ...[
          const SizedBox(height: 6),
          Text(
            result,
            style: TextStyle(
              color: result.startsWith('FAILED')
                  ? theme.colorScheme.error
                  : theme.colorScheme.primary,
            ),
          ),
        ],
      ],
    );
  }
}

/// Encodes [imageBytes] as AI sketch HD and shows its size and airtime.
/// Returns the result to send, or null if cancelled or it failed.
///
/// [parity]: the channel transport's XOR parity packet (channels yes, OTP
/// DMs no, which retry lost chunks instead).
Future<ImageSendPreviewResult?> showAeicHdSendSheet(
  BuildContext context, {
  required Uint8List imageBytes,
  bool parity = true,
}) async {
  final hd = AeicHdService.instance;
  await hd.init();
  if (!context.mounted) return null;
  if (!hd.isReady) {
    await AeicHdScreen.open(context);
    return null;
  }
  return showModalBottomSheet<ImageSendPreviewResult>(
    context: context,
    isScrollControlled: true,
    isDismissible: false,
    builder: (_) => _AeicHdSendSheet(imageBytes: imageBytes, parity: parity),
  );
}

class _AeicHdSendSheet extends StatefulWidget {
  final Uint8List imageBytes;
  final bool parity;
  const _AeicHdSendSheet({required this.imageBytes, required this.parity});

  @override
  State<_AeicHdSendSheet> createState() => _AeicHdSendSheetState();
}

class _AeicHdSendSheetState extends State<_AeicHdSendSheet> {
  Uint8List? _payload;
  String? _error;
  bool _cancelled = false;

  @override
  void initState() {
    super.initState();
    _encode();
  }

  Future<void> _encode() async {
    try {
      final rgb = await _square512Rgb(widget.imageBytes);
      final payload = await AeicHdService.instance.encode(rgb);
      if (!mounted || _cancelled) return;
      if (payload.length > kImageMaxPayloadBytes) {
        setState(
          () => _error =
              'This photo came out at ${payload.length} bytes, more than an '
              'image message can carry ($kImageMaxPayloadBytes). Try a '
              'simpler photo, or send it as a Mesh photo or AI sketch.',
        );
        return;
      }
      setState(() => _payload = payload);
    } catch (e) {
      if (!mounted || _cancelled) return;
      setState(() => _error = '$e');
    }
  }

  @override
  void dispose() {
    if (_payload == null && _error == null) {
      _cancelled = true;
      AeicHdService.instance.cancelEncode();
    }
    super.dispose();
  }

  SendEstimate _estimate(int bytes) {
    final connector = context.read<MeshCoreConnector>();
    return estimateSendFromRadioParams(
      payloadBytes: bytes,
      spreadingFactor: connector.currentSf,
      bandwidthHz: connector.currentBwHz,
      codingRate: connector.currentCr,
      parity: widget.parity,
    );
  }

  String _duration(Duration? d) {
    if (d == null) return 'unknown';
    final s = d.inSeconds;
    return s < 90 ? '$s s' : '${(s / 60).toStringAsFixed(1)} min';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hd = AeicHdService.instance;
    final payload = _payload;
    final estimate = payload == null ? null : _estimate(payload.length);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('AI sketch HD', style: theme.textTheme.titleLarge),
            const SizedBox(height: 12),
            Center(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.memory(
                  widget.imageBytes,
                  height: 200,
                  fit: BoxFit.contain,
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (_error != null)
              Text(_error!, style: TextStyle(color: theme.colorScheme.error))
            else if (payload == null)
              ListenableBuilder(
                listenable: hd,
                builder: (context, _) => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    LinearProgressIndicator(
                      value: hd.isBusy && hd.jobProgress > 0
                          ? hd.jobProgress
                          : null,
                    ),
                    const SizedBox(height: 6),
                    const Text('Compressing…'),
                  ],
                ),
              )
            else
              Text(
                '${payload.length} bytes, ${estimate!.chunkCount} packets'
                '${estimate.includesParity ? ' (with parity)' : ''}, '
                'about ${_duration(estimate.pacedWallClock)} to send. '
                'The receiving phone takes a few minutes to draw it.',
              ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: payload == null
                      ? null
                      : () => Navigator.pop(
                          context,
                          ImageSendPreviewResult(
                            payload: payload,
                            rate: ImageCodecRatePoint.hd,
                            includeParity: estimate!.includesParity,
                            packetCount: estimate.chunkCount,
                            airtime: estimate.totalAirtime,
                            wallClock: estimate.pacedWallClock,
                          ),
                        ),
                  child: const Text('Send'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// [imageBytes] stretched to 512x512 (the whole frame, like the other AEIC
/// option: the receiver un-stretches it from the aspect code), packed RGB.
Future<Uint8List> _square512Rgb(Uint8List imageBytes) async {
  final codec = await ui.instantiateImageCodec(
    imageBytes,
    targetWidth: 512,
    targetHeight: 512,
  );
  final frame = await codec.getNextFrame();
  final data = await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
  frame.image.dispose();
  codec.dispose();
  if (data == null) throw StateError('couldn\'t read the photo');
  final rgba = data.buffer.asUint8List();
  final rgb = Uint8List(512 * 512 * 3);
  for (var i = 0, o = 0; i < rgba.length; i += 4, o += 3) {
    rgb[o] = rgba[i];
    rgb[o + 1] = rgba[i + 1];
    rgb[o + 2] = rgba[i + 2];
  }
  return rgb;
}
