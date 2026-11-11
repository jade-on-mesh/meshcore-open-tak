// Runs around every test file (flutter_test picks this file up by name).

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// connectivity_plus has no plugin in tests. The fork's Wi-Fi watcher
/// (WifiState, started by the connector) listens to it, and the failed listen
/// is reported by the services library a moment later, failing whichever test
/// happens to be running then: active_conversation_test failed this way on
/// 2026-11-11 (#185). Every file gets a stand-in that answers "Wi-Fi" and
/// never emits. (Stream mocks register a tear-down, so they go in setUpAll.)
///
/// path_provider likewise: an image or cache that resolves late asked for a
/// temporary folder after its test had moved on, and the MissingPluginException
/// failed the next one (message_url_image_helper_test, the same day). Every
/// path it's asked for is one temporary folder here; a test that sets its own
/// handler replaces this one.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    final tmp = Directory.systemTemp.createTempSync('meshcore_test_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      ..setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => tmp.path,
      )
      ..setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/connectivity'),
        (call) async => <String>['wifi'],
      )
      ..setMockStreamHandler(
        const EventChannel('dev.fluttercommunity.plus/connectivity_status'),
        MockStreamHandler.inline(onListen: (arguments, events) {}),
      );
  });
  await testMain();
}
