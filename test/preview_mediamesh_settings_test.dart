// Temporary (preview branch only): renders MediaMesh Settings to PNGs with
// real fonts, for a screenshot. Run with --update-goldens.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/l10n/app_localizations.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:meshcore_open/theme/mesh_theme.dart';
import 'package:meshcore_open/widgets/media_mesh_settings_dialog.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/fork_providers.dart';

Future<void> _font(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    final bytes = File(p).readAsBytesSync();
    loader.addFont(Future.value(ByteData.view(bytes.buffer)));
  }
  await loader.load();
}

void main() {
  setUpAll(() async {
    final root = Platform.environment['FLUTTER_ROOT']!;
    final mf = '$root/bin/cache/artifacts/material_fonts';
    await _font('Inter', ['assets/fonts/Inter.ttf']);
    await _font('Roboto', [
      '$mf/Roboto-Regular.ttf',
      '$mf/Roboto-Medium.ttf',
      '$mf/Roboto-Bold.ttf',
    ]);
    await _font('MaterialIcons', ['$mf/MaterialIcons-Regular.otf']);
    SharedPreferences.setMockInitialValues({'vox_autoplay': true});
    PrefsManager.reset();
    await PrefsManager.initialize();
  });

  for (final dark in [false, true]) {
    testWidgets('MediaMesh Settings ${dark ? 'dark' : 'light'}', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(412 * 2, 2600 * 2);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);
      final connector = MeshCoreConnector();
      final providers = await forkProviders(tester, connector);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<MeshCoreConnector>.value(value: connector),
            ...providers,
          ],
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: dark ? MeshTheme.dark() : MeshTheme.light(),
            locale: const Locale('en'),
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: RepaintBoundary(
                key: const ValueKey('shot'),
                child: Builder(
                  builder: (context) => Container(
                    color: Theme.of(context).colorScheme.surface,
                    alignment: Alignment.topCenter,
                    child: MediaMeshSettingsDialog(connector: connector),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await expectLater(
        find.byKey(const ValueKey('shot')),
        matchesGoldenFile('preview/mediamesh_settings_${dark ? 'dark' : 'light'}.png'),
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(minutes: 1));
    });
  }
}
