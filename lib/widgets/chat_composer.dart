import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../helpers/gif_helper.dart';
import '../l10n/l10n.dart';
import '../services/app_settings_service.dart';
import '../theme/chat_look.dart';
import '../theme/mesh_theme.dart';
import '../utils/radio_guard.dart';
import 'byte_count_input.dart';
import 'chat_chrome.dart';
import 'connect_sheet.dart';
import 'emoji_picker.dart';
import 'gif_message.dart';
import 'gif_picker.dart';
import 'mesh_ui.dart';
import 'message_translation_button.dart';
import '../theme/theme_icons.dart';

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
  showMeshSheet<void>(
    context,
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

  /// Shown above the field, usually a [ChatComposerQuote] (upstream's reply
  /// preview); before [header].
  final Widget? replyPreview;

  /// Marks the composer (upstream tests find it by this key).
  static const bubbleKey = ValueKey('chat-composer-bubble');

  /// Marks the "+" menu (upstream tests find it by this key).
  static const actionMenuKey = ValueKey('chat-composer-action-menu');

  /// MeshCore Open TAK: shown in the send button's place while there's
  /// nothing to send (the voice-message button), as messaging apps do.
  final Widget? idleTrailing;

  /// MeshCore Open TAK: the byte counter's text and colour (an OTP pad's
  /// remaining budget), passed to [ByteCountedTextField].
  final String Function(int usedBytes, int maxBytes)? counterTextBuilder;
  final Color Function(int usedBytes, int maxBytes, Color defaultColor)?
  counterColorBuilder;

  /// Who the message goes to, as the field's hint names it in the Discord
  /// style ("Message #gaming", "Message @Ana").
  final String? hintTarget;

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
    this.replyPreview,
    this.idleTrailing,
    this.counterTextBuilder,
    this.counterColorBuilder,
    this.hintTarget,
  });

  /// MeshCore Open TAK: everything the composer offers is in the one "+"
  /// menu (photo, walkie-talkie, GIF, location, contact, translation), not
  /// split between "+" and a row of buttons folded behind ">".
  Future<void> _openActionMenu(BuildContext buttonContext) async {
    final settings = buttonContext.read<AppSettingsService>().settings;
    final actions = [
      ...actionsBuilder(),
      if (settings.translationEnabled)
        ChatComposerAction(
          id: _translateAction,
          icon: settings.composerTranslationEnabled
              ? Icons.translate
              : Icons.translate_outlined,
          label: buttonContext.l10n.translation_translationOptions,
        ),
    ];
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
            child: MeshMenuItemRow(icon: action.icon, label: action.label),
          ),
      ],
    );
    if (selected == null || !buttonContext.mounted) return;
    if (selected == _translateAction) {
      await showComposerTranslationOptions(buttonContext);
      return;
    }
    onAction(selected);
  }

  static const _translateAction = '_translate';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Offline the chat is read-only. The draft stays in [controller] (owned
    // by the screen) and is back when the radio reconnects.
    if (context.radioReadOnly) return const OfflineComposerBar();
    final look = ChatComposerLook.of(context);
    if (!look.isPlain) {
      return KeyedSubtree(
        key: ChatComposer.bubbleKey,
        child: _buildStyled(context, look),
      );
    }
    return Container(
      key: ChatComposer.bubbleKey,
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(top: BorderSide(color: scheme.outlineVariant, width: 1)),
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (replyPreview != null) replyPreview!,
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
                        icon: const ThemedIcon(ThemeIconSlot.send, size: 20),
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

  /// Puts [text] where the cursor is (or at the end), replacing a selection.
  void _insert(String text) {
    final value = controller.value;
    final sel = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    controller.value = TextEditingValue(
      text: value.text.replaceRange(sel.start, sel.end, text),
      selection: TextSelection.collapsed(offset: sel.start + text.length),
    );
  }

  /// Discord's mobile composer: one rounded field with "+" on the left and
  /// GIF, emoji and the mic on the right; once there's text, the mic gives
  /// way to the blurple send button. Its own colours, the bar's edges.
  Widget _buildAllInside(BuildContext context, ChatComposerLook look) {
    final scheme = Theme.of(context).colorScheme;
    final bar = MeshChatLook.of(context).background(dark: look.dark);
    final ink = look.iconInk;
    Widget icon(IconData data, String tip, VoidCallback onTap) => IconButton(
      icon: Icon(data, size: 26, color: ink),
      tooltip: tip,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints.tightFor(width: 42, height: 42),
      padding: EdgeInsets.zero,
      onPressed: onTap,
    );
    // Discord's send button: a blurple rounded square.
    Widget discordSend() => Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 3),
      child: IconButton.filled(
        icon: const Icon(Icons.send, size: 20, color: Colors.white),
        tooltip: sendTooltip,
        style: IconButton.styleFrom(
          backgroundColor: discordBlurple,
          minimumSize: const Size.square(36),
          maximumSize: const Size.square(36),
          padding: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
        onPressed: () {
          HapticFeedback.lightImpact();
          onSend();
        },
      ),
    );
    final field = ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        final gifId = GifHelper.parseGif(value.text);
        // The send button lives in the field, which the GIF takes the
        // place of: it goes beside the GIF (a phone has no Enter key).
        if (gifId != null) {
          return _buildGifPreview(context, gifId, scheme, send: discordSend());
        }
        final hasText = value.text.trim().isNotEmpty;
        final idle = idleTrailing;
        // As Discord's app: with text typed, the GIF button and the mic make
        // way for the send button, so the text has the field's width, and
        // the buttons sit by the last line as the text grows.
        Widget frame(Widget text) => DecoratedBox(
          decoration: BoxDecoration(
            color: look.fill,
            borderRadius: BorderRadius.circular(look.radius),
            border: Border.all(
              color: look.border ?? Colors.transparent,
              width: 1,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(6, 6, 8, 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Builder(
                  builder: (buttonContext) => icon(
                    Icons.add,
                    context.l10n.chat_selectSendAction,
                    () => _openActionMenu(buttonContext),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(child: text),
                if (!hasText)
                  icon(
                    Icons.gif_box_outlined,
                    context.l10n.chat_sendGif,
                    () => showChatGifPicker(context, controller),
                  ),
                icon(
                  Icons.sentiment_satisfied_alt,
                  context.l10n.chat_addEmoji,
                  () => showMeshSheet<void>(
                    context,
                    builder: (_) => EmojiPicker(onEmojiSelected: _insert),
                  ),
                ),
                if (hasText)
                  discordSend()
                else if (idle != null)
                  Theme(
                    // The mic in the field's grey, at the other icons' size.
                    data: Theme.of(context).copyWith(
                      iconButtonTheme: IconButtonThemeData(
                        style: IconButton.styleFrom(
                          foregroundColor: ink,
                          iconSize: 26,
                        ),
                      ),
                    ),
                    child: idle,
                  ),
              ],
            ),
          ),
        );
        return _buildTextField(context, scheme, look: look, frame: frame);
      },
    );
    return Container(
      color: bar,
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (replyPreview != null) replyPreview!,
            ...header,
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: field,
            ),
          ],
        ),
      ),
    );
  }

  /// The composer as the chat style's app draws it (chat_chrome.dart).
  Widget _buildStyled(BuildContext context, ChatComposerLook look) {
    if (look.allInside) return _buildAllInside(context, look);
    final scheme = Theme.of(context).colorScheme;
    final dark = look.dark;
    final bar = MeshChatLook.of(context).background(dark: dark);
    Widget plus(BuildContext buttonContext) {
      final fill = look.plusFill;
      final icon = Icon(
        look.plusIcon,
        color: look.buttonsInside
            ? (dark ? Colors.white : const Color(0xFF424242))
            : (fill != null ? look.hint : null),
      );
      return IconButton(
        icon: icon,
        tooltip: context.l10n.chat_selectSendAction,
        style: fill == null
            ? null
            : IconButton.styleFrom(
                backgroundColor: fill,
                minimumSize: const Size(36, 36),
                shape: const CircleBorder(),
              ),
        onPressed: () => _openActionMenu(buttonContext),
      );
    }

    Widget send(bool hasText) {
      void go() {
        HapticFeedback.lightImpact();
        onSend();
      }

      if (look.style == ChatStyle.icq) {
        return Padding(
          padding: const EdgeInsets.only(left: 6),
          child: OutlinedButton(
            onPressed: hasText ? go : null,
            style: OutlinedButton.styleFrom(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(2),
              ),
              side: BorderSide(color: look.border ?? scheme.outline),
              foregroundColor: dark ? icqInkNight : icqInkDay,
              minimumSize: const Size(64, 40),
            ),
            child: Text(context.l10n.chat_sendButton),
          ),
        );
      }
      final fill = look.sendFill;
      if (fill == null) {
        // The MeshCore app's (and mIRC's) plain arrow.
        return IconButton(
          icon: Icon(look.sendIcon, color: look.sendInk),
          tooltip: sendTooltip,
          onPressed: hasText ? go : null,
        );
      }
      final small = look.sendInside;
      return Padding(
        padding: EdgeInsets.only(left: small ? 0 : 6, right: small ? 4 : 0),
        child: IconButton.filled(
          icon: Icon(look.sendIcon, size: small ? 18 : 20, color: look.sendInk),
          tooltip: sendTooltip,
          style: IconButton.styleFrom(
            backgroundColor: fill,
            disabledBackgroundColor: fill.withValues(alpha: 0.4),
            minimumSize: Size.square(small ? 30 : 42),
            maximumSize: Size.square(small ? 30 : 42),
            padding: EdgeInsets.zero,
            shape: const CircleBorder(),
          ),
          onPressed: hasText ? go : null,
        ),
      );
    }

    final field = ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        final gifId = GifHelper.parseGif(value.text);
        if (gifId != null) {
          // A send button inside the field goes with it: keep one beside
          // the GIF (a phone has no Enter key).
          return _buildGifPreview(
            context,
            gifId,
            scheme,
            send: look.sendInside ? send(true) : null,
          );
        }
        final hasText = value.text.trim().isNotEmpty;
        final idle = idleTrailing;
        Widget? inside;
        if (look.sendInside) {
          inside = !hasText && idle != null ? idle : send(hasText);
        }
        return _buildTextField(
          context,
          scheme,
          look: look,
          prefix: look.buttonsInside
              ? Builder(builder: (buttonContext) => plus(buttonContext))
              : null,
          suffix: inside,
        );
      },
    );

    return Container(
      color: bar,
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (replyPreview != null) replyPreview!,
            ...header,
            Padding(
              padding: EdgeInsets.fromLTRB(
                look.buttonsInside ? 8 : 4,
                6,
                8,
                look.alwaysCount ? 2 : 6,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (!look.buttonsInside)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4, right: 2),
                      child: Builder(
                        builder: (buttonContext) => plus(buttonContext),
                      ),
                    ),
                  Expanded(child: field),
                  if (!look.sendInside)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: ValueListenableBuilder<TextEditingValue>(
                        valueListenable: controller,
                        builder: (context, value, _) {
                          final hasText = value.text.trim().isNotEmpty;
                          final idle = idleTrailing;
                          if (!hasText &&
                              idle != null &&
                              look.style != ChatStyle.icq) {
                            return idle;
                          }
                          return send(hasText);
                        },
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _hintFor(BuildContext context, ChatComposerLook look) {
    final l10n = context.l10n;
    return switch (look.style) {
      ChatStyle.classic => l10n.chat_hintSendAMessage,
      ChatStyle.signal || ChatStyle.iphone => l10n.chat_hintMessage,
      ChatStyle.android => l10n.chat_hintTextMessage,
      ChatStyle.discord =>
        hintTarget == null
            ? l10n.chat_hintMessage
            : l10n.chat_hintMessageTo(hintTarget!),
      ChatStyle.mirc || ChatStyle.icq => '',
      _ => l10n.chat_typeMessage,
    };
  }

  /// A picked GIF in place of the text field, with an X to remove it, and
  /// [send] beside it when the style's send button lived in the field.
  Widget _buildGifPreview(
    BuildContext context,
    String gifId,
    ColorScheme scheme, {
    Widget? send,
  }) {
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
          if (send != null) send,
        ],
      ),
    );
  }

  Widget _buildTextField(
    BuildContext context,
    ColorScheme scheme, {
    ChatComposerLook? look,
    Widget? prefix,
    Widget? suffix,
    Widget Function(Widget field)? frame,
  }) {
    OutlineInputBorder border(Color color, [double width = 1]) =>
        OutlineInputBorder(
          borderRadius: BorderRadius.circular(MeshRadii.md),
          borderSide: BorderSide(color: color, width: width),
        );
    if (look != null && !look.isPlain) {
      final media = MediaQuery.of(context);
      final room =
          media.size.height - media.viewInsets.bottom - media.padding.top;
      final lines = (room * 0.3 / 26).floor().clamp(1, 6);
      final edge = look.border;
      InputBorder styled([double width = 1]) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(look.radius),
        borderSide: edge == null
            ? BorderSide.none
            : BorderSide(color: edge, width: width),
      );
      final hint = _hintFor(context, look);
      if (look.allInside) {
        // Discord's field: no box of its own (frame draws it round the
        // buttons too), its 16 pt text with no extra letter spacing, so a
        // line wraps where Discord's does.
        return ByteCountedTextField(
          maxBytes: maxBytes,
          maxLines: lines,
          softLimitBytes: softLimitBytes,
          softLimitNote: softLimitNote,
          controller: controller,
          focusNode: focusNode,
          hintText: hint,
          onSubmitted: (_) => onSend(),
          encoder: encoder,
          counterTextBuilder: counterTextBuilder,
          counterColorBuilder: counterColorBuilder,
          hideCounterWhenEmpty: true,
          fieldFrame: frame,
          style: TextStyle(
            fontSize: 16,
            height: 1.3,
            letterSpacing: 0,
            color: look.dark ? discordInkNight : discordInkDay,
          ),
          decoration: InputDecoration(
            hintText: hint.isEmpty ? null : hint,
            hintMaxLines: 1,
            hintStyle: TextStyle(
              color: look.hint,
              fontSize: 16,
              height: 1.3,
              letterSpacing: 0,
            ),
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            filled: false,
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(vertical: 11),
          ),
        );
      }
      return ByteCountedTextField(
        maxBytes: maxBytes,
        maxLines: lines,
        softLimitBytes: softLimitBytes,
        softLimitNote: softLimitNote,
        controller: controller,
        focusNode: focusNode,
        hintText: hint,
        onSubmitted: (_) => onSend(),
        encoder: encoder,
        counterTextBuilder:
            counterTextBuilder ??
            (look.alwaysCount ? (used, max) => '$used/$max' : null),
        counterColorBuilder: counterColorBuilder,
        hideCounterWhenEmpty: !look.alwaysCount,
        style: look.textStyle,
        decoration: InputDecoration(
          hintText: hint.isEmpty ? null : hint,
          hintMaxLines: 1,
          hintStyle: TextStyle(color: look.hint),
          border: styled(),
          enabledBorder: styled(),
          focusedBorder: styled(edge == null ? 1 : 1.5),
          filled: true,
          fillColor: look.fill,
          isDense: look.style == ChatStyle.mirc,
          prefixIcon: prefix,
          suffixIcon: suffix,
          suffixIconConstraints: const BoxConstraints(
            minWidth: 36,
            minHeight: 36,
          ),
          contentPadding: EdgeInsets.symmetric(
            horizontal: prefix == null ? 16 : 4,
            vertical: look.buttonsInside ? 16 : 11,
          ),
        ),
      );
    }
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

