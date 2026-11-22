// MeshCore Open TAK - MediaMesh coverage mapping: where the MediaMesh
// repeaters can be reached, recorded as you walk or drive.
//
// While recording, each time the phone has moved 150 m (and at most every
// 40 s, so the repeaters' four answers per two minutes go round) it asks the
// repeaters in direct range, as Find MediaMesh does (DISCOVER_REQ with the
// radio2 flag), and keeps only the ones that answer with radio2 on: MediaMesh
// repeaters, nothing else. Each sample is a point with those repeaters and
// their signal.
//
// The ask goes out on the main mesh, and the radio doesn't say which radio a
// reply came in on, so radio2's reach is estimated from it: the weaker of the
// two directions' SNR (ours of the reply, the repeater's of the ask), less the
// extra noise of radio2's wider bandwidth, against the SNR radio2's spreading
// factor still decodes. [mediaMeshMargin] is shared with Wadamesh TAK
// (mediamesh::coverageMargin, golden values in both tests).
//
// See documentation/media-mesh.md, "Coverage map".

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../connector/meshcore_connector.dart';
import '../connector/meshcore_protocol.dart';
import 'mediamesh_coverage_share.dart';
import 'mediamesh_receipts.dart';

/// What the last send to the analyzer did: [error] (a message, or
/// 'not-connected' / 'bad-address'), or [count] points sent or removed;
/// [already]: points sent that the analyzer already had.
class CoverageShareStatus {
  final String? error;
  final int count, already;
  final bool removedPoints;
  final DateTime? at;
  const CoverageShareStatus._(
    this.error,
    this.count,
    this.removedPoints,
    this.at, [
    this.already = 0,
  ]);
  const CoverageShareStatus.error(String message)
    : this._(message, 0, false, null);
  const CoverageShareStatus.sent(int n, DateTime when, {int already = 0})
    : this._(null, n, false, when, already);
  const CoverageShareStatus.removed(int n, DateTime when)
    : this._(null, n, true, when);
}

/// The lowest SNR (dB) LoRa decodes at each spreading factor.
double loraSnrFloor(int sf) => switch (sf) {
  5 => -2.5,
  6 => -5.0,
  7 => -7.5,
  8 => -10.0,
  9 => -12.5,
  10 => -15.0,
  11 => -17.5,
  _ => -20.0,
};

/// Radio2's estimated margin (dB) over what it decodes, from an SNR measured
/// on the main mesh at [mainBwHz]: the wider radio2 bandwidth hears that much
/// more noise.
double mediaMeshMargin({
  required double snr,
  required int mainBwHz,
  required int radio2BwHz,
  required int radio2Sf,
}) {
  final widen = mainBwHz > 0 && radio2BwHz > 0
      ? 10 * log(radio2BwHz / mainBwHz) / ln10
      : 0.0;
  return snr - widen - loraSnrFloor(radio2Sf);
}

enum MediaMeshReach { good, marginal, out, none }

MediaMeshReach mediaMeshReachFor(double? margin) => margin == null
    ? MediaMeshReach.none
    : margin >= 5
    ? MediaMeshReach.good
    : margin >= 0
    ? MediaMeshReach.marginal
    : MediaMeshReach.out;

/// A MediaMesh repeater heard at a sample.
class CoverageRepeater {
  final String key; // first 8 hex of its key
  final String name;
  final double snr; // ours of its reply
  final double remoteSnr; // its of our ask
  final double margin;
  final int bwHz, sf; // its radio2 setting (0: not known)
  const CoverageRepeater({
    required this.key,
    required this.name,
    required this.snr,
    required this.remoteSnr,
    required this.margin,
    this.bwHz = 0,
    this.sf = 0,
  });

  Map<String, Object> toJson() => {
    'k': key,
    'n': name,
    's': snr,
    'r': remoteSnr,
    'm': double.parse(margin.toStringAsFixed(1)),
    if (bwHz > 0) 'b': bwHz,
    if (sf > 0) 'f': sf,
  };
  static CoverageRepeater? fromJson(Object? j) {
    if (j is! Map) return null;
    final k = j['k'], n = j['n'], s = j['s'], r = j['r'], m = j['m'];
    if (k is! String || s is! num || r is! num || m is! num) return null;
    final b = j['b'], f = j['f'];
    return CoverageRepeater(
      key: k,
      name: n is String ? n : k,
      snr: s.toDouble(),
      remoteSnr: r.toDouble(),
      margin: m.toDouble(),
      bwHz: b is int ? b : 0,
      sf: f is int ? f : 0,
    );
  }
}

