// MeshCore Open TAK - share a contact by QR code or by sound (Sound Link),
// from the contact's long-press sheet. The link is the official app's
// contact card, `meshcore://contact/add?name=..&public_key=..&type=..`, which
// this app's scanner (lib/utils/contact_qr.dart), the official app and
// Wadamesh TAK standalones (by sound) all read.

import 'package:flutter/material.dart';

import '../helpers/snack_bar_builder.dart';
import '../l10n/l10n.dart';
import '../models/contact.dart';
import '../sound/sound_link.dart';
import '../sound/sound_share_widgets.dart';
import 'qr_code_display.dart';

/// The contact card link for [contact], or null without a full 32-byte key.
String? contactShareLink(Contact contact) {
  if (contact.publicKey.length != 32) return null;
  final type = contact.type >= 1 && contact.type <= 4 ? contact.type : 1;
  return Uri(
    scheme: 'meshcore',
    host: 'contact',
    path: '/add',
    queryParameters: {
      'name': contact.name,
      'public_key': contact.publicKeyHex,
      'type': '$type',
    },
  ).toString();
}

/// Shows [contact] as a QR code, with "Play by sound" beneath it for a
/// device that has no camera.
void showContactShareQr(BuildContext context, Contact contact) {
  final link = contactShareLink(contact);
  if (link == null) return;
  final name = contact.name.trim().isEmpty ? '?' : contact.name.trim();
  showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      scrollable: true,
      contentPadding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          QrCodeDisplay(
            data: link,
            size: 240,
            padding: EdgeInsets.zero,
            title: name,
            instructions: dialogContext.l10n.contacts_shareQrInstructions,
          ),
          const SizedBox(height: 12),
          SoundShareButton(data: link),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: Text(dialogContext.l10n.common_close),
        ),
      ],
    ),
  );
}

/// Plays [contact]'s card as sound (Sound Link), for a phone or standalone
/// listening nearby.
Future<void> playContactBySound(BuildContext context, Contact contact) async {
  final link = contactShareLink(contact);
  if (link == null) return;
  final l10n = context.l10n;
  showDismissibleSnackBar(context, content: Text(l10n.sound_playing));
  try {
    await SoundLink.instance.play(link);
  } catch (e) {
    if (context.mounted) {
      showDismissibleSnackBar(
        context,
        content: Text(l10n.sound_playFailed('$e')),
      );
    }
  }
}

/// Whether this build can play Sound Link (not on the web).
bool get soundShareAvailable => SoundLink.instance.available;

