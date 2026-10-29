// MeshCore Open TAK - which repeaters run MediaMesh (radio2), as last heard.
//
// A repeater says so in two places: its DISCOVER_RESP when the request asked
// for the radio2 profile (Find MediaMesh, the coverage map, Discover nearby
// nodes and a quiet ask every half hour while connected), and `get radio2`
// over remote admin. Both are noted here by the first 8 hex of its key, with
// the profile and when it was heard, so the map can mark MediaMesh repeaters.
// An answer with radio2 off clears the mark. Kept for 30 days, globally (a
// repeater is the same repeater whichever radio heard it).

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../connector/meshcore_connector.dart';
import '../connector/meshcore_protocol.dart';

/// What a repeater last said about its radio2.
class MediaMeshRepeaterInfo {
  /// radio2 on (listening, or listening and sending).
  final bool active;

  /// 1 listen only, 2 listen and send (0 when off).
  final int mode;
  final int frequencyKHz;
  final int bandwidthHz;
  final int spreadingFactor;
  final DateTime heardAt;

  const MediaMeshRepeaterInfo({
    required this.active,
    this.mode = 0,
    this.frequencyKHz = 0,
    this.bandwidthHz = 0,
    this.spreadingFactor = 0,
    required this.heardAt,
  });

  bool get sends => active && mode == 2;

  factory MediaMeshRepeaterInfo.fromDiscover(DiscoverRadio2 r, DateTime at) =>
      MediaMeshRepeaterInfo(
        active: r.active,
        mode: r.active ? r.mode : 0,
        frequencyKHz: r.frequencyKHz,
        bandwidthHz: r.bandwidthHz,
        spreadingFactor: r.spreadingFactor,
        heardAt: at,
      );

  /// "250 kHz SF7" (empty when unknown).
  String get profileLabel {
    if (!active || bandwidthHz <= 0) return '';
    final khz = bandwidthHz / 1000;
    final bw = khz == khz.roundToDouble()
        ? khz.toStringAsFixed(0)
        : khz.toStringAsFixed(1);
    return spreadingFactor > 0 ? '$bw kHz SF$spreadingFactor' : '$bw kHz';
  }

  Map<String, Object> toJson() => {
    'a': active,
    'm': mode,
    'f': frequencyKHz,
    'b': bandwidthHz,
    's': spreadingFactor,
    't': heardAt.millisecondsSinceEpoch,
  };

  static MediaMeshRepeaterInfo? fromJson(Object? j) {
    if (j is! Map) return null;
    final a = j['a'], t = j['t'];
    if (a is! bool || t is! int) return null;
    int n(Object? v) => v is int ? v : 0;
    return MediaMeshRepeaterInfo(
      active: a,
      mode: n(j['m']),
      frequencyKHz: n(j['f']),
      bandwidthHz: n(j['b']),
      spreadingFactor: n(j['s']),
      heardAt: DateTime.fromMillisecondsSinceEpoch(t),
    );
  }
}

class MediaMeshRepeaters extends ChangeNotifier {
  MediaMeshRepeaters._();
  static final MediaMeshRepeaters instance = MediaMeshRepeaters._();

  /// For tests: a store of its own.
  @visibleForTesting
  MediaMeshRepeaters.forTest();

  static const _key = 'mediamesh_repeaters';
  static const Duration keepFor = Duration(days: 30);

  /// The quiet ask: once a connection has settled, then every half hour.
  static const Duration askAfterConnect = Duration(seconds: 45);
  static const Duration askEvery = Duration(minutes: 30);

  final Map<String, MediaMeshRepeaterInfo> _byKey = {};
  Timer? _saveTimer;
  MeshCoreConnector? _connector;
  Timer? _askTimer;
  Timer? _firstAsk;
  bool _wasConnected = false;
  bool _asking = false;
  int _version = 0;

  /// Changes whenever a mark is added, changed or cleared.
  int get version => _version;

  static String keyOf(String publicKeyHex) {
    final k = publicKeyHex.toLowerCase();
    return k.length > 8 ? k.substring(0, 8) : k;
  }

  /// What the repeater with [publicKeyHex] last said, if it said in the last
  /// 30 days.
  MediaMeshRepeaterInfo? infoFor(String publicKeyHex, {DateTime? now}) {
    if (publicKeyHex.length < 8) return null;
    final i = _byKey[keyOf(publicKeyHex)];
    if (i == null) return null;
    if ((now ?? DateTime.now()).difference(i.heardAt) > keepFor) return null;
    return i;
  }

  /// It runs MediaMesh, as far as we last heard.
  bool isMediaMesh(String publicKeyHex) =>
      infoFor(publicKeyHex)?.active ?? false;

  /// Repeaters marked as MediaMesh now.
  int get count => _byKey.keys.where(isMediaMesh).length;

  void noteDiscover(String publicKeyHex, DiscoverRadio2 r) =>
      note(publicKeyHex, MediaMeshRepeaterInfo.fromDiscover(r, DateTime.now()));

  void note(String publicKeyHex, MediaMeshRepeaterInfo info) {
    if (publicKeyHex.length < 8) return;
    final k = keyOf(publicKeyHex);
    final had = _byKey[k];
    _byKey[k] = info;
    final changed =
        had == null ||
        had.active != info.active ||
        had.mode != info.mode ||
        had.bandwidthHz != info.bandwidthHz ||
        had.spreadingFactor != info.spreadingFactor ||
        had.frequencyKHz != info.frequencyKHz;
    if (changed) {
      _version++;
      notifyListeners();
    }
    _scheduleSave();
  }

  /// Asks the repeaters in direct reach for their radio2 profile once a
  /// connection has settled, then every [askEvery]: one zero-hop request,
  /// which stock firmware answers without the profile (and is not marked).
  void attach(MeshCoreConnector connector) {
    _connector = connector;
    connector.addListener(_onConnector);
    _askTimer ??= Timer.periodic(askEvery, (_) => unawaited(ask()));
    _onConnector();
  }

  void _onConnector() {
    final c = _connector;
    if (c == null || c.isConnected == _wasConnected) return;
    _wasConnected = c.isConnected;
    _firstAsk?.cancel();
    if (c.isConnected) {
      _firstAsk = Timer(askAfterConnect, () => unawaited(ask()));
    }
  }

  /// One asking round (the responses are noted as they come in, by the
  /// connector).
  Future<void> ask() async {
    final c = _connector;
    if (c == null || _asking || !c.isConnected || !c.supportsNodeDiscover) {
      return;
    }
    _asking = true;
    try {
      await c
          .discoverNearbyNodes(typeMask: 1 << advTypeRepeater, wantRadio2: true)
          .drain<void>();
    } catch (_) {
    } finally {
      _asking = false;
    }
  }

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null) return;
      final j = jsonDecode(raw);
      if (j is! Map) return;
      final now = DateTime.now();
      j.forEach((k, v) {
        final i = MediaMeshRepeaterInfo.fromJson(v);
        if (k is String && i != null && now.difference(i.heardAt) <= keepFor) {
          _byKey.putIfAbsent(k, () => i);
        }
      });
      _version++;
      notifyListeners();
    } catch (_) {}
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 2), () => unawaited(_save()));
  }

  Future<void> _save() async {
    try {
      final now = DateTime.now();
      _byKey.removeWhere((_, i) => now.difference(i.heardAt) > keepFor);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _key,
        jsonEncode({for (final e in _byKey.entries) e.key: e.value.toJson()}),
      );
    } catch (_) {}
  }
}
