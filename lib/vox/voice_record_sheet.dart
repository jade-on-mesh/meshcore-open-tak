// MeshCore Open VOX - record / preview / send sheet for voice messages.

import 'dart:async';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';

import 'mimi.dart';
import 'resample.dart';
import 'voice_message_bubble.dart' show showVoxVoiceLog;
import 'voice_service.dart';

/// Mic button for a chat composer. Hidden when no voice codec is available.
class VoxMicButton extends StatelessWidget {
  final Future<void> Function(VoxEncodedClip clip) onSend;
  final String? recipientLabel;

  const VoxMicButton({super.key, required this.onSend, this.recipientLabel});

  @override
  Widget build(BuildContext context) {
    final voice = context.watch<VoxVoiceService>();
    if (!voice.isAvailable) return const SizedBox.shrink();
    return IconButton(
      icon: const Icon(Icons.mic_none),
      tooltip: 'Voice message',
      onPressed: () => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (_) =>
            VoxRecordSheet(onSend: onSend, recipientLabel: recipientLabel),
      ),
    );
  }
}

class VoxRecordSheet extends StatefulWidget {
  final Future<void> Function(VoxEncodedClip clip) onSend;
  final String? recipientLabel;

  const VoxRecordSheet({super.key, required this.onSend, this.recipientLabel});

  @override
  State<VoxRecordSheet> createState() => _VoxRecordSheetState();
}

enum _Phase { idle, recording, encoding, recorded, sending }

class _VoxRecordSheetState extends State<VoxRecordSheet> {
  final AudioRecorder _recorder = AudioRecorder();
  final AudioPlayer _player = AudioPlayer();
  final BytesBuilder _pcmBytes = BytesBuilder(copy: false);
  StreamSubscription<Uint8List>? _sub;
  Timer? _ticker;
  _Phase _phase = _Phase.idle;
  Duration _elapsed = Duration.zero;
  VoxEncodedClip? _clip;
  bool _previewing = false;
  String? _error;

  static const _max = VoxVoiceService.maxClipLength;
  VoxVoiceService? _voice;
  Future<Uint8List>? _previewWav;

  @override
  void initState() {
    super.initState();
    // Nothing auto-plays while the recorder is open.
    _voice = context.read<VoxVoiceService>()..micBusy = true;
  }

