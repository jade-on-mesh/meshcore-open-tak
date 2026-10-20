import 'package:flutter/material.dart';

import '../helpers/snack_bar_builder.dart';
import '../l10n/l10n.dart';
import '../sound/sound_link.dart';
import '../sound/sound_share_widgets.dart';
import '../utils/channel_qr.dart';
import '../widgets/adaptive_app_bar_title.dart';
import '../widgets/qr_scanner_widget.dart';

/// Scans a channel share QR code (meshcore://channel/add?...) and pops with
/// the [ScannedChannel].
class ChannelQrScannerScreen extends StatelessWidget {
  const ChannelQrScannerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: AdaptiveAppBarTitle(context.l10n.channels_scanChannelQrTitle),
        centerTitle: true,
        actions: [
          // A T-Deck or another phone can play the channel as sound instead.
          if (SoundLink.instance.available)
            IconButton(
              tooltip: context.l10n.sound_listen,
              icon: const Icon(Icons.hearing),
              onPressed: () async {
                final heard = await showSoundListenSheet(
                  context,
                  accept: isChannelQr,
                );
                final channel = heard == null ? null : parseChannelQr(heard);
                if (channel != null && context.mounted) {
                  Navigator.of(context).pop(channel);
                }
              },
            ),
        ],
      ),
      body: QrScannerWidget(
        validator: isChannelQr,
        onScanned: (data) {
          final channel = parseChannelQr(data);
          if (channel != null) Navigator.of(context).pop(channel);
        },
        onValidationFailed: (_) => showDismissibleSnackBar(
          context,
          content: Text(context.l10n.channels_invalidChannelQr),
        ),
        instructions: context.l10n.channels_scanChannelQrInstructions,
      ),
    );
  }
}
