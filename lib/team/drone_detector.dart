// MeshCore Open TAK - the drone detector: the phone listens for Remote ID over
// Bluetooth (service data 0xFFFA), keeps the drones it hears
// (remote_id.dart), puts them in the Watch feed and on the map as "This
// phone", alerts on a new one, and can post them to a channel that Watch
// (here and on Wadamesh TAK standalones) puts on the map.
//
// The scan pauses while the app searches for radios (the connector's own
// scan) and resumes after.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../connector/meshcore_connector.dart';
import '../models/channel.dart';
import 'remote_id.dart';
import 'watch_feed.dart';
import 'watch_sounds.dart';

class DroneDetectorService extends ChangeNotifier {
  DroneDetectorService(this._connector, this._watch) {
    _connector.addListener(_onConnector);
    unawaited(_load());
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  final MeshCoreConnector _connector;
  final WatchFeedService _watch;
  final RemoteIdTracker tracker = RemoteIdTracker();
  final WatchSoundPlayer _player = WatchSoundPlayer();
  late final Timer _ticker;

  static const _kListen = 'drones_listen_v1';
  static const _kShare = 'drones_share_v1';
  static const _kChannel = 'drones_channel_v1';
  static const _kSound = 'drones_sound_v1';
  static final Guid _service = Guid('fffa');

  bool _listen = false;
  bool _share = false;
  bool _sound = true;
  String? _channel;
  bool _scanning = false;
  String? _error;
  String? _shareError;
  int _heard = 0, _posted = 0;
  StreamSubscription<List<ScanResult>>? _results;
  StreamSubscription<bool>? _isScanning;
  bool _starting = false;
  final Map<String, DateTime> _mapAt = {};
  bool _posting = false;

  /// The user wants the phone to listen.
  bool get listening => _listen;

  /// The phone's scan is running now.
  bool get scanning => _scanning;

  /// Why it isn't scanning, when it should be.
  String? get error => _error;
  String? get shareError => _shareError;
  bool get share => _share;
  bool get sound => _sound;
  String? get channelName => _channel;
  int get heard => _heard;
  int get posted => _posted;

  /// Newest first.
  List<RemoteIdTrack> get tracks =>
      tracker.tracks.toList()..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));

  Channel? get channel {
    for (final c in _connector.channels) {
      if (c.name == _channel) return c;
    }
    return null;
  }

  Future<void> _load() async {
    try {
      final p = await SharedPreferences.getInstance();
      _listen = p.getBool(_kListen) ?? false;
      _share = p.getBool(_kShare) ?? false;
      _sound = p.getBool(_kSound) ?? true;
      _channel = p.getString(_kChannel);
    } catch (_) {}
    notifyListeners();
    if (_listen) unawaited(_start());
  }

  Future<void> _save() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_kListen, _listen);
      await p.setBool(_kShare, _share);
      await p.setBool(_kSound, _sound);
      if (_channel == null) {
        await p.remove(_kChannel);
      } else {
        await p.setString(_kChannel, _channel!);
      }
    } catch (_) {}
  }

  Future<void> setListening(bool on) async {
    if (on == _listen) return;
    _listen = on;
    notifyListeners();
    unawaited(_save());
    if (on) {
      await _start();
    } else {
      await _stop();
    }
  }

  void setShare(bool on) {
    _share = on && _channel != null;
    _shareError = null;
    notifyListeners();
    unawaited(_save());
  }

  void setSound(bool on) {
    _sound = on;
    notifyListeners();
    unawaited(_save());
  }

  void setChannel(String? name) {
    _channel = name;
    if (name == null) _share = false;
    _shareError = null;
    notifyListeners();
    unawaited(_save());
  }

  void clear() {
    tracker.clear();
    _mapAt.clear();
    _watch.clearLocal();
    notifyListeners();
  }

  // ---- the scan ----------------------------------------------------------------------

  bool get _connectorBusy =>
      _connector.state == MeshCoreConnectionState.scanning;

  void _onConnector() {
    if (!_listen) return;
    if (_connectorBusy) {
      // The radio search took the scanner; ours resumes when it is done.
      _scanning = false;
      return;
    }
    if (!_scanning && !_starting) unawaited(_start());
  }

  Future<void> _start() async {
    if (!_listen || _starting || _connectorBusy) return;
    _starting = true;
    try {
      if (!await FlutterBluePlus.isSupported) {
        _error = 'Bluetooth is not available here';
        return;
      }
      await _results?.cancel();
      _results = FlutterBluePlus.onScanResults.listen(_onResults);
      await _isScanning?.cancel();
      _isScanning = FlutterBluePlus.isScanning.listen((s) {
        if (!s && _scanning) {
          _scanning = false;
          notifyListeners();
          // Stopped by someone else (or Bluetooth off): try again shortly.
          Timer(const Duration(seconds: 5), () {
            if (_listen && !_scanning) unawaited(_start());
          });
        }
      });
      await FlutterBluePlus.startScan(
        withServiceData: [ServiceDataFilter(_service)],
        continuousUpdates: true,
        oneByOne: true,
        androidScanMode: AndroidScanMode.lowLatency,
      );
      _scanning = true;
      _error = null;
    } catch (e) {
      _scanning = false;
      _error = '$e';
    } finally {
      _starting = false;
      notifyListeners();
    }
  }

  Future<void> _stop() async {
    await _isScanning?.cancel();
    _isScanning = null;
    await _results?.cancel();
    _results = null;
    if (_scanning && !_connectorBusy && FlutterBluePlus.isScanningNow) {
      try {
        await FlutterBluePlus.stopScan();
      } catch (_) {}
    }
    _scanning = false;
    notifyListeners();
  }

  void _onResults(List<ScanResult> results) {
    final now = DateTime.now();
    for (final r in results) {
      final data = r.advertisementData.serviceData[_service];
      if (data == null) continue;
      final o = parseRemoteIdServiceData(data);
      if (o == null) continue;
      final t = tracker.ingest(
        o,
        r.device.remoteId.str,
        r.rssi,
        now,
        isNew: _announce,
      );
      if (t == null) continue;
      _heard++;
      _toWatch(t, now);
    }
    notifyListeners();
  }

  void _announce(RemoteIdTrack t) {
    if (_sound) unawaited(_player.play(WatchSound.chime));
  }

  // The phone's drones in the Watch feed and on the map, at most every 2 s each.
  void _toWatch(RemoteIdTrack t, DateTime now) {
    final last = _mapAt[t.uasId];
    if (last != null && now.difference(last) < const Duration(seconds: 2)) {
      return;
    }
    final text = remoteIdPost(t);
    if (text == null) return;
    _mapAt[t.uasId] = now;
    _watch.putLocal('drone:${t.uasId}', text, now);
  }

  // ---- posting -------------------------------------------------------------------------

  /// Posts [t] to the alert channel now. Returns why not, or null when sent.
  Future<String?> post(RemoteIdTrack t) async {
    final c = channel;
    if (c == null) return 'Pick the alert channel first';
    if (_isPublic(c)) return 'Not on Public';
    if (!_connector.isConnected) return 'Not connected to a radio';
    final text = remoteIdPost(t);
    if (text == null) return 'No position to post yet';
    await _connector.sendChannelMessage(c, text);
    t.markPosted(DateTime.now());
    _posted++;
    notifyListeners();
    return null;
  }

  static bool _isPublic(Channel c) =>
      c.isPublicChannel || c.name.toLowerCase() == 'public';

  void _tick() {
    final now = DateTime.now();
    if (tracker.age(now)) notifyListeners();
    if (!_share || !_listen || _posting) return;
    for (final t in tracker.tracks) {
      if (t.isStale(now) || !t.postDue(now)) continue;
      _posting = true;
      unawaited(
        post(t)
            .then((why) {
              if (why != _shareError) {
                _shareError = why;
                notifyListeners();
              }
            })
            .whenComplete(() => _posting = false),
      );
      break; // one at a time
    }
  }

  @override
  void dispose() {
    _ticker.cancel();
    _connector.removeListener(_onConnector);
    unawaited(_stop());
    super.dispose();
  }
}
