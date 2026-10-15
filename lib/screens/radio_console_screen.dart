import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../connector/meshcore_connector.dart';
import '../l10n/l10n.dart';

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
              child: ListView(
                controller: _scroll,
                padding: const EdgeInsets.all(16),
                children: [
                  Text(l10n.radioConsole_intro, style: theme.textTheme.bodySmall),
                  const SizedBox(height: 12),
                  for (final line in _lines)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: SelectableText(
                        line.text,
                        style: mono?.copyWith(
                          color: line.command
                              ? theme.colorScheme.primary
                              : line.error
                              ? theme.colorScheme.error
                              : null,
                        ),
                      ),
                    ),
                ],
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
