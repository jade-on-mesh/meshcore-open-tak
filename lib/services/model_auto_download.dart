// MeshCore Open TAK - download the on-device models on first open, on Wi-Fi.
//
// Each model used to wait for a tap on the message or screen that needed it
// (a Mimi voice message, a photo to upscale, Settings for translation and
// AEIC photos). Now the first open fetches them in the background, one at a
// time, smallest first, while the phone is on Wi-Fi (or Ethernet); on mobile
// data they wait for the next Wi-Fi connection, or the next open.
//
// Each model is fetched once: when it is on disk (downloaded here, or by hand
// before) it is recorded as done, so one the user later deletes is not fetched
// again. A failed download is retried on the next Wi-Fi connection or open.
// The models' own services do the downloading, so their progress shows where
// it always did and a tap on a model already downloading does nothing.

import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One model the app can fetch by itself.
class AutoDownloadModel {
  const AutoDownloadModel({
    required this.id,
    required this.isReady,
    required this.download,
  });

  /// Stable key in the "done" list. Never rename one: it would be fetched again.
  final String id;

  /// Whether the model is on disk now (checks the disk, may be slow).
  final Future<bool> Function() isReady;

  /// Fetches it. May throw; [isReady] is asked afterwards either way.
  final Future<void> Function() download;
}

/// True on Wi-Fi or Ethernet (a VPN over either counts too).
bool connectivityAllowsModelDownload(List<ConnectivityResult> results) =>
    results.contains(ConnectivityResult.wifi) ||
    results.contains(ConnectivityResult.ethernet);

class ModelAutoDownloader {
  ModelAutoDownloader(
    this.models, {
    Future<bool> Function()? onWifi,
    Stream<bool>? wifiChanges,
  }) : _onWifi = onWifi ?? _connectivityOnWifi,
       _wifiChanges = wifiChanges ?? _connectivityChanges();

  static const prefsKey = 'model_auto_download_done';

  final List<AutoDownloadModel> models;
  final Future<bool> Function() _onWifi;
  final Stream<bool> _wifiChanges;
  StreamSubscription<bool>? _sub;
  Future<void>? _running;

  static Future<bool> _connectivityOnWifi() async =>
      connectivityAllowsModelDownload(await Connectivity().checkConnectivity());

  static Stream<bool> _connectivityChanges() =>
      Connectivity().onConnectivityChanged.map(connectivityAllowsModelDownload);

  /// Runs now, and again each time the phone joins Wi-Fi, until every model
  /// is done.
  void start() {
    if (models.isEmpty) return;
    unawaited(runOnce());
    _sub ??= _wifiChanges.listen((wifi) {
      if (wifi) unawaited(runOnce());
    });
  }

  void dispose() {
    unawaited(_sub?.cancel());
    _sub = null;
  }

  /// One pass over the models (at most one at a time). Completes when done.
  Future<void> runOnce() => _running ??= _pass().whenComplete(() {
    _running = null;
  });

  Future<void> _pass() async {
    final prefs = await SharedPreferences.getInstance();
    final done = (prefs.getStringList(prefsKey) ?? const <String>[]).toSet();
    final pending = [
      for (final m in models)
        if (!done.contains(m.id)) m,
    ];
    if (pending.isEmpty) {
      await _sub?.cancel();
      _sub = null;
      return;
    }
    Future<void> markDone(String id) async {
      done.add(id);
      await prefs.setStringList(prefsKey, done.toList()..sort());
    }

    for (final m in pending) {
      try {
        if (await m.isReady()) {
          await markDone(m.id);
          continue;
        }
        if (!await _onWifi()) return; // the rest wait for Wi-Fi
        debugPrint('[models] downloading ${m.id}');
        try {
          await m.download();
        } catch (e) {
          debugPrint('[models] ${m.id} failed: $e');
        }
        if (await m.isReady()) {
          await markDone(m.id);
          debugPrint('[models] ${m.id} ready');
        }
      } catch (e) {
        debugPrint('[models] ${m.id}: $e');
      }
    }
  }
}
