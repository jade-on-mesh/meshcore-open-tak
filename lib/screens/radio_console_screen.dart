import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../connector/meshcore_connector.dart';
import '../helpers/snack_bar_builder.dart';
import '../l10n/l10n.dart';
import '../widgets/mesh_ui.dart';

/// A terminal for the connected radio's own local CLI (`CMD_RUN_CLI_COMMAND`):
/// radio2, tempradio, schedules, tx.* routing and diagnostics. Up/down in the
/// field steps through earlier commands.
class RadioConsoleScreen extends StatefulWidget {
  final MeshCoreConnector connector;

  const RadioConsoleScreen({super.key, required this.connector});

  @override
  State<RadioConsoleScreen> createState() => _RadioConsoleScreenState();
}

class _ConsoleLine {
  final String text;
  final bool command;
  final bool error;
  const _ConsoleLine(this.text, {this.command = false, this.error = false});
}

class _RadioConsoleScreenState extends State<RadioConsoleScreen> {
  // Kept for the app session so reopening the console keeps earlier commands.
  static final List<String> _history = [];
  static const _maxHistory = 50;

  final _input = TextEditingController();
  late final _focus = FocusNode(onKeyEvent: _onKey);
  final _scroll = ScrollController();
  final List<_ConsoleLine> _lines = [];
  int _historyIndex = -1;
  bool _running = false;

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _run([String? text]) async {
    final command = (text ?? _input.text).trim();
    if (command.isEmpty || _running) return;
    _history.remove(command);
    _history.add(command);
    if (_history.length > _maxHistory) _history.removeAt(0);
    _historyIndex = -1;
    setState(() {
      _running = true;
      _lines.add(_ConsoleLine('> $command', command: true));
      _input.clear();
    });
    _scrollToEnd();
    String? reply;
    try {
      reply = await widget.connector.runLocalCliCommand(command);
    } catch (_) {
      reply = null;
    }
    if (!mounted) return;
    final l10n = context.l10n;
    final error =
        reply == null ||
        reply.startsWith('Error') ||
        reply.trim() == 'Unknown command';
    if (reply == null) {
      reply = l10n.radioConsole_failed;
    } else if (reply.trim().isEmpty) {
      reply = l10n.radioConsole_noReply;
    }
    final String shown = reply;
    setState(() {
      _running = false;
      _lines.add(_ConsoleLine(shown, error: error));
    });
    _scrollToEnd();
    _focus.requestFocus();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
      );
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || _history.isEmpty) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _historyIndex = _historyIndex < 0
          ? _history.length - 1
          : (_historyIndex - 1).clamp(0, _history.length - 1);
    } else if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      if (_historyIndex < 0) return KeyEventResult.ignored;
      _historyIndex++;
      if (_historyIndex >= _history.length) {
        _historyIndex = -1;
        _input.clear();
        return KeyEventResult.handled;
      }
    } else {
      return KeyEventResult.ignored;
    }
    final text = _history[_historyIndex];
    _input.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    return KeyEventResult.handled;
  }

  /// Long press on a sent command: Copy, or Resend it (as in the official
  /// app). [line] is shown as `> command`.
  Future<void> _commandMenu(Offset at, String line) async {
    final l10n = context.l10n;
    final command = line.startsWith('> ') ? line.substring(2) : line;
    HapticFeedback.selectionClick();
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: [
        PopupMenuItem(
          value: 'copy',
          child: MeshMenuItemRow(icon: Icons.copy, label: l10n.common_copy),
        ),
        PopupMenuItem(
          value: 'resend',
          enabled: !_running,
          child: MeshMenuItemRow(icon: Icons.replay, label: l10n.chat_resend),
        ),
      ],
    );
    if (!mounted || choice == null) return;
    if (choice == 'copy') {
      await Clipboard.setData(ClipboardData(text: command));
      if (!mounted) return;
      showDismissibleSnackBar(
        context,
        content: Text(l10n.repeater_cliCommandCopied),
      );
    } else if (choice == 'resend') {
      unawaited(_run(command));
    }
  }

  /// Long press on empty space in the output: Paste into the command line.
  Future<void> _pasteMenu(Offset at) async {
    final l10n = context.l10n;
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '';
    if (!mounted) return;
    HapticFeedback.selectionClick();
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: [
        PopupMenuItem(
          value: 'paste',
          enabled: text.isNotEmpty,
          child: MeshMenuItemRow(
            icon: Icons.content_paste,
            label: l10n.repeater_cliPaste,
          ),
        ),
      ],
    );
    if (!mounted || choice != 'paste' || text.isEmpty) return;
    final value = _input.value;
    final sel = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    _input.value = TextEditingValue(
      text: value.text.replaceRange(sel.start, sel.end, text),
      selection: TextSelection.collapsed(offset: sel.start + text.length),
    );
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final mono = theme.textTheme.bodyMedium?.copyWith(fontFamily: 'monospace');
    final recent = _history.reversed.take(8).toList();
    return Scaffold(
      appBar: AppBar(title: Text(l10n.radioConsole_title)),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              // Long press on empty space (not on a line) pastes.
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onLongPressStart: (d) => _pasteMenu(d.globalPosition),
                child: ListView(
                  controller: _scroll,
                  padding: const EdgeInsets.all(16),
                  children: [
                    Text(
                      l10n.radioConsole_intro,
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(height: 12),
                    for (final line in _lines)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        // A command: long press to copy or resend. Replies
                        // stay selectable.
                        child: line.command
                            ? GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onLongPressStart: (d) =>
                                    _commandMenu(d.globalPosition, line.text),
                                child: Text(
                                  line.text,
                                  style: mono?.copyWith(
                                    color: theme.colorScheme.primary,
                                  ),
                                ),
                              )
                            : SelectableText(
                                line.text,
                                style: mono?.copyWith(
                                  color: line.error
                                      ? theme.colorScheme.error
                                      : null,
                                ),
                              ),
                      ),
                  ],
                ),
              ),
            ),
            if (recent.isNotEmpty)
              SizedBox(
                height: 44,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  children: [
                    for (final command in recent)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: ActionChip(
                          label: Text(command),
                          onPressed: _running ? null : () => _run(command),
                        ),
                      ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      focusNode: _focus,
                      autofocus: true,
                      autocorrect: false,
                      enableSuggestions: false,
                      textCapitalization: TextCapitalization.none,
                      style: mono,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _run(),
                      decoration: InputDecoration(
                        hintText: l10n.radioConsole_hint,
                        border: const OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _running
                      ? const SizedBox(
                          width: 40,
                          height: 40,
                          child: Padding(
                            padding: EdgeInsets.all(10),
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : IconButton.filled(
                          tooltip: l10n.radioConsole_send,
                          onPressed: () => _run(),
                          icon: const Icon(Icons.send),
                        ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
