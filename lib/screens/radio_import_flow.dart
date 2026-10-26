// MeshCore Open TAK - Settings > Import: identity, channels and contacts from
// another MeshCore app or firmware onto the connected radio
// (services/radio_import.dart reads the files).

import 'dart:async';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../connector/meshcore_connector.dart';
import '../l10n/l10n.dart';
import '../services/radio_import.dart';

/// Larger than any of the files it reads (a 2,000-contact backup is ~600 KB).
const int _maxImportBytes = 8 * 1024 * 1024;

String radioImportSourceLabel(BuildContext context, RadioImportSource s) {
  final l10n = context.l10n;
  return switch (s) {
    RadioImportSource.meshcoreBackup => l10n.radioImport_sourceBackup,
    RadioImportSource.meshcoreOpenContacts =>
      l10n.radioImport_sourceOpenContacts,
    RadioImportSource.squatchMesh => l10n.radioImport_sourceSquatch,
    RadioImportSource.meshPunk => l10n.radioImport_sourceMeshPunk,
  };
}

/// Picks the file(s), shows what's in them, and imports what the user keeps.
Future<void> runRadioImport(
  BuildContext context,
  MeshCoreConnector connector,
) async {
  final l10n = context.l10n;
  final messenger = ScaffoldMessenger.of(context);
  void show(String text) =>
      messenger.showSnackBar(SnackBar(content: Text(text)));

  // Any file: a firmware's files have no extension (contacts3, identity).
  final files = await openFiles();
  if (files.isEmpty) return;
  final read = <String, Uint8List>{};
  for (final f in files) {
    if (await f.length() > _maxImportBytes) {
      show(l10n.radioImport_tooLarge(f.name));
      return;
    }
    read[f.name] = await f.readAsBytes();
  }
  final imp = parseRadioImport(read);
  if (imp == null || imp.isEmpty) {
    show(l10n.radioImport_notKnown);
    return;
  }
  if (!context.mounted) return;

  final choice = await showDialog<_Choice>(
    context: context,
    builder: (_) => _ImportDialog(imp: imp),
  );
  if (choice == null || !context.mounted) return;
  if (!connector.isConnected) {
    show(l10n.radioImport_notConnected);
    return;
  }

  final progress = ValueNotifier<double?>(null);
  unawaited(
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: Text(l10n.radioImport_importing),
          content: ValueListenableBuilder<double?>(
            valueListenable: progress,
            builder: (_, v, _) => LinearProgressIndicator(value: v),
          ),
        ),
      ),
    ),
  );
  RadioImportResult? result;
  Object? error;
  try {
    result = await connector.applyRadioImport(
      imp,
      identity: choice.identity,
      channels: choice.channels,
      contacts: choice.contacts,
      onProgress: (d, t) => progress.value = t == 0 ? null : d / t,
    );
  } catch (e) {
    error = e;
  }
  if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
  progress.dispose();
  if (error != null || result == null) {
    show(l10n.radioImport_failed('$error'));
    return;
  }
  final parts = <String>[
    if (choice.identity && imp.hasIdentity)
      result.identity
          ? l10n.radioImport_doneIdentity
          : l10n.radioImport_identityRefused,
    l10n.radioImport_doneCounts(result.channels, result.contacts),
    if (result.contactErrors > 0)
      l10n.radioImport_contactsRefused(result.contactErrors),
  ];
  show(parts.join(' '));
}

class _Choice {
  _Choice(this.identity, this.channels, this.contacts);
  final bool identity, channels, contacts;
}

class _ImportDialog extends StatefulWidget {
  const _ImportDialog({required this.imp});
  final RadioImport imp;

  @override
  State<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<_ImportDialog> {
  late bool _identity = widget.imp.hasIdentity;
  late bool _channels = widget.imp.channelCount > 0;
  late bool _contacts = widget.imp.contacts.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final imp = widget.imp;
    return AlertDialog(
      title: Text(
        l10n.radioImport_found(radioImportSourceLabel(context, imp.source)),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (imp.hasIdentity)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _identity,
                onChanged: (v) => setState(() => _identity = v ?? false),
                title: Text(
                  imp.name == null
                      ? l10n.radioImport_identity
                      : l10n.radioImport_identityNamed(imp.name!),
                ),
                subtitle: Text(l10n.radioImport_identityHelp),
              ),
            if (imp.channelCount > 0)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _channels,
                onChanged: (v) => setState(() => _channels = v ?? false),
                title: Text(l10n.radioImport_channels(imp.channelCount)),
                subtitle: Text(l10n.radioImport_channelsHelp),
              ),
            if (imp.contacts.isNotEmpty)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _contacts,
                onChanged: (v) => setState(() => _contacts = v ?? false),
                title: Text(l10n.radioImport_contacts(imp.contacts.length)),
                subtitle: Text(l10n.radioImport_contactsHelp),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.common_cancel),
        ),
        FilledButton(
          onPressed: _identity || _channels || _contacts
              ? () => Navigator.pop(
                  context,
                  _Choice(_identity, _channels, _contacts),
                )
              : null,
          child: Text(l10n.radioImport_import),
        ),
      ],
    );
  }
}
