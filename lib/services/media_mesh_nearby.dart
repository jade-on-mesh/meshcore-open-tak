// MeshCore Open TAK - "a MediaMesh is on the air here".
//
// Lit for two hours after the connected radio heard a valid packet on radio2.
// The radio is asked (`get radio2.status`) once a minute while connected:
// Wadamesh says how long ago (`heard=Ns`); keymindCascade's radio2 receive
// count going up says "just now". A photo or voice packet the app gets via
// radio2 lights it at once. The time is saved, so it survives a restart.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../connector/meshcore_connector.dart';
import 'media_mesh.dart';

class MediaMeshNearby extends ChangeNotifier {
  MediaMeshNearby._();
  static final MediaMeshNearby instance = MediaMeshNearby._();

  static const Duration window = Duration(hours: 2);
  static const Duration _pollEvery = Duration(minutes: 1);
  static const _key = 'mediamesh_heard_at';

  DateTime? _heardAt;
  bool _listening = false;
  bool _supported = false;
  bool _lit = false;

  MeshCoreConnector? _connector;
  Timer? _timer;
  String? _radio;
  int? _lastRx;
  int _misses = 0;
  int _ticks = 0;
  bool _polling = false;
  bool _wasConnected = false;

  /// A valid radio2 packet was heard in the last two hours.
  bool get lit => _lit;

  /// The connected radio's radio2 is on (listening for a MediaMesh).
  bool get listening => _listening;

  /// The connected radio has MediaMesh (answers `get radio2.status`), on
  /// or off.
  bool get supported => _supported;

  DateTime? get heardAt => _heardAt;

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final ms = prefs.getInt(_key);
      if (ms != null) _heardAt = DateTime.fromMillisecondsSinceEpoch(ms);
    } catch (_) {}
    _update();
  }

  void attach(MeshCoreConnector connector) {
    _connector = connector;
    connector.addListener(_onConnector);
    _timer ??= Timer.periodic(_pollEvery, (_) {
      // A radio that hasn't answered lately is asked every 10 minutes.
      _ticks++;
      if (_misses >= 3 && _ticks % 10 != 0) return;
      unawaited(_poll());
    });
  }

  void _onConnector() {
    final c = _connector;
    if (c == null) return;
    if (c.isConnected != _wasConnected) {
      _wasConnected = c.isConnected;
      // A new connection: ask straight away (after it has settled).
      if (c.isConnected) {
        _misses = 0;
        _lastRx = null;
        // Once it has settled, and again in case the first ask was lost in
        // the connection's start-up traffic.
        Timer(const Duration(seconds: 5), () => unawaited(_poll()));
        Timer(const Duration(seconds: 20), () => unawaited(_poll()));
      } else {
        _supported = false;
        _update();
      }
    }
  }

  /// A packet was heard on radio2 [at] (now if null).
  void markHeard([DateTime? at]) {
    final when = at ?? DateTime.now();
    if (_heardAt != null && !when.isAfter(_heardAt!)) return;
    _heardAt = when;
    unawaited(() async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt(_key, when.millisecondsSinceEpoch);
      } catch (_) {}
    }());
    _update();
  }

  Future<void> _poll() async {
    final c = _connector;
    if (c == null || _polling) {
      _update();
      return;
    }
    if (!c.isConnected) {
      _lastRx = null;
      _update();
      return;
    }
    final radio = c.selfPublicKeyHex;
    if (radio != _radio) {
      _radio = radio;
      _lastRx = null;
      _misses = 0;
    }
    _polling = true;
    try {
      String? text;
      try {
        text = await c
            .runLocalCliCommand('get radio2.status')
            .timeout(const Duration(seconds: 4));
      } catch (_) {
        text = null;
      }
      final st = text == null ? null : Radio2Status.tryParse(text);
      if (st == null) {
        _misses++;
        if (_misses >= 3) {
          _supported = false;
          _setListening(false);
        }
        return;
      }
      _misses = 0;
      _supported = true;
      if (st.pending) return;
      _setListening(Radio2Mode.fromCli(st.mode) != Radio2Mode.off);
      final ago = st.heardSecondsAgo;
      if (ago != null) {
        markHeard(DateTime.now().subtract(Duration(seconds: ago)));
      } else if (_lastRx != null && st.rx[1] > _lastRx!) {
        markHeard();
      }
      _lastRx = st.rx[1];
    } finally {
      _polling = false;
      _update();
    }
  }

  void _setListening(bool v) {
    _listening = v && (_connector?.isConnected ?? false);
  }

  void _update() {
    if (!(_connector?.isConnected ?? false)) {
      _listening = false;
      _supported = false;
    }
    final at = _heardAt;
    final lit = at != null && DateTime.now().difference(at) < window;
    final shown = (_listening, _supported);
    if (lit != _lit || shown != _notified) {
      _lit = lit;
      _notified = shown;
      notifyListeners();
    }
  }

  (bool, bool) _notified = (false, false);
}
