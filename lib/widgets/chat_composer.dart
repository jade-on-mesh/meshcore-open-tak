import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../helpers/gif_helper.dart';
import '../l10n/l10n.dart';
import '../services/app_settings_service.dart';
import '../theme/mesh_theme.dart';
import 'byte_count_input.dart';
import 'gif_message.dart';
import 'gif_picker.dart';
import 'message_translation_button.dart';

/// One entry of the composer's "+" menu.
@immutable
class ChatComposerAction {
  final String id;
  final IconData icon;
  final String label;

  const ChatComposerAction({
    required this.id,
    required this.icon,
    required this.label,
  });
}

/// Opens the GIF picker and puts the chosen GIF into [controller].
void showChatGifPicker(BuildContext context, TextEditingController controller) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (context) => GifPicker(
      onGifSelected: (gifId) {
        controller.text = GifHelper.encodeGif(gifId);
      },
    ),
  );
}

/// Opens the outgoing-translation options sheet.
Future<void> showComposerTranslationOptions(BuildContext context) async {
  final settingsService = context.read<AppSettingsService>();
  final settings = settingsService.settings;
  await showMessageTranslationSheet(
    context: context,
    enabled: settings.composerTranslationEnabled,
    selectedLanguageCode: settings.translationTargetLanguageCode,
    onEnabledChanged: settingsService.setComposerTranslationEnabled,
    onLanguageSelected: settingsService.setTranslationTargetLanguageCode,
  );
}

/// The message composer shared by the direct and channel chat screens:
/// "+" action menu, optional translation toggle, byte-counted text field (or
/// GIF preview) and send button. [header] widgets (reply banner, progress)
/// are stacked above the row.
class ChatComposer extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final int maxBytes;
  final int? softLimitBytes;
  final String? softLimitNote;
  final String Function(String)? encoder;
  final VoidCallback onSend;
  final String sendTooltip;

  /// Builds the "+" menu entries when it is opened, so they reflect the
  /// current state (e.g. whether the radio has a position).
  final List<ChatComposerAction> Function() actionsBuilder;
  final ValueChanged<String> onAction;
  final List<Widget> header;

  /// MeshCore Open TAK: buttons after the "+" menu (photo, push-to-talk).
  final List<Widget> leading;

  /// MeshCore Open TAK: shown in the send button's place while there's
  /// nothing to send (the voice-message button), as messaging apps do.
  final Widget? idleTrailing;

  /// MeshCore Open TAK: the byte counter's text and colour (an OTP pad's
  /// remaining budget), passed to [ByteCountedTextField].
  final String Function(int usedBytes, int maxBytes)? counterTextBuilder;
  final Color Function(int usedBytes, int maxBytes, Color defaultColor)?
  counterColorBuilder;

  const ChatComposer({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.maxBytes,
    required this.onSend,
    required this.sendTooltip,
    required this.actionsBuilder,
    required this.onAction,
    this.softLimitBytes,
    this.softLimitNote,
    this.encoder,
    this.header = const [],
    this.leading = const [],
    this.idleTrailing,
    this.counterTextBuilder,
    this.counterColorBuilder,
  });

  Future<void> _openActionMenu(BuildContext buttonContext) async {
    final actions = actionsBuilder();
    if (actions.isEmpty) return;
    final button = buttonContext.findRenderObject() as RenderBox;
    final overlay =
        Overlay.of(buttonContext).context.findRenderObject() as RenderBox;
    final buttonOffset = button.localToGlobal(Offset.zero, ancestor: overlay);
    final menuHeight = actions.length * kMinInteractiveDimension + 16;
    final menuTop = (buttonOffset.dy - menuHeight).clamp(
      8.0,
      overlay.size.height,
    );
    final position = RelativeRect.fromLTRB(
      buttonOffset.dx,
      menuTop,
      overlay.size.width - buttonOffset.dx - button.size.width,
      overlay.size.height - buttonOffset.dy,
    );
    final selected = await showMenu<String>(
      context: buttonContext,
      position: position,
      // Keep focus on the text field: if the menu route took focus, the
      // keyboard would close, the composer would drop down and the menu would
      // be left floating where the keyboard used to be.
      requestFocus: false,
      items: [
        for (final action in actions)
          PopupMenuItem(
            value: action.id,
            child: Row(
              children: [
                Icon(action.icon),
                const SizedBox(width: 12),
                Flexible(child: Text(action.label)),
              ],
            ),
          ),
      ],
    );
    if (selected == null || !buttonContext.mounted) return;
    onAction(selected);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final translation = context
        .select<AppSettingsService, (bool, bool, String?)>(
          (s) => (
            s.settings.translationEnabled,
            s.settings.composerTranslationEnabled,
            s.settings.translationTargetLanguageCode,
          ),
        );
    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(top: BorderSide(color: scheme.outlineVariant, width: 1)),
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ...header,
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Builder(
                    builder: (buttonContext) => IconButton(
                      icon: const Icon(Icons.add_circle_outline),
                      tooltip: context.l10n.chat_selectSendAction,
                      onPressed: () => _openActionMenu(buttonContext),
                    ),
                  ),
                  _CollapsingButtons(
                    controller: controller,
                    focusNode: focusNode,
                    // A phone's width: folded until asked, so the field
                    // gets the room even before typing.
                    alwaysFold: MediaQuery.sizeOf(context).width < 600,
                    children: [
                      ...leading,
                      if (translation.$1)
                        MessageTranslationButton(
                          enabled: translation.$2,
                          languageCode: translation.$3,
                          onPressed: () =>
                              showComposerTranslationOptions(context),
                        ),
                    ],
                  ),
                  Expanded(
                    child: ValueListenableBuilder<TextEditingValue>(
                      valueListenable: controller,
                      builder: (context, value, _) {
                        final gifId = GifHelper.parseGif(value.text);
                        if (gifId != null) {
                          return _buildGifPreview(context, gifId, scheme);
                        }
                        return _buildTextField(context, scheme);
                      },
                    ),
                  ),
                  const SizedBox(width: 6),
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: controller,
                    builder: (context, value, _) {
                      final hasText = value.text.trim().isNotEmpty;
                      final idle = idleTrailing;
                      if (!hasText && idle != null) return idle;
                      return IconButton.filled(
                        icon: const Icon(Icons.send, size: 20),
                        tooltip: sendTooltip,
                        style: IconButton.styleFrom(
                          backgroundColor: hasText
                              ? scheme.primary
                              : scheme.surfaceContainerHighest,
                          foregroundColor: hasText
                              ? scheme.onPrimary
                              : scheme.onSurfaceVariant,
                          minimumSize: const Size(40, 40),
                          shape: const CircleBorder(),
                        ),
                        onPressed: hasText
                            ? () {
                                HapticFeedback.lightImpact();
                                onSend();
                              }
                            : null,
                      );
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGifPreview(
    BuildContext context,
    String gifId,
    ColorScheme scheme,
  ) {
    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.enter ||
                event.logicalKey == LogicalKeyboardKey.numpadEnter)) {
          onSend();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Row(
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: GifMessage(
                url: 'https://media.giphy.com/media/$gifId/giphy.gif',
                backgroundColor: scheme.surfaceContainerHighest,
                fallbackTextColor: scheme.onSurface.withValues(alpha: 0.6),
                maxSize: 160,
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: context.l10n.chat_removeGif,
            onPressed: () {
              controller.clear();
              focusNode.requestFocus();
            },
          ),
        ],
      ),
    );
  }

  Widget _buildTextField(BuildContext context, ColorScheme scheme) {
    OutlineInputBorder border(Color color, [double width = 1]) =>
        OutlineInputBorder(
          borderRadius: BorderRadius.circular(MeshRadii.md),
          borderSide: BorderSide(color: color, width: width),
        );
    // Grows with the message up to about a third of the room the keyboard
    // leaves (6 lines at most, 1 in landscape with the keyboard up), then
    // scrolls inside itself, so it never reaches under the keyboard or
    // pushes the chat off the screen.
    final media = MediaQuery.of(context);
    final room =
        media.size.height - media.viewInsets.bottom - media.padding.top;
    final maxLines = (room * 0.3 / 26).floor().clamp(1, 6);
    return ByteCountedTextField(
      maxBytes: maxBytes,
      maxLines: maxLines,
      softLimitBytes: softLimitBytes,
      softLimitNote: softLimitNote,
      controller: controller,
      focusNode: focusNode,
      hintText: context.l10n.chat_typeMessage,
      onSubmitted: (_) => onSend(),
      encoder: encoder,
      counterTextBuilder: counterTextBuilder,
      counterColorBuilder: counterColorBuilder,
      decoration: InputDecoration(
        hintText: context.l10n.chat_typeMessage,
        hintMaxLines: 1,
        border: border(scheme.outlineVariant),
        enabledBorder: border(scheme.outlineVariant),
        focusedBorder: border(scheme.primary, 1.5),
        filled: true,
        fillColor: scheme.surfaceContainerLow,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 18,
          vertical: 12,
        ),
      ),
    );
  }
}

