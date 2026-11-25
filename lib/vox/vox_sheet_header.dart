import 'package:characters/characters.dart';
import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../widgets/mesh_ui.dart';
import 'voice_wire.dart';

String _clip(String text, int max) =>
    text.characters.length > max ? '${text.characters.take(max)}…' : text;

/// The header of a message's long-press sheet. A photo, video or voice
/// message shows its kind and caption instead of the VOX envelope it travels
/// in; any other text shows its first 40 characters, as before.
///
/// [sender] is the subtitle for plain text, and for media without a caption.
BottomSheetHeader messageSheetHeader(
  BuildContext context, {
  required String text,
  String? sender,
}) {
  final env = VoxVoiceEnvelope.tryParse(text);
  if (env == null) {
    return BottomSheetHeader(title: _clip(text, 40), subtitle: sender);
  }
  final l10n = context.l10n;
  final scheme = Theme.of(context).colorScheme;
  final title = env.isImage
      ? l10n.chat_replyPhoto
      : env.isVideo
      ? l10n.chat_replyVideo(env.durationSeconds)
      : l10n.chat_replyVoice(env.durationSeconds);
  final caption = env.isTalk ? '' : env.caption.trim();
  return BottomSheetHeader(
    leading: Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(
        env.isImage
            ? Icons.photo_camera_outlined
            : env.isVideo
            ? Icons.videocam_outlined
            : Icons.mic_none,
        color: scheme.onPrimaryContainer,
        size: 22,
      ),
    ),
    title: title,
    subtitle: caption.isNotEmpty ? _clip(caption, 60) : sender,
  );
}
