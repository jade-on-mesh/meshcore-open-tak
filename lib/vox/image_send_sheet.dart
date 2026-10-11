// MeshCore Open VOX - pick or take a photo, preview exactly what the receiver
// will see, choose how much airtime to spend, send.

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../connector/meshcore_connector.dart';
import 'av1_ffi.dart';
import 'image_codec.dart';
import 'image_focus.dart';
import 'image_message_bubble.dart' show voxRgbToUiImage;
import 'voice_service.dart';
import 'voice_wire.dart';

/// Camera/gallery button for the chat input row.
class VoxImageButton extends StatelessWidget {
  final String recipientLabel;
  final Future<void> Function(VoxEncodedImage image) onSend;

  const VoxImageButton({
    super.key,
    required this.recipientLabel,
    required this.onSend,
  });

  Future<void> _start(BuildContext context) async {
    final voice = context.read<VoxVoiceService>();
    if (!voice.imagesAvailable) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Photo messages need the Android app.')),
      );
      return;
    }
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take photo'),
              onTap: () => Navigator.pop(context, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose from gallery'),
              onTap: () => Navigator.pop(context, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null || !context.mounted) return;
    XFile? picked;
    try {
      picked = await ImagePicker().pickImage(
        source: source,
        maxWidth: 2048,
        maxHeight: 2048,
        imageQuality: 95,
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Couldn\'t open the photo: $e')));
      }
      return;
    }
    if (picked == null || !context.mounted) return;
    VoxRgbImage ref;
    try {
      ref = await voxLoadReference(await picked.readAsBytes());
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Couldn\'t read that photo: $e')),
        );
      }
      return;
    }
    if (!context.mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => VoxImageSendSheet(
        reference: ref,
        recipientLabel: recipientLabel,
        onSend: onSend,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.add_photo_alternate_outlined),
      tooltip: 'Send a photo',
      onPressed: () => _start(context),
    );
  }
}

/// Decodes a picked file to the RGB reference picture (at most
/// [voxImageWorkSide] px on its long side).
Future<VoxRgbImage> voxLoadReference(Uint8List fileBytes) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(fileBytes);
  final desc = await ui.ImageDescriptor.encoded(buffer);
  final (w, h) = voxFitSize(desc.width, desc.height, voxImageWorkSide);
  final codec = await desc.instantiateCodec(targetWidth: w, targetHeight: h);
  final frame = await codec.getNextFrame();
  final data = await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final iw = frame.image.width, ih = frame.image.height;
  frame.image.dispose();
  codec.dispose();
  desc.dispose();
  buffer.dispose();
  if (data == null) throw StateError('no pixels');
  final rgba = data.buffer.asUint8List();
  final rgb = Uint8List(iw * ih * 3);
  for (var i = 0; i < iw * ih; i++) {
    rgb[i * 3] = rgba[i * 4];
    rgb[i * 3 + 1] = rgba[i * 4 + 1];
    rgb[i * 3 + 2] = rgba[i * 4 + 2];
  }
  return VoxRgbImage(iw, ih, rgb);
}

class VoxImageSendSheet extends StatefulWidget {
  final VoxRgbImage reference;
  final String recipientLabel;
  final Future<void> Function(VoxEncodedImage image) onSend;

  const VoxImageSendSheet({
    super.key,
    required this.reference,
    required this.recipientLabel,
    required this.onSend,
  });

  @override
  State<VoxImageSendSheet> createState() => _VoxImageSendSheetState();
}

class _VoxImageSendSheetState extends State<VoxImageSendSheet> {
  VoxImageDetail _detail = VoxImageDetail.standard;
  bool _useFocus = true;
  VoxFocusRegions _focus = VoxFocusRegions.none;
  bool _detecting = true;
  bool _encoding = false;
  bool _sending = false;
  bool _showOriginal = false;
  String? _error;
  VoxEncodedImage? _encoded;
  ui.Image? _preview;
  ui.Image? _original;
  int _job = 0;
  final Map<(VoxImageDetail, bool), VoxEncodedImage> _cache = {};

  @override
  void initState() {
    super.initState();
    unawaited(_init());
  }

  Future<void> _init() async {
    _original = await voxRgbToUiImage(widget.reference);
    final detector = VoxFocusDetector();
    try {
      _focus = await detector.detect(widget.reference);
    } finally {
      unawaited(detector.close());
    }
    if (!mounted) return;
    setState(() => _detecting = false);
    await _encode();
  }

  Future<void> _encode() async {
    final key = (_detail, _useFocus && !_focus.isEmpty);
    final job = ++_job;
    setState(() {
      _encoding = true;
      _error = null;
    });
    try {
      final enc =
          _cache[key] ??
          await context.read<VoxVoiceService>().encodeImage(
            widget.reference,
            _detail,
            focus: _focus,
            useFocus: _useFocus,
          );
      _cache[key] = enc;
      final img = await voxRgbToUiImage(enc.preview);
      if (!mounted || job != _job) {
        img.dispose();
        return;
      }
      setState(() {
        _preview?.dispose();
        _preview = img;
        _encoded = enc;
        _encoding = false;
      });
    } catch (e) {
      if (!mounted || job != _job) return;
      setState(() {
        _encoding = false;
        _error = 'Couldn\'t encode this photo: $e';
      });
    }
  }

