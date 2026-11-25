import 'package:flutter/material.dart';

import '../helpers/edit_helper.dart';
import '../l10n/l10n.dart';

/// Asks for a sent message's corrected text. [check] says why a draft can't
/// be sent (null when it can). Returns the new text, or null when cancelled.
Future<String?> showEditMessageDialog(
  BuildContext context, {
  required String text,
  required EditRefusal? Function(String draft) check,
}) => showDialog<String>(
  context: context,
  builder: (_) => _EditMessageDialog(text: text, check: check),
);

class _EditMessageDialog extends StatefulWidget {
  final String text;
  final EditRefusal? Function(String draft) check;

  const _EditMessageDialog({required this.text, required this.check});

  @override
  State<_EditMessageDialog> createState() => _EditMessageDialogState();
}

class _EditMessageDialogState extends State<_EditMessageDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.text,
  );
  EditRefusal? _refusal = EditRefusal.unchanged;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _changed(String draft) {
    final refusal = widget.check(draft);
    if (refusal != _refusal) setState(() => _refusal = refusal);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.chat_editTitle),
      content: TextField(
        controller: _controller,
        autofocus: true,
        minLines: 1,
        maxLines: 6,
        textCapitalization: TextCapitalization.sentences,
        onChanged: _changed,
        decoration: InputDecoration(
          helperText: l10n.chat_editHint,
          helperMaxLines: 3,
          errorText: _refusal == EditRefusal.tooLong
              ? l10n.chat_editTooLong
              : null,
          errorMaxLines: 3,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.common_cancel),
        ),
        FilledButton(
          onPressed: _refusal == null
              ? () => Navigator.pop(context, _controller.text)
              : null,
          child: Text(l10n.common_save),
        ),
      ],
    );
  }
}