/// Upstream's most lines the field grows to before it scrolls.
const int kComposerMaxLines = 5;

/// A quoted message above the field ("Replying to Bob"): a coloured bar on
/// the leading edge, [title], [content], optional [trailing] controls and a
/// dismiss button. From upstream MeshCore Open.
class ChatComposerQuote extends StatelessWidget {
  final String title;
  final Widget content;
  final Widget? trailing;
  final VoidCallback onDismiss;
  final String dismissTooltip;

  const ChatComposerQuote({
    super.key,
    required this.title,
    required this.content,
    required this.onDismiss,
    required this.dismissTooltip,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final background = scheme.surfaceContainerHighest;
    final accent = readableAccent(scheme.primary, background);
    final trailing = this.trailing;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(MeshRadii.md),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: background,
            border: BorderDirectional(
              start: BorderSide(color: accent, width: 4),
            ),
          ),
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(10, 6, 0, 6),
            child: LayoutBuilder(
              builder: (context, constraints) => Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                fontWeight: FontWeight.w700,
                                color: accent,
                              ),
                        ),
                        content,
                      ],
                    ),
                  ),
                  if (trailing != null)
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: constraints.maxWidth * 0.4,
                      ),
                      child: trailing,
                    ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: dismissTooltip,
                    color: scheme.onSurfaceVariant,
                    onPressed: onDismiss,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Stands in for the composer while no radio is connected.
class OfflineComposerBar extends StatelessWidget {
  const OfflineComposerBar({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border(top: BorderSide(color: scheme.outlineVariant, width: 1)),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final message = Row(
                children: [
                  Icon(
                    Icons.cloud_off,
                    color: scheme.onSurfaceVariant,
                    size: 24,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      context.l10n.chat_composerOffline,
                      style: Theme.of(
                        context,
                      ).textTheme.bodyLarge?.copyWith(color: scheme.onSurface),
                    ),
                  ),
                ],
              );
              // Side by side when there is room; otherwise the button goes
              // under the message so large text never squeezes it.
              final roomy =
                  constraints.maxWidth /
                      MediaQuery.textScalerOf(context).scale(1) >=
                  420;
              if (roomy) {
                return Row(
                  children: [
                    Expanded(child: message),
                    const SizedBox(width: 8),
                    const ConnectButton(),
                  ],
                );
              }
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  message,
                  const SizedBox(height: 8),
                  const ConnectButton(),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
