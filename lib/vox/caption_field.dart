// MeshCore Open TAK - caption for a photo or voice message.
//
// The caption rides in the same text message as the photo or clip's
// envelope (voice_wire.dart), so it has to fit beside it. The field shares
// the chat's own text box: whatever was typed before tapping the photo or
// mic button becomes the caption, and it is cleared once sent.

import 'dart:convert';

import 'package:flutter/material.dart';

import 'voice_wire.dart';

/// A chat's text box, offered as the caption for a photo or voice message.
class VoxCaptionInput {
  final TextEditingController controller;

  /// The chat's text message limit; the envelope takes some of it.
  final int maxTextBytes;

  const VoxCaptionInput(this.controller, {required this.maxTextBytes});

  int get maxBytes => voxCaptionMaxBytes(maxTextBytes);

  String get text => controller.text.trim();

  int get usedBytes => utf8.encode(text).length;

  bool get tooLong => usedBytes > maxBytes;
}

/// The caption box in a photo or voice send sheet.
class VoxCaptionField extends StatelessWidget {
  final VoxCaptionInput input;
  final bool enabled;

  const VoxCaptionField({super.key, required this.input, this.enabled = true});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: input.controller,
      builder: (context, _, _) {
        final used = input.usedBytes;
        return TextField(
          controller: input.controller,
          enabled: enabled,
          minLines: 1,
          maxLines: 3,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            hintText: 'Add a caption',
            isDense: true,
            border: const OutlineInputBorder(),
            counterText: used == 0 ? '' : '$used/${input.maxBytes} bytes',
            counterStyle: TextStyle(
              color: input.tooLong ? scheme.error : scheme.onSurfaceVariant,
            ),
            errorText: input.tooLong ? 'Too long to send with it' : null,
          ),
        );
      },
    );
  }
}
