import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/helpers/gif_helper.dart';
import 'package:meshcore_open/l10n/app_localizations.dart';
import 'package:meshcore_open/theme/chat_look.dart';
import 'package:meshcore_open/theme/mesh_theme.dart';
import 'package:meshcore_open/widgets/chat_composer.dart';

class _ConnectedConnector extends MeshCoreConnector {
  @override
  bool get isConnected => true;
}

/// A picked GIF takes the text field's place. In the styles whose send
/// button lives in the field (Discord, iMessage, the MeshCore app) it went
/// with it, and a phone has no Enter key: the GIF couldn't be sent. Every
/// style must offer exactly one send button with a GIF picked.
void main() {
  for (final style in ChatStyle.values) {
    testWidgets('a picked GIF can be sent: ${style.id}', (tester) async {
      final controller = TextEditingController(
        text: GifHelper.encodeGif('abc123'),
      );
      final focus = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(focus.dispose);
      var sent = 0;
      await tester.pumpWidget(
        ChangeNotifierProvider<MeshCoreConnector>.value(
          value: _ConnectedConnector(),
          child: MaterialApp(
            theme: MeshChatLook(style: style).applyTo(MeshTheme.dark()),
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: const SizedBox.expand(),
              bottomNavigationBar: ChatComposer(
                controller: controller,
                focusNode: focus,
                maxBytes: 160,
                onSend: () => sent++,
                sendTooltip: 'Send',
                actionsBuilder: () => const [],
                onAction: (_) {},
                idleTrailing: const Icon(Icons.mic),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byTooltip('Remove GIF'), findsOneWidget);
      final byTip = find.byTooltip('Send');
      final send = byTip.evaluate().isNotEmpty
          ? byTip
          : find.widgetWithText(OutlinedButton, 'Send');
      expect(send, findsOneWidget, reason: style.id);
      await tester.tap(send);
      await tester.pump();
      expect(sent, 1, reason: style.id);
    });
  }
}
