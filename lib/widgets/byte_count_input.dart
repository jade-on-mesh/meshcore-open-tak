import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../helpers/utf8_length_limiter.dart';

/// A [TextField] that displays a live UTF-8 byte counter.
///
/// The counter appears below the field once the user starts typing and changes
/// colour as the limit is approached (orange at 70 %, error-red at 90 %).
///
/// All standard [TextField] behaviour (focus nodes, input actions, decoration
/// overrides, etc.) is forwarded so the widget can be dropped into any screen.
class ByteCountedTextField extends StatelessWidget {
  /// Maximum number of UTF-8 bytes allowed.
  final int maxBytes;

  /// Controller for the text field.
  final TextEditingController controller;

  /// Optional focus node forwarded to the inner [TextField].
  final FocusNode? focusNode;

  /// Whether the inner [TextField] requests focus when first built.
  final bool autofocus;

  /// Hint text shown when the field is empty.
  final String? hintText;

  /// Keyboard action button (defaults to [TextInputAction.send]).
  final TextInputAction textInputAction;

  /// Called when the user submits via the keyboard action button.
  final ValueChanged<String>? onSubmitted;

  /// Additional [TextInputFormatter]s applied *before* the byte limiter.
  final List<TextInputFormatter> extraFormatters;

  /// Text capitalisation forwarded to the inner [TextField].
  final TextCapitalization textCapitalization;

  /// Optional full [InputDecoration] override.  When provided, [hintText] is
  /// ignored – set it inside the decoration instead.
  final InputDecoration? decoration;

  /// Ratio (0–1) at which the counter turns the warning colour (default 0.7).
  final double warningThreshold;

  /// Ratio (0–1) at which the counter turns the error colour (default 0.9).
  final double errorThreshold;

  /// Whether to hide the counter when the field is empty (default `true`).
  final bool hideCounterWhenEmpty;

  /// Wraps the text field alone (not the counter under it): a composer that
  /// draws its own box round the field and its buttons (the Discord style).
  final Widget Function(Widget field)? fieldFrame;

  /// The text's style, forwarded to the inner [TextField].
  final TextStyle? style;

  /// Optional encoder function to transform text before byte counting/limiting.
  /// If provided, byte limits and counters will use the encoded text length.
  final String Function(String)? encoder;

  /// Optional byte count above which [softLimitNote] is shown next to the
  /// counter (the text is still allowed up to [maxBytes]).
  final int? softLimitBytes;
  final String? softLimitNote;

  /// Optional override for the counter text, given the used byte count and
  /// [maxBytes] (OTP chats show "remaining | typed/avail (N chunks)").
  final String Function(int usedBytes, int maxBytes)? counterTextBuilder;

  /// Optional override for the counter color.
  final Color Function(int usedBytes, int maxBytes, Color defaultColor)?
  counterColorBuilder;

  /// Lines the field grows to before it scrolls internally. Null (the
  /// default) grows without limit.
  final int? maxLines;

  /// Show the counter row only once usage passes [warningThreshold], and give
  /// it no space until then. By default the row keeps its height while hidden.
  final bool counterOnlyNearLimit;
  const ByteCountedTextField({
    super.key,
    required this.maxBytes,
    required this.controller,
    this.focusNode,
    this.autofocus = false,
    this.hintText,
    this.textInputAction = TextInputAction.send,
    this.onSubmitted,
    this.extraFormatters = const [],
    this.textCapitalization = TextCapitalization.sentences,
    this.decoration,
    this.warningThreshold = 0.7,
    this.errorThreshold = 0.9,
    this.hideCounterWhenEmpty = true,
    this.style,
    this.encoder,
    this.softLimitBytes,
    this.softLimitNote,
    this.counterTextBuilder,
    this.fieldFrame,
    this.counterColorBuilder,
    this.maxLines,
    this.counterOnlyNearLimit = false,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        final effectiveText = encoder != null
            ? encoder!(value.text)
            : value.text;
        final usedBytes = utf8.encode(effectiveText).length;
        final ratio = maxBytes > 0 ? usedBytes / maxBytes : 0.0;
        final showCounter = counterOnlyNearLimit
            ? ratio > warningThreshold
            : !(hideCounterWhenEmpty && value.text.isEmpty);
        final showSoftLimitNote =
            softLimitNote != null &&
            softLimitBytes != null &&
            usedBytes > softLimitBytes!;

        final defaultCounterColor = ratio > errorThreshold
            ? Theme.of(context).colorScheme.error
            : ratio > warningThreshold
            ? Theme.of(context).colorScheme.tertiary
            : Theme.of(context).colorScheme.onSurfaceVariant;
        final counterColor =
            counterColorBuilder?.call(
              usedBytes,
              maxBytes,
              defaultCounterColor,
            ) ??
            defaultCounterColor;
        final counterText =
            counterTextBuilder?.call(usedBytes, maxBytes) ??
            '$usedBytes / $maxBytes';

        final textField = TextField(
          minLines: 1,
          maxLines: maxLines,
          controller: controller,
          focusNode: focusNode,
          autofocus: autofocus,
          style: style,
          inputFormatters: [
            ...extraFormatters,
            Utf8LengthLimitingTextInputFormatter(maxBytes, encoder: encoder),
          ],
          textCapitalization: textCapitalization,
          decoration:
              decoration ??
              InputDecoration(
                hintText: hintText,
                border: const OutlineInputBorder(),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
              ),
          textInputAction: textInputAction,
          onSubmitted: onSubmitted,
        );

        final softNote = showSoftLimitNote
            ? Text(
                softLimitNote!,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.tertiary,
                ),
              )
            : null;
        final counter = Text(
          counterText,
          style: TextStyle(fontSize: 11, color: counterColor),
        );

        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            fieldFrame?.call(textField) ?? textField,
            if (counterOnlyNearLimit && showCounter)
              // Right-aligned, and wraps rather than overflowing at large
              // text sizes in a narrow field.
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 12, 8),
                child: Wrap(
                  alignment: WrapAlignment.end,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  children: [?softNote, counter],
                ),
              )
            else if (!counterOnlyNearLimit)
              Opacity(
                opacity: showCounter ? 1 : 0,
                child: Padding(
                  padding: const EdgeInsets.only(top: 4, right: 4),
                  child: Row(
                    children: [
                      Expanded(child: softNote ?? const SizedBox.shrink()),
                      const SizedBox(width: 8),
                      counter,
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