  Future<void> _start() async {
    setState(() => _error = null);
    if (!await _recorder.hasPermission()) {
      setState(() => _error = 'Microphone permission denied');
      return;
    }
    _pcmBytes.clear();
    final stream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: voxRecordSampleRate,
        numChannels: 1,
        autoGain: true,
        noiseSuppress: true,
      ),
    );
    _sub = stream.listen(_pcmBytes.add);
    final started = DateTime.now();
    _ticker = Timer.periodic(const Duration(milliseconds: 200), (_) {
      final e = DateTime.now().difference(started);
      setState(() => _elapsed = e);
      if (e >= _max) _stop();
    });
    setState(() => _phase = _Phase.recording);
  }

  Future<void> _stop() async {
    if (_phase != _Phase.recording) return;
    _ticker?.cancel();
    await _recorder.stop();
    await _sub?.cancel();
    final bytes = _pcmBytes.takeBytes();
    final bd = ByteData.sublistView(bytes);
    final pcm = Int16List(bytes.length ~/ 2);
    for (var i = 0; i < pcm.length; i++) {
      pcm[i] = bd.getInt16(i * 2, Endian.little);
    }
    if (pcm.length < voxRecordSampleRate ~/ 4) {
      setState(() {
        _phase = _Phase.idle;
        _error = 'Too short';
      });
      return;
    }
    if (!mounted) return;
    setState(() => _phase = _Phase.encoding);
    try {
      final clip = await context.read<VoxVoiceService>().encodeRecording(pcm);
      if (!mounted) return;
      // Start decoding the preview now so Play is instant.
      _previewWav = context.read<VoxVoiceService>().previewWav(clip)
        ..ignore();
      setState(() {
        _clip = clip;
        _phase = _Phase.recorded;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.idle;
        _error = 'Could not encode: $e';
      });
    }
  }

  Future<void> _preview() async {
    final clip = _clip;
    if (clip == null || _previewing) return;
    setState(() => _previewing = true);
    try {
      // Preview what the listener will actually hear: decode the sent bits.
      final wav = await (_previewWav ??= context
          .read<VoxVoiceService>()
          .previewWav(clip));
      await _player.play(BytesSource(wav));
    } catch (e) {
      if (mounted) setState(() => _error = 'Preview failed: $e');
    } finally {
      if (mounted) setState(() => _previewing = false);
    }
  }

  Future<void> _send() async {
    final clip = _clip;
    if (clip == null) return;
    setState(() => _phase = _Phase.sending);
    try {
      await widget.onSend(clip);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _phase = _Phase.recorded;
          _error = 'Send failed: $e';
        });
      }
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _sub?.cancel();
    _recorder.dispose();
    _player.dispose();
    _voice?.micBusy = false;
    super.dispose();
  }

  String _fmt(Duration d) =>
      '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final voice = context.watch<VoxVoiceService>();
    final mode = _clip?.mode ?? voice.sendMode;
    final recording = _phase == _Phase.recording;
    final clip = _clip;
    final packets = clip == null
        ? 0
        : (clip.bits.length / mode.bytesPerPacket).ceil();
    final codecLine = mode.isMimi
        ? 'Mimi · ~1.1 kb/s'
        : 'Codec2 ${mode.label} bps';
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.recipientLabel == null
                  ? 'Voice message'
                  : 'Voice message to ${widget.recipientLabel}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              '$codecLine · max ${_max.inSeconds}s · '
              'listeners download it when they press play',
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
            Wrap(
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              children: [
                if (voice.forcedRoute != null)
                  Chip(
                    avatar: const Icon(Icons.alt_route, size: 16),
                    label: Text(
                      'Testing: forced via ${voice.forcedRouteLabel()}',
                    ),
                  ),
                if (voice.preferMimi && !voice.mimi.isReady)
                  ActionChip(
                    avatar: const Icon(Icons.graphic_eq, size: 16),
                    label: Text(
                      voice.mimi.state == VoxMimiState.downloading
                          ? 'Downloading Mimi voice '
                                '${(voice.mimi.progress * 100).round()}%'
                          : 'Clearer voice: get Mimi',
                    ),
                    onPressed: () => showVoxVoiceLog(context, voice),
                  ),
                TextButton.icon(
                  icon: const Icon(Icons.tune, size: 18),
                  label: const Text('Voice settings'),
                  onPressed: () => showVoxVoiceLog(context, voice),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              recording
                  ? '${_fmt(_elapsed)} / ${_fmt(_max)}'
                  : _phase == _Phase.encoding
                  ? 'Encoding…'
                  : clip == null
                  ? 'Tap to record'
                  : '${clip.durationSeconds}s · $packets packet'
                        '${packets == 1 ? '' : 's'}',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            if (recording)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: LinearProgressIndicator(
                  value: _elapsed.inMilliseconds / _max.inMilliseconds,
                ),
              ),
            if (_phase == _Phase.encoding)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: LinearProgressIndicator(),
              ),
            const SizedBox(height: 20),
            if (_phase == _Phase.idle || recording)
              IconButton.filled(
                iconSize: 40,
                style: IconButton.styleFrom(
                  backgroundColor: recording ? scheme.error : scheme.primary,
                  minimumSize: const Size(72, 72),
                ),
                icon: Icon(recording ? Icons.stop : Icons.mic),
                onPressed: recording ? _stop : _start,
              )
            else if (_phase != _Phase.encoding)
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  TextButton.icon(
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Discard'),
                    onPressed: _phase == _Phase.sending
                        ? null
                        : () => setState(() {
                            _clip = null;
                            _previewWav = null;
                            _phase = _Phase.idle;
                          }),
                  ),
                  OutlinedButton.icon(
                    icon: _previewing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.play_arrow),
                    label: const Text('Play'),
                    onPressed: _phase == _Phase.sending ? null : _preview,
                  ),
                  FilledButton.icon(
                    icon: _phase == _Phase.sending
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send),
                    label: const Text('Send'),
                    onPressed: _phase == _Phase.sending ? null : _send,
                  ),
                ],
              ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: scheme.error)),
            ],
          ],
        ),
      ),
    );
  }
}
