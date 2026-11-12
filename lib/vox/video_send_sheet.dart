// MeshCore Open TAK - record or pick a short video, preview exactly what the
// receiver will see and hear, choose how much airtime to spend, send.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import 'caption_field.dart';
import 'video_codec.dart';
import 'video_player.dart';
import 'video_source.dart';
import 'voice_service.dart';
import 'voice_wire.dart';

/// Sends a video, with the caption typed in the sheet ('' for none).
typedef VoxVideoSend =
    Future<void> Function(VoxEncodedVideo video, String caption);

/// Camera/gallery -> preview sheet -> [onSend].
Future<void> showVoxVideoPicker(
  BuildContext context, {
  required String recipientLabel,
  required VoxVideoSend onSend,
  VoxCaptionInput? caption,
}) async {
  final voice = context.read<VoxVoiceService>();
  if (!VoxVideoSource.isSupported || !voice.videosAvailable) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Video messages can only be sent from Android and iPhone.'),
      ),
    );
    return;
  }
  final source = await showModalBottomSheet<ImageSource>(
    context: context,
    builder: (context) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(
                'Up to ${voxVideoMaxSeconds}s, sent small: about 160 px, '
                'like a photo\'s airtime. Phones on this app can play it.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.videocam_outlined),
              title: const Text('Record video'),
              onTap: () => Navigator.pop(context, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.video_library_outlined),
              title: const Text('Choose from gallery'),
              onTap: () => Navigator.pop(context, ImageSource.gallery),
            ),
          ],
        ),
      ),
    ),
  );
  if (source == null || !context.mounted) return;
  XFile? picked;
  try {
    picked = await ImagePicker().pickVideo(
      source: source,
      maxDuration: const Duration(seconds: voxVideoMaxSeconds),
    );
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Couldn\'t open the video: $e')));
    }
    return;
  }
  if (picked == null || !context.mounted) return;
  final path = picked.path;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => VoxVideoSendSheet(
      path: path,
      recipientLabel: recipientLabel,
      onSend: onSend,
      caption: caption,
    ),
  );
}

class VoxVideoSendSheet extends StatefulWidget {
  final String path;
  final String recipientLabel;
  final VoxVideoSend onSend;
  final VoxCaptionInput? caption;

  const VoxVideoSendSheet({
    super.key,
    required this.path,
    required this.recipientLabel,
    required this.onSend,
    this.caption,
  });

  @override
  State<VoxVideoSendSheet> createState() => _VoxVideoSendSheetState();
}

class _VoxVideoSendSheetState extends State<VoxVideoSendSheet> {
  VoxVideoDetail _detail = VoxVideoDetail.quick;
  bool _withSound = true;
  bool _reading = true;
  bool _encoding = false;
  bool _sending = false;
  String? _error;
  VoxPickedVideo? _picked;
  VoxEncodedVideo? _encoded;
  Uint8List? _previewWav;
  int _job = 0;
  final Map<(VoxVideoDetail, bool), VoxEncodedVideo> _cache = {};
  final Map<int, VoxEncodedClip?> _sounds = {};

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
    try {
      _picked = await VoxVideoSource.read(widget.path);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _reading = false;
        _error = 'Couldn\'t read this video: $e';
      });
      return;
    }
    if (!mounted) return;
    setState(() {
      _reading = false;
      _withSound = _picked!.sound != null;
    });
    await _encode();
  }

  Future<VoxEncodedClip?> _soundFor(VoxVoiceService voice, int seconds) async {
    if (_sounds.containsKey(seconds)) return _sounds[seconds];
    final pcm = _picked?.sound;
    final clip = pcm == null
        ? null
        : await voice.encodeVideoSound(pcm, seconds);
    return _sounds[seconds] = clip;
  }

  Future<void> _encode() async {
    final picked = _picked;
    if (picked == null) return;
    final key = (_detail, _withSound);
    final job = ++_job;
    setState(() {
      _encoding = true;
      _error = null;
    });
    final voice = context.read<VoxVoiceService>();
    try {
      var enc = _cache[key];
      if (enc == null) {
        final sound = _withSound
            ? await _soundFor(voice, _detail.maxSeconds)
            : null;
        enc = await voice.encodeVideo(picked.frames, _detail, sound: sound);
      }
      _cache[key] = enc;
      final wav = await voice.videoSoundPreview(enc);
      if (!mounted || job != _job) return;
      setState(() {
        _encoded = enc;
        _previewWav = wav;
        _encoding = false;
      });
    } catch (e) {
      if (!mounted || job != _job) return;
      setState(() {
        _encoding = false;
        _error = 'Couldn\'t encode this video: $e';
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
    super.dispose();
  }

  String _airFor(VoxVideoDetail d) {
    final packets = (d.budget / voxMaxCodecBytesPerPacket).ceil();
    final air = context.read<VoxVoiceService>().mediaAirtime(packets);
    if (air == null) return 'up to $packets packets';
    return 'up to $packets packets · ~${(air.inMilliseconds / 1000).round()}s '
        'air per hop';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enc = _encoded;
    final picked = _picked;
    final busy = _reading || _encoding;
    final soundNote = picked == null
        ? null
        : picked.sound == null
        ? 'This video has no sound.'
        : (_withSound && enc != null && enc.soundMode == null)
        ? 'The sound couldn\'t be coded here, so it goes silent.'
        : null;

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
                'Video to ${widget.recipientLabel}',
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Text(
                'Exactly what they\'ll see and hear. Tap to play.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 10),
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.4,
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      if (enc != null)
                        VoxVideoView(frames: enc.preview, wav: _previewWav)
                      else
                        AspectRatio(
                          aspectRatio: picked == null
                              ? 4 / 3
                              : picked.frames.width / picked.frames.height,
                          child: Container(
                            color: theme.colorScheme.surfaceContainer,
                          ),
                        ),
                      if (busy)
                        Positioned.fill(
                          child: Container(
                            color: Colors.black38,
                            alignment: Alignment.center,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const CircularProgressIndicator(),
                                const SizedBox(height: 8),
                                Text(
                                  _reading
                                      ? 'Reading the video…'
                                      : 'Fitting into ${_detail.budget} '
                                            'bytes…',
                                  style: const TextStyle(color: Colors.white),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  for (final d in VoxVideoDetail.values)
                    ChoiceChip(
                      label: Text(d.label),
                      selected: _detail == d,
                      onSelected: busy || picked == null
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
                  VoxVideoDetail.quick => 'Up to ${_detail.maxSeconds}s, a Sharp photo\'s airtime',
                  VoxVideoDetail.clear => 'Up to ${_detail.maxSeconds}s, 8× a voice message',
                  VoxVideoDetail.maximum => 'Up to ${_detail.maxSeconds}s, a Super Sharp photo\'s airtime',
                }}'
                ' · ${_airFor(_detail)}',
                style: theme.textTheme.bodySmall,
              ),
              if (picked?.sound != null)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Sound'),
                  subtitle: const Text(
                    'Coded like a voice message. Off gives the picture '
                    'all the bytes.',
                  ),
                  value: _withSound,
                  onChanged: busy
                      ? null
                      : (v) {
                          setState(() => _withSound = v);
                          unawaited(_encode());
                        },
                ),
              if (soundNote != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(soundNote, style: theme.textTheme.bodySmall),
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
                        '${enc.payload.length} bytes · '
                        '${enc.preview.width}×${enc.preview.height} at '
                        '${enc.preview.fps} fps · '
                        '${(enc.durationMs / 1000).toStringAsFixed(1)} s',
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
                    onPressed:
                        enc == null ||
                            busy ||
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