class CoverageSample {
  final double lat, lon;
  final DateTime time;
  final List<CoverageRepeater> repeaters;

  /// The radio that recorded it (its public key, hex; '' if not known),
  /// how fast the phone was moving (m/s) and the fix's accuracy (m).
  final String radio;
  final double speed, accuracy;
  const CoverageSample({
    required this.lat,
    required this.lon,
    required this.time,
    required this.repeaters,
    this.radio = '',
    this.speed = 0,
    this.accuracy = 0,
  });

  /// The best repeater's margin; null when none answered.
  double? get best =>
      repeaters.isEmpty ? null : repeaters.map((r) => r.margin).reduce(max);

  MediaMeshReach get reach => mediaMeshReachFor(best);

  Map<String, Object> toJson() => {
    'a': double.parse(lat.toStringAsFixed(6)),
    'o': double.parse(lon.toStringAsFixed(6)),
    't': time.millisecondsSinceEpoch ~/ 1000,
    'p': [for (final r in repeaters) r.toJson()],
    if (radio.isNotEmpty) 'r': radio,
    if (speed > 0) 'v': double.parse(speed.toStringAsFixed(1)),
    if (accuracy > 0) 'c': double.parse(accuracy.toStringAsFixed(1)),
  };
  static CoverageSample? fromJson(Object? j) {
    if (j is! Map) return null;
    final a = j['a'], o = j['o'], t = j['t'], p = j['p'];
    if (a is! num || o is! num || t is! int) return null;
    final r = j['r'], v = j['v'], c = j['c'];
    return CoverageSample(
      lat: a.toDouble(),
      lon: o.toDouble(),
      time: DateTime.fromMillisecondsSinceEpoch(t * 1000),
      repeaters: [
        for (final r in (p is List ? p : const []))
          if (CoverageRepeater.fromJson(r) case final x?) x,
      ],
      radio: r is String ? r : '',
      speed: v is num ? v.toDouble() : 0,
      accuracy: c is num ? c.toDouble() : 0,
    );
  }
}

/// Coverage as GeoJSON: a point per sample, with its reach and repeaters.
String coverageGeoJson(List<CoverageSample> samples) => jsonEncode({
  'type': 'FeatureCollection',
  'features': [
    for (final s in samples)
      {
        'type': 'Feature',
        'geometry': {
          'type': 'Point',
          'coordinates': [s.lon, s.lat],
        },
        'properties': {
          'time': s.time.toUtc().toIso8601String(),
          'reach': s.reach.name,
          'best_margin_db': s.best == null
              ? null
              : double.parse(s.best!.toStringAsFixed(1)),
          'repeaters': [
            for (final r in s.repeaters)
              {
                'key': r.key,
                'name': r.name,
                'snr': r.snr,
                'remote_snr': r.remoteSnr,
                'margin_db': double.parse(r.margin.toStringAsFixed(1)),
              },
          ],
        },
      },
  ],
});

class MediaMeshCoverageService extends ChangeNotifier {
  MediaMeshCoverageService(this._connector) {
    unawaited(_load());
  }

  final MeshCoreConnector _connector;

  static const _kShow = 'mm_coverage_show';
  static const int maxSamples = 3000;
  static const double stepMeters = 150;
  static const Duration minGap = Duration(seconds: 40);

  final List<CoverageSample> _samples = [];
  bool _recording = false, _show = true, _asking = false;
  String? _problem;
  StreamSubscription<Position>? _gps;
  Position? _fix;
  Timer? _tick;
  DateTime? _lastAsk;
  (double, double)? _lastAt;

  List<CoverageSample> get samples => List.unmodifiable(_samples);
  bool get recording => _recording;
  bool get show => _show;
  bool get asking => _asking;
  String? get problem => _problem;

  Future<File?> _file() async {
    if (kIsWeb) return null;
    final d = await getApplicationSupportDirectory();
    return File('${d.path}/mediamesh_coverage.json');
  }