/// MeshCore Open TAK: the buttons between "+" and the text field (photo,
/// push-to-talk, translation). Once there's text, or always on a phone's
/// width, they fold into one chevron so the field gets the width, as
/// messaging apps do; the chevron unfolds them until the text changes. The
/// voice-message button sits in the send button's place instead
/// ([ChatComposer.idleTrailing]), so it's always one tap away.
class _CollapsingButtons extends StatefulWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final List<Widget> children;

  /// Folded even with an empty field (narrow screens).
  final bool alwaysFold;

  const _CollapsingButtons({
    required this.controller,
    required this.focusNode,
    required this.children,
    this.alwaysFold = false,
  });

  @override
  State<_CollapsingButtons> createState() => _CollapsingButtonsState();
}

class _CollapsingButtonsState extends State<_CollapsingButtons> {
  bool _unfolded = false;
  String _textWhenUnfolded = '';

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    widget.focusNode.addListener(_changed);
  }

  @override
  void didUpdateWidget(_CollapsingButtons old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
    if (old.focusNode != widget.focusNode) {
      old.focusNode.removeListener(_changed);
      widget.focusNode.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    widget.focusNode.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    // Typing folds them away again.
    if (_unfolded && widget.controller.text != _textWhenUnfolded) {
      _unfolded = false;
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (widget.children.isEmpty) return const SizedBox.shrink();
    final folded =
        (widget.alwaysFold || widget.controller.text.isNotEmpty) &&
        !_unfolded &&
        widget.children.length > 1;
    return AnimatedSize(
      duration: const Duration(milliseconds: 150),
      alignment: Alignment.centerLeft,
      child: folded
          ? IconButton(
              icon: const Icon(Icons.chevron_right),
              tooltip: context.l10n.chat_showComposerButtons,
              onPressed: () => setState(() {
                _unfolded = true;
                _textWhenUnfolded = widget.controller.text;
              }),
            )
          : Row(mainAxisSize: MainAxisSize.min, children: widget.children),
    );
  }
}
