// MeshCore Open TAK - pick or take a photo, preview exactly what the receiver
// will see, choose how much airtime to spend, send.

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import 'aeic_hd_screens.dart';
import 'aeic_hd_service.dart';
import 'av1_ffi.dart';
import 'caption_field.dart';
import 'image_codec.dart';
import 'image_focus.dart';
import 'image_message_bubble.dart' show voxRgbToUiImage;
import 'voice_service.dart';
import 'voice_wire.dart';

/// The other way to send a picture: AI sketch HD (aeic_hd_service.dart),
/// about 1-2 KB, redrawn by an image model on the receiving device. MeshCore
/// Open's ~150-byte AI sketch (AEIC ft32) is no longer offered: too far from
/// the real photo to be worth sending.
class VoxAiSketchOption {
  /// Encodes and sends the picked file as an AI sketch HD.
  final Future<void> Function(Uint8List bytes, int fileBytes) sendHd;

  const VoxAiSketchOption({required this.sendHd});
}

/// Sends a Mesh photo, with the caption typed in the sheet ('' for none).
typedef VoxImageSend =
    Future<void> Function(VoxEncodedImage image, String caption);

/// Camera/gallery button for the chat input row.
class VoxImageButton extends StatelessWidget {
  final String recipientLabel;
  final VoxImageSend onSend;

  /// The chat's text box, offered as the photo's caption; null for none.
  final VoxCaptionInput? caption;

  /// Offer AEIC as well (chats that can carry it); null: Mesh photos only.
  final VoxAiSketchOption? aiSketch;

  const VoxImageButton({
    super.key,
    required this.recipientLabel,
    required this.onSend,
    this.aiSketch,
    this.caption,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.add_photo_alternate_outlined),
      tooltip: 'Send a photo',
      onPressed: () => showVoxImagePicker(
        context,
        recipientLabel: recipientLabel,
        onSend: onSend,
        aiSketch: aiSketch,
        caption: caption,
      ),
    );
  }
}

/// Camera/gallery -> preview sheet -> [onSend]. Also used for photos
/// attached to team pins and reports.
Future<void> showVoxImagePicker(
  BuildContext context, {
  required String recipientLabel,
  required VoxImageSend onSend,
  String sendLabel = 'Send',
  VoxAiSketchOption? aiSketch,
  VoxCaptionInput? caption,
}) async {
  final voice = context.read<VoxVoiceService>();
  if (!voice.imagesAvailable && aiSketch == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Photo messages are not in this build of the app.'),
      ),
    );
    return;
  }
  // Windows, Linux and macOS: no camera here, so straight to choosing a file
  // (image_picker opens the system file chooser), unless there is a kind of
  // photo to choose first.
  final desktop =
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.linux ||
          defaultTargetPlatform == TargetPlatform.macOS);
  final source = desktop && aiSketch == null
      ? ImageSource.gallery
      : await showModalBottomSheet<ImageSource>(
          context: context,
          builder: (context) => SafeArea(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (aiSketch != null) const _PhotoKindChooser(),
                  if (!desktop)
                    ListTile(
                      leading: const Icon(Icons.photo_camera_outlined),
                      title: const Text('Take photo'),
                      onTap: () => Navigator.pop(context, ImageSource.camera),
                    ),
                  ListTile(
                    leading: const Icon(Icons.photo_library_outlined),
                    title: Text(
                      desktop ? 'Choose a picture' : 'Choose from gallery',
                    ),
                    onTap: () => Navigator.pop(context, ImageSource.gallery),
                  ),
                ],
              ),
            ),
          ),
        );
  if (source == null || !context.mounted) return;
  final sketch =
      aiSketch != null && (voice.photoAiSketch || !voice.imagesAvailable);
  if (sketch) {
    await AeicHdService.instance.init();
    if (!context.mounted) return;
    if (!AeicHdService.instance.isReady) {
      await AeicHdScreen.open(context);
      return;
    }
  }
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
  if (sketch) {
    final Uint8List bytes;
    final int fileBytes;
    try {
      bytes = await picked.readAsBytes();
      fileBytes = await picked.length();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Couldn\'t read that photo: $e')),
        );
      }
      return;
    }
    await aiSketch.sendHd(bytes, fileBytes);
    return;
  }
  VoxRgbImage ref;
  try {
    ref = await voxLoadReference(await picked.readAsBytes());
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Couldn\'t read that photo: $e')));
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
      sendLabel: sendLabel,
      caption: caption,
    ),
  );
}