  Future<void> _load() async {
    try {
      final p = await SharedPreferences.getInstance();
      _show = p.getBool(_kShow) ?? true;
      // both on unless switched off: points and receipts help the whole mesh
      final chosen = p.getBool(_kShare);
      _share = chosen ?? true;
      if (chosen == null) {
        // Sharing used to be off until switched on: points recorded before
        // it came on by itself stay on the phone unless sent on purpose
        // (Send now, or switching sharing off and on again).
        _shareSince =
            p.getInt(_kShareSince) ??
            DateTime.now().millisecondsSinceEpoch ~/ 1000;
        await p.setInt(_kShareSince, _shareSince);
      }
      _analyzer = p.getString(_kAnalyzer) ?? defaultCoverageAnalyzer;
      _receipts = p.getBool(_kReceipts) ?? true;
      final waiting = p.getString(_kReceiptsWaiting);
      if (waiting != null) {
        final j = jsonDecode(waiting);
        if (j is List) {
          _receiptsWaiting
            ..clear()
            ..addAll(j.map(MediaReceipt.fromJson).whereType<MediaReceipt>());
        }
      }
      final f = await _file();
      if (f != null && await f.exists()) {
        final j = jsonDecode(await f.readAsString());
        if (j is List) {
          for (final s in j) {
            if (CoverageSample.fromJson(s) case final x?) _samples.add(x);
          }
        }
      }
    } catch (_) {}
    notifyListeners();
  }

  Future<void> _save() async {
    try {
      final f = await _file();
      await f?.writeAsString(
        jsonEncode([for (final s in _samples) s.toJson()]),
      );
    } catch (_) {}
  }

