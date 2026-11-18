import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../theme/chat_look.dart';
import '../theme/mesh_theme.dart';

/// The "New messages" line above the first unread message, drawn the way the
/// chat style's app draws it (Settings > Appearance > Chat style).
class UnreadDivider extends StatelessWidget {
  const UnreadDivider({super.key});

  /// Discord's and mIRC's red.
  static const Color red = Color(0xFFF23F43);

  @override
  Widget build(BuildContext context) {
    final label = context.l10n.chat_newMessages;
    final dark = Theme.of(context).brightness == Brightness.dark;
    switch (MeshChatLook.of(context).style) {
      case ChatStyle.discord:
        // As in the Discord app: a thin red line either side of a red
        // "NEW MESSAGES" in capitals.
        final line = red.withValues(alpha: 0.6);
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            children: [
              Expanded(child: Container(height: 1, color: line)),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  label.toUpperCase(),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: dark ? const Color(0xFFF57F82) : red,
                    letterSpacing: 0.3,
                  ),
                ),
              ),
              Expanded(child: Container(height: 1, color: line)),
            ],
          ),
        );
      case ChatStyle.mirc:
        // mIRC's marker line: a plain red line across.
        return Semantics(
          label: label,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Container(height: 1.5, color: red),
          ),
        );
      case ChatStyle.signal:
        // A grey chip in the middle, no lines.
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: dark ? signalRecvNight : signalRecvDay,
                borderRadius: BorderRadius.circular(MeshRadii.pill),
              ),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: dark ? signalInkNight : signalInkDay,
                ),
              ),
            ),
          ),
        );
      case ChatStyle.iphone:
        // iMessage has no divider: a small grey caption, centred, as its
        // timestamps are.
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Center(
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: iphoneName,
              ),
            ),
          ),
        );
      case ChatStyle.icq:
        // A quiet grey rule with the words, as an old message window.
        final grey = dark ? const Color(0xFF8A8A8A) : const Color(0xFF808080);
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              Expanded(child: Container(height: 1, color: grey)),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(label, style: TextStyle(fontSize: 11, color: grey)),
              ),
              Expanded(child: Container(height: 1, color: grey)),
            ],
          ),
        );
      case ChatStyle.wadamesh:
        return _pill(context, const Color(0xFF4DD0C4), label);
      case ChatStyle.android:
        return _pill(
          context,
          dark ? androidSentInkNight : const Color(0xFF0B57D0),
          label,
        );
      case ChatStyle.standard:
      case ChatStyle.openClassic:
      case ChatStyle.classic:
        return _pill(context, Theme.of(context).colorScheme.primary, label);
      case ChatStyle.meshcore:
        // As in the MeshCore app: a thin red line either side of the words in
        // bold red, nearly edge to edge.
        final red = dark ? const Color(0xFFF44336) : const Color(0xFFD32F2F);
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
          child: Row(
            children: [
              Expanded(child: Container(height: 1, color: red)),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: red,
                    letterSpacing: 0.4,
                  ),
                ),
              ),
              Expanded(child: Container(height: 1, color: red)),
            ],
          ),
        );
    }
  }

  /// The app's own: a pill between two faint lines.
  static Widget _pill(BuildContext context, Color color, String label) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: Container(height: 1, color: color.withValues(alpha: 0.25)),
          ),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(MeshRadii.pill),
              border: Border.all(color: color.withValues(alpha: 0.35)),
            ),
            child: Text(
              label,
              style: MeshTheme.mono(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Container(height: 1, color: color.withValues(alpha: 0.25)),
          ),
        ],
      ),
    );
  }
}
