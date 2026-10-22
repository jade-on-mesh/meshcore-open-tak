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
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../connector/meshcore_connector.dart';
import '../connector/meshcore_protocol.dart';

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
  const CoverageRepeater({
    required this.key,
    required this.name,
    required this.snr,
    required this.remoteSnr,
    required this.margin,
  });

  Map<String, Object> toJson() => {
    'k': key,
    'n': name,
    's': snr,
    'r': remoteSnr,
    'm': double.parse(margin.toStringAsFixed(1)),
  };
  static CoverageRepeater? fromJson(Object? j) {
    if (j is! Map) return null;
    final k = j['k'], n = j['n'], s = j['s'], r = j['r'], m = j['m'];
    if (k is! String || s is! num || r is! num || m is! num) return null;
    return CoverageRepeater(
      key: k,
      name: n is String ? n : k,
      snr: s.toDouble(),
      remoteSnr: r.toDouble(),
      margin: m.toDouble(),
    );
  }
}

class CoverageSample {
  final double lat, lon;
  final DateTime time;
  final List<CoverageRepeater> repeaters;
  const CoverageSample({
    required this.lat,
    required this.lon,
    required this.time,
    required this.repeaters,
  });

  /// The best repeater's margin; null when none answered.
  double? get best => repeaters.isEmpty
      ? null
      : repeaters.map((r) => r.margin).reduce(max);

  MediaMeshReach get reach => mediaMeshReachFor(best);

  Map<String, Object> toJson() => {
    'a': double.parse(lat.toStringAsFixed(6)),
    'o': double.parse(lon.toStringAsFixed(6)),
    't': time.millisecondsSinceEpoch ~/ 1000,
    'p': [for (final r in repeaters) r.toJson()],
  };
  static CoverageSample? fromJson(Object? j) {
    if (j is! Map) return null;
    final a = j['a'], o = j['o'], t = j['t'], p = j['p'];
    if (a is! num || o is! num || t is! int) return null;
    return CoverageSample(
      lat: a.toDouble(),
      lon: o.toDouble(),
      time: DateTime.fromMillisecondsSinceEpoch(t * 1000),
      repeaters: [
        for (final r in (p is List ? p : const []))
          if (CoverageRepeater.fromJson(r) case final x?) x,
      ],
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
      ),
    );
    if (_samples.length > maxSamples) _samples.removeAt(0);
    _lastAt = (f.latitude, f.longitude);
    _asking = false;
    notifyListeners();
    await _save();
  }

  @override
  void dispose() {
    _tick?.cancel();
    unawaited(_gps?.cancel());
    super.dispose();
  }
}
