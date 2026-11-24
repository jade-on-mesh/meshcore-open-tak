import 'package:flutter/material.dart';

import '../helpers/snack_bar_builder.dart';
import '../l10n/l10n.dart';
import '../models/channel.dart';
import '../services/alert_words_service.dart';
import '../theme/mesh_theme.dart';
import 'mesh_ui.dart';

/// A list of alert words as removable chips, with a field to add one.
/// [words] is the current list; [onAdd] returns false when nothing was added
/// (empty, already there, or the list is full).
class AlertWordsEditor extends StatefulWidget {
  final List<String> words;
  final Future<bool> Function(String word) onAdd;
  final Future<void> Function(String word) onRemove;

  const AlertWordsEditor({
    super.key,
    required this.words,
    required this.onAdd,
    required this.onRemove,
  });

  @override
  State<AlertWordsEditor> createState() => _AlertWordsEditorState();
}

class _AlertWordsEditorState extends State<AlertWordsEditor> {
  final TextEditingController _field = TextEditingController();

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final text = _field.text;
    if (AlertWordsService.normalize(text).isEmpty) return;
    final full = widget.words.length >= AlertWordsService.maxWords;
    final added = await widget.onAdd(text);
    if (!mounted) return;
    if (added) {
      _field.clear();
    } else if (full) {
      showDismissibleSnackBar(
        context,
        content: Text(
          context.l10n.alertWords_full(AlertWordsService.maxWords),
        ),
      );
    } else {
      _field.clear(); // already in the list
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.words.isEmpty)
          Text(
            l10n.alertWords_none,
            style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
          )
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final w in widget.words)
                InputChip(
                  label: Text(w),
                  labelStyle: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: scheme.onSecondaryContainer,
                  ),
                  backgroundColor: scheme.secondaryContainer,
                  side: BorderSide(color: scheme.primary),
                  deleteIcon: const Icon(Icons.close, size: 16),
                  deleteIconColor: scheme.onSecondaryContainer,
                  deleteButtonTooltipMessage: l10n.alertWords_remove(w),
                  onDeleted: () => widget.onRemove(w),
                ),
            ],
          ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _field,
                maxLength: AlertWordsService.maxLength,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _add(),
                decoration: InputDecoration(
                  labelText: l10n.alertWords_addLabel,
                  hintText: l10n.alertWords_addHint,
                  counterText: '',
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(MeshRadii.md),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(onPressed: _add, child: Text(l10n.alertWords_add)),
          ],
        ),
      ],
    );
  }
}

/// The channel's Alert words sheet (channel menu): its own words, and
/// whether the global ones apply too.
Future<void> showChannelAlertWordsSheet(BuildContext context, Channel channel) {
  return showMeshSheet<void>(
    context,
    builder: (sheetContext) => _ChannelAlertWordsSheet(channel: channel),
  );
}

class _ChannelAlertWordsSheet extends StatelessWidget {
  final Channel channel;

  const _ChannelAlertWordsSheet({required this.channel});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final alerts = AlertWordsService.instance;
    final key = channel.muteKey;
    return ListenableBuilder(
      listenable: alerts,
      builder: (context, _) {
        final own = alerts.channelWords(key);
        final global = alerts.globalWords;
        return SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              BottomSheetHeader(
                title: l10n.alertWords_title,
                subtitle: key,
                trailing: own.isEmpty
                    ? null
                    : TextButton(
                        onPressed: () => alerts.clearChannel(key),
                        child: Text(l10n.alertWords_clearAll),
                      ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                child: Text(
                  l10n.alertWords_sheetHint,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.4,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: AlertWordsEditor(
                  words: own,
                  onAdd: (w) => alerts.addChannel(key, w),
                  onRemove: (w) => alerts.removeChannel(key, w),
                ),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                title: Text(l10n.alertWords_useGlobal),
                subtitle: Text(
                  global.isEmpty
                      ? l10n.alertWords_useGlobalNone
                      : l10n.alertWords_useGlobalSubtitle(global.join(', ')),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                value: alerts.usesGlobal(key),
                onChanged: (v) => alerts.setUsesGlobal(key, v),
              ),
              const SizedBox(height: 12),
            ],
          ),
        );
      },
    );
  }
}

/// App Settings › Messaging: the alert words for every channel and the
/// notify switch.
class GlobalAlertWordsSection extends StatelessWidget {
  const GlobalAlertWordsSection({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final alerts = AlertWordsService.instance;
    return ListenableBuilder(
      listenable: alerts,
      builder: (context, _) {
        final words = alerts.globalWords;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 4,
              ),
              leading: const Icon(Icons.notifications_active_outlined, size: 24),
              title: Text(l10n.alertWords_globalTitle),
              subtitle: Text(l10n.alertWords_globalHint),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: AlertWordsEditor(
                words: words,
                onAdd: alerts.addGlobal,
                onRemove: alerts.removeGlobal,
              ),
            ),
            SwitchListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 4,
              ),
              secondary: const Icon(Icons.notifications_outlined, size: 24),
              title: Text(l10n.alertWords_notify),
              subtitle: Text(l10n.alertWords_notifySubtitle),
              value: alerts.notify,
              onChanged: alerts.setNotify,
            ),
            if (words.isNotEmpty)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: Padding(
                  padding: const EdgeInsets.only(left: 8, bottom: 4),
                  child: TextButton(
                    style: TextButton.styleFrom(
                      foregroundColor: scheme.primary,
                    ),
                    onPressed: alerts.clearGlobal,
                    child: Text(l10n.alertWords_clearGlobal),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