  Future<void> setShow(bool v) async {
    _show = v;
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_kShow, v);
    } catch (_) {}
  }

  Future<void> setRecording(bool on) async {
    if (on == _recording) return;
    _recording = on;
    _problem = null;
    if (on) {
      _lastAt = null;
      try {
        var perm = await Geolocator.checkPermission();
        if (perm == LocationPermission.denied) {
          perm = await Geolocator.requestPermission();
        }
        if (perm == LocationPermission.denied ||
            perm == LocationPermission.deniedForever) {
          _problem = 'Location permission denied';
        }
        final LocationSettings settings =
            defaultTargetPlatform == TargetPlatform.android
            ? AndroidSettings(
                accuracy: LocationAccuracy.high,
                distanceFilter: 10,
                intervalDuration: const Duration(seconds: 5),
                foregroundNotificationConfig:
                    const ForegroundNotificationConfig(
                      notificationTitle: 'Mapping MediaMesh coverage',
                      notificationText:
                          'MeshCore Open TAK asks the MediaMesh repeaters '
                          'as you move.',
                      enableWakeLock: true,
                    ),
              )
            : const LocationSettings(
                accuracy: LocationAccuracy.high,
                distanceFilter: 10,
              );
        _gps = Geolocator.getPositionStream(
          locationSettings: settings,
        ).listen((p) => _fix = p, onError: (_) {});
      } catch (e) {
        _problem = 'Location: $e';
      }
      _tick = Timer.periodic(const Duration(seconds: 5), (_) => _onTick());
    } else {
      await _gps?.cancel();
      _gps = null;
      _tick?.cancel();
      _tick = null;
    }
    notifyListeners();
  }

  Future<void> clear() async {
    _samples.clear();
    notifyListeners();
    await _save();
  }

  /// Shares the samples as a GeoJSON file.
  Future<bool> export() async {
    if (_samples.isEmpty || kIsWeb) return false;
    final dir = await getTemporaryDirectory();
    final stamp = DateTime.now()
        .toIso8601String()
        .substring(0, 16)
        .replaceAll(':', '');
    final f = File('${dir.path}/mediamesh-coverage-$stamp.geojson');
    await f.writeAsString(coverageGeoJson(_samples));
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(f.path, mimeType: 'application/geo+json')],
        subject: 'MediaMesh coverage',
      ),
    );
    return true;
  }

  Future<void> _onTick() async {
    if (!_recording || _asking) return;
    final f = _fix;
    if (f == null) {
      _setProblem('Waiting for a GPS fix');
      return;
    }
    if (!_connector.isConnected) {
      _setProblem('Not connected to a radio');
      return;
    }
    if (!_connector.supportsNodeDiscover) {
      _setProblem("This radio's firmware can't ask repeaters to answer");
      return;
    }
    final now = DateTime.now();
    if (_lastAsk != null && now.difference(_lastAsk!) < minGap) return;
    final at = _lastAt;
    if (at != null &&
        Geolocator.distanceBetween(at.$1, at.$2, f.latitude, f.longitude) <
            stepMeters) {
      return;
    }
    _setProblem(null);
    await _sample(f);
  }

  void _setProblem(String? p) {
    if (p == _problem) return;
    _problem = p;
    notifyListeners();
  }

  Future<void> _sample(Position f) async {
    _asking = true;
    _lastAsk = DateTime.now();
    notifyListeners();
    final mainBw = _connector.currentBwHz ?? 62500;
    final heard = <String, CoverageRepeater>{};
    try {
      await for (final r in _connector.discoverNearbyNodes(
        typeMask: 1 << advTypeRepeater,
        timeout: const Duration(seconds: 12),
        wantRadio2: true,
      )) {
        final p = r.radio2;
        if (p == null || !p.active) continue; // MediaMesh repeaters only
        final snr = min(r.snr, r.remoteSnr);
        final key = r.publicKeyHex.substring(0, 8).toLowerCase();
        final rep = CoverageRepeater(
          key: key,
          name: _connector.contactForDiscoverResponse(r).name,
          snr: r.snr,
          remoteSnr: r.remoteSnr,
          margin: mediaMeshMargin(
            snr: snr,
            mainBwHz: mainBw,
            radio2BwHz: p.bandwidthHz,
            radio2Sf: p.spreadingFactor,
          ),
          bwHz: p.bandwidthHz,
          sf: p.spreadingFactor,
        );
        final had = heard[key];
        if (had == null || rep.margin > had.margin) heard[key] = rep;
      }
    } catch (e) {
      _problem = '$e';
    }
    final list = heard.values.toList()
      ..sort((a, b) => b.margin.compareTo(a.margin));
    _samples.add(
      CoverageSample(
        lat: f.latitude,
        lon: f.longitude,
        time: DateTime.now(),
        repeaters: list,
        radio: _connector.selfPublicKey == null
            ? ''
            : _connector.selfPublicKeyHex.toLowerCase(),
        speed: f.speed > 0 && f.speed.isFinite ? f.speed : 0,
        accuracy: f.accuracy > 0 && f.accuracy.isFinite ? f.accuracy : 0,
      ),
    );
    if (_samples.length > maxSamples) _samples.removeAt(0);
    _lastAt = (f.latitude, f.longitude);
    _asking = false;
    notifyListeners();
    await _save();
    if (_share) _shareSoon();
  }

  // ---- Sharing with an analyzer (mediamesh_coverage_share.dart) ----

  static const _kShare = 'mm_coverage_share';
  static const _kShareSince = 'mm_coverage_share_since';

  /// Sharing came on by default at this time (unix seconds): points before
  /// it go only when sent on purpose. 0 when sharing was chosen.
  int _shareSince = 0;
  static const _kAnalyzer = 'mm_coverage_analyzer';
  static const _kSentPrefix = 'mm_coverage_sent:';

  bool _share = true, _sending = false;
  String _analyzer = defaultCoverageAnalyzer;
  CoverageShareStatus? _shareStatus;
  Timer? _shareTimer;
  DateTime? _lastSend;

  /// Factory for the HTTP client (tests swap it).
  http.Client Function() httpClient = http.Client.new;

  bool get share => _share;
  bool get sending => _sending;
  String get analyzer => _analyzer;
  CoverageShareStatus? get shareStatus => _shareStatus;

  String _sentKey(String radio) =>
      '$_kSentPrefix${coverageEndpoint(_analyzer) ?? _analyzer}|$radio';

  Future<void> setShare(bool on) async {
    if (on == _share) return;
    _share = on;
    _shareSince = 0;
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_kShare, on);
      await p.remove(_kShareSince);
    } catch (_) {}
    if (on) unawaited(sendNow());
  }

  /// Sets where points go; false when it isn't a web address.
  Future<bool> setAnalyzer(String value) async {
    final v = value.trim().isEmpty ? defaultCoverageAnalyzer : value.trim();
    if (coverageEndpoint(v) == null) return false;
    if (v == _analyzer) return true;
    _analyzer = v;
    _shareStatus = null;
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_kAnalyzer, v);
    } catch (_) {}
    if (_share) unawaited(sendNow());
    return true;
  }

  /// Up to when (unix seconds) each radio's points have gone, as far as
  /// this run of the app knows.
  final Map<String, int> _sentUntil = {};

  /// After a sample: send once ten are waiting, or five minutes after the
  /// last send, whichever comes first. (Every sample would be a send
  /// otherwise, and the analyzer takes 30 an hour from a radio.)
  void _shareSoon() {
    final radio = _connector.selfPublicKey == null
        ? ''
        : _connector.selfPublicKeyHex.toLowerCase();
    if (radio.isEmpty) return;
    final until = coverageAutoFrom(_sentUntil[radio] ?? 0, _shareSince);
    final waiting = _samples
        .where(
          (s) =>
              s.radio == radio && s.time.millisecondsSinceEpoch ~/ 1000 > until,
        )
        .length;
    final last = _lastSend;
    if (last == null ||
        waiting >= 10 ||
        DateTime.now().difference(last) > const Duration(minutes: 5)) {
      _shareTimer?.cancel();
      _shareTimer = Timer(const Duration(seconds: 2), () => sendNow());
    }
  }

  /// Sends the connected radio's points the analyzer doesn't have yet.
  /// [all] (the Send now button): every point this phone holds for it,
  /// including those that don't say which radio recorded them, whatever was
  /// sent before; the analyzer keeps one of each, so nothing doubles.
  Future<void> sendNow({bool all = false}) async {
    if (_sending) return;
    final endpoint = coverageEndpoint(_analyzer);
    if (endpoint == null) {
      _setShareStatus(CoverageShareStatus.error('bad-address'));
      return;
    }
    if (!_connector.isConnected || _connector.selfPublicKey == null) {
      _setShareStatus(CoverageShareStatus.error('not-connected'));
      return;
    }
    final radio = _connector.selfPublicKeyHex.toLowerCase();
    _sending = true;
    _lastSend = DateTime.now();
    notifyListeners();
    final client = httpClient();
    var sent = 0, already = 0;
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = _sentKey(radio);
      final had = prefs.getInt(key) ?? 0;
      var until = all ? 0 : coverageAutoFrom(had, _shareSince);
      final app = await _appName();
      for (final batch in coverageBatches(
        _samples,
        radio,
        until,
        unknownToo: all,
      )) {
        final body = coverageBatchBody(
          radioHex: radio,
          samples: batch,
          sent: DateTime.now(),
          app: app,
          mainBwHz: _connector.currentBwHz ?? 62500,
        );
        final sig = await _connector.signWithRadio(
          Uint8List.fromList(coverageSignedMessage(coverageSignPrefix, body)),
        );
        final res = await client
            .post(
              endpoint,
              headers: {
                'Content-Type': 'application/json',
                'X-MeshCore-Signature': pubKeyToHex(sig),
              },
              body: body,
            )
            .timeout(const Duration(seconds: 30));
        if (res.statusCode != 200) {
          _setShareStatus(
            CoverageShareStatus.error(
              coverageReplyError(res.body) ?? 'HTTP ${res.statusCode}',
            ),
          );
          return;
        }
        final counts = coverageReplyCounts(res.body);
        sent += counts?.$1 ?? batch.length;
        already += counts?.$2 ?? 0;
        until = batch.last.time.millisecondsSinceEpoch ~/ 1000;
        if (until > had) await prefs.setInt(key, until);
        _sentUntil[radio] = until > had ? until : had;
      }
      _setShareStatus(
        CoverageShareStatus.sent(sent, DateTime.now(), already: already),
      );
    } catch (e) {
      _setShareStatus(CoverageShareStatus.error('$e'));
    } finally {
      client.close();
      _sending = false;
      notifyListeners();
    }
  }

  /// Asks the analyzer to remove every point the connected radio sent, and
  /// switches sharing off. The number removed, or null (see [shareStatus]).
  Future<int?> removeMine() async {
    final endpoint = coverageEndpoint(_analyzer);
    if (endpoint == null ||
        !_connector.isConnected ||
        _connector.selfPublicKey == null) {
      _setShareStatus(
        CoverageShareStatus.error(
          endpoint == null ? 'bad-address' : 'not-connected',
        ),
      );
      return null;
    }
    final radio = _connector.selfPublicKeyHex.toLowerCase();
    final client = httpClient();
    try {
      final body = coverageDeleteBody(radio, DateTime.now());
      final sig = await _connector.signWithRadio(
        Uint8List.fromList(coverageSignedMessage(coverageDeletePrefix, body)),
      );
      final req = http.Request('DELETE', endpoint)
        ..headers['Content-Type'] = 'application/json'
        ..headers['X-MeshCore-Signature'] = pubKeyToHex(sig)
        ..bodyBytes = body;
      final res = await http.Response.fromStream(
        await client.send(req).timeout(const Duration(seconds: 30)),
      );
      if (res.statusCode != 200) {
        _setShareStatus(
          CoverageShareStatus.error(
            coverageReplyError(res.body) ?? 'HTTP ${res.statusCode}',
          ),
        );
        return null;
      }
      final j = jsonDecode(res.body);
      final n = j is Map && j['removed'] is int ? j['removed'] as int : 0;
      // sharing switches off; switched on again, it sends them all again
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_sentKey(radio));
      _share = false;
      _shareTimer?.cancel();
      await prefs.setBool(_kShare, false);
      _setShareStatus(CoverageShareStatus.removed(n, DateTime.now()));
      return n;
    } catch (e) {
      _setShareStatus(CoverageShareStatus.error('$e'));
      return null;
    } finally {
      client.close();
    }
  }

  void _setShareStatus(CoverageShareStatus s) {
    _shareStatus = s;
    notifyListeners();
  }

  // ---- Delivery receipts (mediamesh_receipts.dart) ----

  static const _kReceipts = 'mm_receipts_share';
  static const _kReceiptsWaiting = 'mm_receipts_waiting';

  bool _receipts = true, _sendingReceipts = false;
  final List<MediaReceipt> _receiptsWaiting = [];
  CoverageShareStatus? _receiptsStatus;
  Timer? _receiptsTimer;

  bool get shareReceipts => _receipts;
  bool get sendingReceipts => _sendingReceipts;
  int get receiptsWaiting => _receiptsWaiting.length;
  CoverageShareStatus? get receiptsStatus => _receiptsStatus;

  Future<void> setShareReceipts(bool on) async {
    if (on == _receipts) return;
    _receipts = on;
    if (!on) {
      // off: nothing more leaves the phone, and what was waiting is dropped
      _receiptsWaiting.clear();
      _receiptsTimer?.cancel();
    }
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_kReceipts, on);
      await _saveReceipts(p);
    } catch (_) {}
  }

  /// A clip this phone received, or gave up on: kept for the analyzer when
  /// receipts are shared (nothing otherwise), and sent a minute later, with
  /// any that come in the meantime.
  void addReceipt(MediaReceipt r) {
    if (!_receipts) return;
    _receiptsWaiting.add(r);
    if (_receiptsWaiting.length > receiptsKeptMax) {
      _receiptsWaiting.removeRange(
        0,
        _receiptsWaiting.length - receiptsKeptMax,
      );
    }
    notifyListeners();
    unawaited(SharedPreferences.getInstance().then(_saveReceipts));
    _receiptsTimer?.cancel();
    _receiptsTimer = Timer(const Duration(minutes: 1), () => sendReceiptsNow());
  }

  Future<void> _saveReceipts(SharedPreferences p) async {
    try {
      await p.setString(
        _kReceiptsWaiting,
        jsonEncode([for (final r in _receiptsWaiting) r.toJson()]),
      );
    } catch (_) {}
  }

  void _setReceiptsStatus(CoverageShareStatus s) {
    _receiptsStatus = s;
    notifyListeners();
  }

  /// Sends the waiting receipts, signed by the connected radio (the one that
  /// received the clips).
  Future<void> sendReceiptsNow() async {
    if (_sendingReceipts || !_receipts || _receiptsWaiting.isEmpty) return;
    final endpoint = receiptsEndpoint(_analyzer);
    if (endpoint == null) {
      _setReceiptsStatus(CoverageShareStatus.error('bad-address'));
      return;
    }
    if (!_connector.isConnected || _connector.selfPublicKey == null) {
      _setReceiptsStatus(CoverageShareStatus.error('not-connected'));
      return;
    }
    final radio = _connector.selfPublicKeyHex.toLowerCase();
    _sendingReceipts = true;
    notifyListeners();
    final client = httpClient();
    var sent = 0;
    try {
      final app = await _appName();
      while (_receiptsWaiting.isNotEmpty) {
        final batch = _receiptsWaiting.take(receiptBatchMax).toList();
        final body = receiptsBatchBody(
          radioHex: radio,
          receipts: batch,
          sent: DateTime.now(),
          app: app,
        );
        final sig = await _connector.signWithRadio(
          Uint8List.fromList(coverageSignedMessage(receiptSignPrefix, body)),
        );
        final res = await client
            .post(
              endpoint,
              headers: {
                'Content-Type': 'application/json',
                'X-MeshCore-Signature': pubKeyToHex(sig),
              },
              body: body,
            )
            .timeout(const Duration(seconds: 30));
        if (res.statusCode != 200) {
          _setReceiptsStatus(
            CoverageShareStatus.error(
              coverageReplyError(res.body) ?? 'HTTP ${res.statusCode}',
            ),
          );
          return;
        }
        _receiptsWaiting.removeRange(0, batch.length);
        sent += batch.length;
        await _saveReceipts(await SharedPreferences.getInstance());
      }
      _setReceiptsStatus(CoverageShareStatus.sent(sent, DateTime.now()));
    } catch (e) {
      _setReceiptsStatus(CoverageShareStatus.error('$e'));
    } finally {
      client.close();
      _sendingReceipts = false;
      notifyListeners();
    }
  }

  /// Asks the analyzer to remove every receipt the connected radio sent, and
  /// switches receipts off. The number removed, or null (see
  /// [receiptsStatus]).
  Future<int?> removeMyReceipts() async {
    final endpoint = receiptsEndpoint(_analyzer);
    if (endpoint == null ||
        !_connector.isConnected ||
        _connector.selfPublicKey == null) {
      _setReceiptsStatus(
        CoverageShareStatus.error(
          endpoint == null ? 'bad-address' : 'not-connected',
        ),
      );
      return null;
    }
    final radio = _connector.selfPublicKeyHex.toLowerCase();
    final client = httpClient();
    try {
      final body = coverageDeleteBody(radio, DateTime.now());
      final sig = await _connector.signWithRadio(
        Uint8List.fromList(coverageSignedMessage(receiptDeletePrefix, body)),
      );
      final req = http.Request('DELETE', endpoint)
        ..headers['Content-Type'] = 'application/json'
        ..headers['X-MeshCore-Signature'] = pubKeyToHex(sig)
        ..bodyBytes = body;
      final res = await http.Response.fromStream(
        await client.send(req).timeout(const Duration(seconds: 30)),
      );
      if (res.statusCode != 200) {
        _setReceiptsStatus(
          CoverageShareStatus.error(
            coverageReplyError(res.body) ?? 'HTTP ${res.statusCode}',
          ),
        );
        return null;
      }
      final j = jsonDecode(res.body);
      final n = j is Map && j['removed'] is int ? j['removed'] as int : 0;
      await setShareReceipts(false);
      _setReceiptsStatus(CoverageShareStatus.removed(n, DateTime.now()));
      return n;
    } catch (e) {
      _setReceiptsStatus(CoverageShareStatus.error('$e'));
      return null;
    } finally {
      client.close();
    }
  }

  static String? _appNameCache;
  Future<String> _appName() async {
    if (_appNameCache != null) return _appNameCache!;
    var v = '';
    try {
      v = (await PackageInfo.fromPlatform()).version;
    } catch (_) {}
    return _appNameCache = 'MeshCore Open TAK${v.isEmpty ? '' : ' $v'}';
  }

  @override
  void dispose() {
    _tick?.cancel();
    _shareTimer?.cancel();
    _receiptsTimer?.cancel();
    unawaited(_gps?.cancel());
    super.dispose();
  }
}
