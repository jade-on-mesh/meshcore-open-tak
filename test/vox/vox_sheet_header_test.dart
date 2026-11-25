import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/l10n/app_localizations.dart';
import 'package:meshcore_open/vox/voice_wire.dart';
import 'package:meshcore_open/vox/vox_sheet_header.dart';

Future<void> _pump(WidgetTester tester, String text, {String? sender}) =>
    tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) =>
                messageSheetHeader(context, text: text, sender: sender),
          ),
        ),
      ),
    );

void main() {
  const photo = VoxVoiceEnvelope(
    sessionId: 'deadbeef',
    mode: VoxVoiceMode.av1Image,
    totalPackets: 18,
    durationSeconds: 3,
  );

  testWidgets('a photo shows its kind and caption, not the envelope', (
    tester,
  ) async {
    await _pump(
      tester,
      photo.withCaption("Here's a photo").encode(),
      sender: '07B6CB48',
    );
    expect(find.text('Photo'), findsOneWidget);
    expect(find.text("Here's a photo"), findsOneWidget);
    expect(find.textContaining('VI1:'), findsNothing);
    expect(find.textContaining('IMAGE'), findsNothing);
    expect(find.byIcon(Icons.photo_camera_outlined), findsOneWidget);
  });

  testWidgets('media without a caption keeps the sender', (tester) async {
    await _pump(tester, photo.encode(), sender: '07B6CB48');
    expect(find.text('Photo'), findsOneWidget);
    expect(find.text('07B6CB48'), findsOneWidget);
  });

  testWidgets('plain text is unchanged', (tester) async {
    await _pump(tester, 'x' * 50, sender: 'Jade');
    expect(find.text('${'x' * 40}…'), findsOneWidget);
    expect(find.text('Jade'), findsOneWidget);
  });
}
