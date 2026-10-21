// MeshCore Open TAK - share by sound: a "Play by sound" button next to a
// share QR code, and a sheet that listens for one (scanners' "Listen").

import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import 'sound_link.dart';

/// Plays [data] (a share link) as sound, for a device that can't scan the
/// QR code beside it (a T-Deck has no camera).
class SoundShareButton extends StatefulWidget {
  final String data;
  const SoundShareButton({super.key, required this.data});

  @override
  State<SoundShareButton> createState() => _SoundShareButtonState();
}

class _SoundShareButtonState extends State<SoundShareButton> {
  bool _playing = false;

  Future<void> _play() async {
    setState(() => _playing = true);
    try {
      await SoundLink.instance.play(widget.data);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.sound_playFailed('$e'))),
        );
      }
    } finally {
      if (mounted) setState(() => _playing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!SoundLink.instance.available) return const SizedBox.shrink();
    final l10n = context.l10n;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        OutlinedButton.icon(
          onPressed: _playing ? null : _play,
          icon: _playing
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.graphic_eq),
          label: Text(_playing ? l10n.sound_playing : l10n.sound_playByShare),
        ),
        const SizedBox(height: 4),
        Text(
          l10n.sound_playByShareHelp,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

/// Listens until something [accept] takes is heard, then returns it (null:
/// closed first).
Future<String?> showSoundListenSheet(
  BuildContext context, {
  required bool Function(String heard) accept,
}) {
  return showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (_) => _ListenSheet(accept: accept),
  );
}

class _ListenSheet extends StatefulWidget {
  final bool Function(String heard) accept;
  const _ListenSheet({required this.accept});

  @override
  State<_ListenSheet> createState() => _ListenSheetState();
}

class _ListenSheetState extends State<_ListenSheet> {
  StreamSubscription<String>? _sub;
  String? _error;
  String? _other; // heard, but not something this screen takes

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      final s = await SoundLink.instance.listen();
      _sub = s.listen((heard) {
        if (!mounted) return;
        if (widget.accept(heard)) {
          Navigator.of(context).pop(heard);
        } else {
          setState(() => _other = heard);
        }
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    unawaited(SoundLink.instance.stopListening());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.hearing, size: 48, color: theme.colorScheme.primary),
            const SizedBox(height: 12),
            Text(l10n.sound_listening, style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              _error ?? l10n.sound_listeningHelp,
              textAlign: TextAlign.center,
              style: _error == null
                  ? theme.textTheme.bodySmall
                  : TextStyle(color: theme.colorScheme.error),
            ),
            if (_other != null) ...[
              const SizedBox(height: 8),
              Text(
                l10n.sound_heardOther(_other!),
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
            ],
            if (_error == null) ...[
              const SizedBox(height: 16),
              const LinearProgressIndicator(),
            ],
          ],
        ),
      ),
    );
  }
}