  Future<void> _send() async {
    final enc = _encoded;
    if (enc == null) return;
    setState(() => _sending = true);
    try {
      await widget.onSend(enc);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _sending = false;
          _error = 'Send failed: $e';
        });
      }
    }
  }

  @override
  void dispose() {
    _preview?.dispose();
    _original?.dispose();
    super.dispose();
  }

  String _airFor(VoxImageDetail d) {
    final connector = context.read<MeshCoreConnector>();
    final sf = connector.currentSf, bw = connector.currentBwHz;
    final packets = (d.budget / voxMaxCodecBytesPerPacket).ceil();
    if (sf == null || bw == null || bw <= 0) return '$packets packets';
    final air = voxEstimateAirtime(
      totalPackets: packets,
      codecBytesPerPacket: voxMaxCodecBytesPerPacket,
      spreadingFactor: sf,
      bandwidthKhz: bw / 1000,
      codingRate: connector.currentCr ?? 5,
      pathLength: 0,
    );
    return '$packets packets · ~${(air.inMilliseconds / 1000).round()}s air';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enc = _encoded;
    final ref = widget.reference;
    final shown = _showOriginal ? _original : _preview;
    final faces = _focus.faces.length, texts = _focus.text.length;
    final focusLabel = [
      if (faces > 0) '$faces face${faces == 1 ? '' : 's'}',
      if (texts > 0) '$texts text area${texts == 1 ? '' : 's'}',
    ].join(', ');

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 12,
          bottom: 12 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Photo to ${widget.recipientLabel}',
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Text(
                _showOriginal
                    ? 'Original. Let go to see what they\'ll receive.'
                    : 'Exactly what they\'ll receive. Press and hold to compare '
                          'with the original.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 10),
              GestureDetector(
                onLongPressStart: (_) => setState(() => _showOriginal = true),
                onLongPressEnd: (_) => setState(() => _showOriginal = false),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(context).size.height * 0.45,
                  ),
                  child: AspectRatio(
                    aspectRatio: ref.width / ref.height,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Container(color: theme.colorScheme.surfaceContainer),
                          if (shown != null)
                            RawImage(
                              image: shown,
                              fit: BoxFit.contain,
                              filterQuality: FilterQuality.medium,
                            ),
                          if (_detecting || _encoding)
                            Container(
                              color: Colors.black26,
                              alignment: Alignment.center,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const CircularProgressIndicator(),
                                  const SizedBox(height: 8),
                                  Text(
                                    _detecting
                                        ? 'Finding text and faces…'
                                        : 'Fitting into ${_detail.budget} bytes…',
                                    style: const TextStyle(color: Colors.white),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  for (final d in VoxImageDetail.values)
                    ChoiceChip(
                      label: Text(d.label),
                      selected: _detail == d,
                      onSelected: _encoding || _detecting
                          ? null
                          : (_) {
                              setState(() => _detail = d);
                              unawaited(_encode());
                            },
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '${_detail.multiple == 1 ? 'Same airtime as one voice message' : '${_detail.multiple}× a voice message'}'
                ' · ${_airFor(_detail)}',
                style: theme.textTheme.bodySmall,
              ),
              if (!_focus.isEmpty)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Sharpen text and faces'),
                  subtitle: Text(
                    'Found $focusLabel. Spends more of the bytes there and '
                    'softens the background slightly.',
                  ),
                  value: _useFocus,
                  onChanged: _encoding
                      ? null
                      : (v) {
                          setState(() => _useFocus = v);
                          unawaited(_encode());
                        },
                ),
              if (enc != null && enc.smallTextAtRisk && !_encoding)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Row(
                    children: [
                      Icon(
                        Icons.text_fields,
                        size: 18,
                        color: theme.colorScheme.tertiary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _detail == VoxImageDetail.more
                              ? 'Small text may still be hard to read.'
                              : 'Small text may not be readable. '
                                    'More detail would help.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.tertiary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    _error!,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ),
              const SizedBox(height: 12),
              Row(
                children: [
                  if (enc != null)
                    Expanded(
                      child: Text(
                        '${enc.payload.length} bytes · sent at '
                        '${enc.preview.width}×${enc.preview.height}',
                        style: theme.textTheme.bodySmall,
                      ),
                    )
                  else
                    const Spacer(),
                  TextButton(
                    onPressed: _sending ? null : () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    icon: _sending
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send),
                    label: const Text('Send'),
                    onPressed: enc == null || _encoding || _sending
                        ? null
                        : _send,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