/// Decodes a picked file to the RGB reference picture (at most
/// [voxImageMaxWorkSide] px on its long side; levels below Super Sharp scale
/// it to [voxImageWorkSide] when they encode).
Future<VoxRgbImage> voxLoadReference(Uint8List fileBytes) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(fileBytes);
  final desc = await ui.ImageDescriptor.encoded(buffer);
  final (w, h) = voxFitSize(desc.width, desc.height, voxImageMaxWorkSide);
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
  final VoxImageSend onSend;
  final String sendLabel;
  final VoxCaptionInput? caption;

  const VoxImageSendSheet({
    super.key,
    required this.reference,
    required this.recipientLabel,
    required this.onSend,
    this.sendLabel = 'Send',
    this.caption,
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
    widget.caption?.controller.addListener(_captionChanged);
    unawaited(_init());
  }

  void _captionChanged() {
    if (mounted) setState(() {});
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
    final caption = widget.caption;
    setState(() => _sending = true);
    try {
      await widget.onSend(enc, caption?.text ?? '');
      caption?.controller.clear();
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
    widget.caption?.controller.removeListener(_captionChanged);
    _preview?.dispose();
    _original?.dispose();
    super.dispose();
  }

  String _airFor(VoxImageDetail d) {
    final packets = (d.budget / voxMaxCodecBytesPerPacket).ceil();
    // On MediaMesh's radio2 when photos go there, else the main radio.
    final air = context.read<VoxVoiceService>().mediaAirtime(packets);
    if (air == null) return '$packets packets';
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
                '${switch (_detail) {
                  VoxImageDetail.standard => 'Same airtime as one voice message',
                  VoxImageDetail.more => '2× a voice message',
                  VoxImageDetail.sharp => 'About 2× the resolution, 4× a voice message',
                  VoxImageDetail.superSharp => 'Up to 1024 px, 14× a voice message',
                }}'
                ' · ${_airFor(_detail)}',
                style: theme.textTheme.bodySmall,
              ),
              if (!_focus.isEmpty)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Sharpen text and faces'),
                  subtitle: Text(
                    _detail.backgroundSoften == null
                        ? 'Found $focusLabel. Picks the size that keeps them '
                              'clearest; the background keeps its detail.'
                        : 'Found $focusLabel. Spends more of the bytes there '
                              'and softens the background slightly.',
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
                          switch (_detail) {
                            VoxImageDetail.superSharp =>
                              'Small text may still be hard to read.',
                            VoxImageDetail.sharp =>
                              'Small text may still be hard to read.',
                            VoxImageDetail.more =>
                              'Small text may still be hard to read. '
                                  'Sharp would help.',
                            VoxImageDetail.standard =>
                              'Small text may not be readable. '
                                  'More detail or Sharp would help.',
                          },
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
              if (widget.caption != null) ...[
                const SizedBox(height: 12),
                VoxCaptionField(input: widget.caption!, enabled: !_sending),
              ],
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
                    label: Text(widget.sendLabel),
                    onPressed:
                        enc == null ||
                            _encoding ||
                            _sending ||
                            (widget.caption?.tooLong ?? false)
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

/// Mesh photo (default) or AI sketch HD, remembered like the Mimi choice
/// (VoxVoiceService.photoAiSketch).
enum _PhotoKind { vox, hd }

class _PhotoKindChooser extends StatelessWidget {
  const _PhotoKindChooser();

  @override
  Widget build(BuildContext context) {
    final voice = context.watch<VoxVoiceService>();
    final sketch = voice.photoAiSketch || !voice.imagesAvailable;
    final kind = sketch ? _PhotoKind.hd : _PhotoKind.vox;
    final theme = Theme.of(context);
    final String about;
    switch (kind) {
      case _PhotoKind.vox:
        about =
            'Real pixels, about 2.7 KB (up to 11 KB at Sharp). Everyone '
            'can view it, Wadamesh radios included. The default.';
      case _PhotoKind.hd:
        about =
            'AEIC HD, about 1-2 KB (8-15 packets), redrawn by an image '
            'model: half the airtime of a Mesh photo. The '
            'receiver\'s phone takes a few minutes to draw it and needs the '
            'AI sketch HD model; radios can\'t show it. In channels it goes '
            'on MediaMesh (radio2), like Mesh photos.';
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SegmentedButton<_PhotoKind>(
            segments: [
              const ButtonSegment(
                value: _PhotoKind.vox,
                icon: Icon(Icons.photo_outlined),
                label: Text('Mesh photo'),
              ),
              const ButtonSegment(
                value: _PhotoKind.hd,
                icon: Icon(Icons.hd_outlined),
                label: Text('AI sketch HD'),
              ),
            ],
            selected: {kind},
            onSelectionChanged: (s) {
              final k = s.first;
              if (k == _PhotoKind.vox && !voice.imagesAvailable) return;
              voice.setPhotoAiSketch(k == _PhotoKind.hd);
            },
          ),
          const SizedBox(height: 6),
          Text(
            about,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (kind == _PhotoKind.hd)
            ListenableBuilder(
              listenable: AeicHdService.instance,
              builder: (context, _) => AeicHdService.instance.isReady
                  ? const SizedBox.shrink()
                  : Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        icon: const Icon(Icons.download, size: 18),
                        label: const Text('Set up AI sketch HD'),
                        onPressed: () => AeicHdScreen.open(context),
                      ),
                    ),
            ),
        ],
      ),
    );
  }
}
