import 'package:flutter/material.dart';

import '../connector/meshcore_connector.dart';
import '../helpers/snack_bar_builder.dart';
import '../l10n/app_localizations.dart';
import '../l10n/l10n.dart';
import '../services/media_mesh.dart';

/// Which radio profile one contact's (`tx.user`) or channel's (`tx.channel`)
/// traffic is sent on: auto, main only, radio2 only, both, or not at all.
/// Give either [contactKeyHex] or [channelSlot].
Future<void> showTxRouteDialog(
  BuildContext context, {
  required MeshCoreConnector connector,
  required String name,
  String? contactKeyHex,
  int? channelSlot,
}) {
  assert((contactKeyHex == null) != (channelSlot == null));
  return showDialog<void>(
    context: context,
    builder: (_) => _TxRouteDialog(
      connector: connector,
      name: name,
      contactKeyHex: contactKeyHex,
      channelSlot: channelSlot,
    ),
  );
}

String txChoiceLabel(AppLocalizations l10n, TxChoice c) => switch (c) {
  TxChoice.auto => l10n.txRoute_auto,
  TxChoice.radio => l10n.txRoute_radio,
  TxChoice.radio2 => l10n.txRoute_radio2,
  TxChoice.both => l10n.txRoute_both,
  TxChoice.off => l10n.txRoute_off,
};

class _TxRouteDialog extends StatefulWidget {
  final MeshCoreConnector connector;
  final String name;
  final String? contactKeyHex;
  final int? channelSlot;

  const _TxRouteDialog({
    required this.connector,
    required this.name,
    this.contactKeyHex,
    this.channelSlot,
  });

  @override
  State<_TxRouteDialog> createState() => _TxRouteDialogState();
}

class _TxRouteDialogState extends State<_TxRouteDialog> {
  late final MediaMeshController _controller = MediaMeshController(
    widget.connector,
  );
  bool _loading = true;
  bool _saving = false;
  TxRouteReply? _route;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final route = widget.contactKeyHex != null
        ? await _controller.getUserRoute(widget.contactKeyHex!)
        : await _controller.getChannelRoute(widget.channelSlot!);
    if (!mounted) return;
    setState(() {
      _route = route;
      _loading = false;
    });
  }

  Future<void> _pick(TxChoice choice) async {
    if (_saving || choice == _route?.choice) return;
    setState(() => _saving = true);
    try {
      final route = widget.contactKeyHex != null
          ? await _controller.setUserRoute(widget.contactKeyHex!, choice)
          : await _controller.setChannelRoute(widget.channelSlot!, choice);
      if (!mounted) return;
      setState(() {
        _route = route;
        _saving = false;
      });
    } on MediaMeshException catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      showDismissibleSnackBar(context, content: Text(e.message));
    }
  }

  String _activeLabel(String active) {
    final l10n = context.l10n;
    return switch (active) {
      'radio' => l10n.txRoute_radio,
      'radio2' => l10n.txRoute_radio2,
      'both' => l10n.txRoute_both,
      _ => l10n.txRoute_none,
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    final route = _route;
    Widget body;
    if (_loading) {
      body = const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      );
    } else if (route == null) {
      body = Text(l10n.txRoute_unsupported);
    } else {
      final bound = route.boundByName;
      body = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (bound) ...[
            Text(l10n.txRoute_boundByName),
            const SizedBox(height: 8),
          ],
          RadioGroup<TxChoice>(
            groupValue: bound ? TxChoice.radio2 : route.choice,
            onChanged: (c) {
              if (c != null && !bound && !_saving) _pick(c);
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final c in TxChoice.values)
                  RadioListTile<TxChoice>(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    value: c,
                    enabled: !bound && !_saving,
                    title: Text(txChoiceLabel(l10n, c)),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(l10n.txRoute_active(_activeLabel(route.active)), style: small),
          if (route.radio2Unavailable) ...[
            const SizedBox(height: 4),
            Text(
              l10n.txRoute_radio2Unavailable,
              style: small?.copyWith(color: theme.colorScheme.error),
            ),
          ],
          const SizedBox(height: 8),
          Text(l10n.txRoute_help, style: small),
        ],
      );
    }
    return AlertDialog(
      title: Text(l10n.txRoute_title(widget.name)),
      content: SingleChildScrollView(child: body),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.common_close),
        ),
      ],
    );
  }
}
