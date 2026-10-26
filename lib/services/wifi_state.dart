// MeshCore Open TAK - whether the phone is on Wi-Fi (or Ethernet), for
// downloads that wait for it: Settings > Linked images.

import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

import 'model_auto_download.dart' show connectivityAllowsModelDownload;

class WifiState {
  WifiState._();

  /// True on Wi-Fi or Ethernet; false until the first check answers.
  static final ValueNotifier<bool> onWifi = ValueNotifier<bool>(false);

  static StreamSubscription<List<ConnectivityResult>>? _sub;

  /// Starts watching (once; later calls do nothing).
  static void start() {
    if (_sub != null) return;
    final c = Connectivity();
    _sub = c.onConnectivityChanged.listen(
      (r) => onWifi.value = connectivityAllowsModelDownload(r),
      onError: (Object _) {},
    );
    unawaited(
      c
          .checkConnectivity()
          .then((r) => onWifi.value = connectivityAllowsModelDownload(r))
          .catchError((Object _) => onWifi.value),
    );
  }
}
