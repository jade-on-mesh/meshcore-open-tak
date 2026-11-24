import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/l10n/app_localizations.dart';
import 'package:meshcore_open/models/image_codec_support.dart';
import 'package:meshcore_open/screens/app_settings_screen.dart';
import 'package:meshcore_open/services/app_settings_service.dart';
import 'package:meshcore_open/services/image_codec_service.dart';
import 'package:meshcore_open/services/image_codec_settings_store.dart';
import 'package:meshcore_open/services/network_map/network_map_upload_service.dart';
import 'package:meshcore_open/services/translation_service.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:meshcore_open/theme/mesh_theme.dart';
import 'package:meshcore_open/widgets/image_codec_models_section.dart';
import 'package:meshcore_open/widgets/settings_reveal.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
  });

  testWidgets('SettingsReveal hides children when off and reveals with tint', (
    tester,
  ) async {
    var visible = false;
    late StateSetter setHostState;

    await tester.pumpWidget(
      MaterialApp(
        theme: MeshTheme.dark(),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              setHostState = setState;
              return SettingsReveal(
                visible: visible,
                children: const [Text('Nested option')],
              );
            },
          ),
        ),
      ),
    );

    expect(find.text('Nested option'), findsNothing);

    setHostState(() => visible = true);
    await tester.pump();
    await tester.pump(RevealOnEnable.duration);
    await tester.pumpAndSettle();

    expect(find.text('Nested option'), findsOneWidget);
    final context = tester.element(find.byType(SettingsReveal));
    final material = tester.widget<Material>(
      find
          .descendant(
            of: find.byType(SettingsReveal),
            matching: find.byType(Material),
          )
          .first,
    );
    expect(
      material.color,
      Theme.of(context).colorScheme.surfaceContainerHighest,
    );

    final padding = tester.widget<Padding>(
      find
          .descendant(
            of: find.byType(SettingsReveal),
            matching: find.byType(Padding),
          )
          .first,
    );
    expect(padding.padding, const EdgeInsets.only(left: 16));

    setHostState(() => visible = false);
    await tester.pumpAndSettle();
    expect(find.text('Nested option'), findsNothing);
  });

  // Upstream's Image Messages reveal test is left out: MeshCore Open TAK has
  // no image-messages switch (AI sketch HD is the only AI sketch).

  for (final scale in [1.3, 2.0]) {
    testWidgets(
      'AppSettingsScreen with Image Messages and Translation expanded fits 320dp at ${scale}x',
      (tester) async {
        final overflows = <String>[];
        final previous = FlutterError.onError;
        FlutterError.onError = (details) {
          if (details.exceptionAsString().contains('overflowed')) {
            overflows.add(details.exceptionAsString().split('\n').first);
            return;
          }
          previous?.call(details);
        };
        addTearDown(() => FlutterError.onError = previous);

        final settings = AppSettingsService();
        await settings.loadSettings();
        await settings.setImageMessagesEnabled(true);
        await settings.setTranslationEnabled(true);
        final connector = MeshCoreConnector();
        final translation = TranslationService(settings);
        final codec = ImageCodecService(
          settings,
          settingsStore: InMemoryImageCodecSettingsStore(
            const ImageCodecPreferences(enabled: true),
          ),
        );
        final uploads = NetworkMapUploadService(
          connector: connector,
          settings: settings,
        );
        addTearDown(connector.dispose);
        addTearDown(translation.dispose);
        addTearDown(codec.dispose);
        addTearDown(uploads.dispose);

        tester.view.physicalSize = const Size(320, 568);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider.value(value: settings),
              ChangeNotifierProvider.value(value: connector),
              ChangeNotifierProvider.value(value: translation),
              ChangeNotifierProvider.value(value: codec),
              ChangeNotifierProvider.value(value: uploads),
            ],
            child: MaterialApp(
              theme: MeshTheme.light(),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: const AppSettingsScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(overflows, isEmpty);
      },
    );
  }
}
