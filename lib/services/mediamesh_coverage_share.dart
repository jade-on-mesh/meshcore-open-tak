// MeshCore Open TAK - sending MediaMesh coverage points to an analyzer.
//
// With "Share coverage points" on, what the coverage recorder found goes to a
// CoreScope analyzer (the CascadiaMesh fork: POST /api/mediamesh/coverage-
// points), where its coverage estimate is checked against it. Each batch is
// signed by the connected radio's own key (CMD_SIGN_*), over
// "corescope-coverage:" + the hex SHA-256 of the exact body, and holds only
// the points that radio recorded. The analyzer only takes radios it has
// heard, shows the points as 200 m cells without the start and end of each
// trip, and never names a radio. See documentation/media-mesh.md, "Sharing
// coverage points", and CoreScope's docs/mediamesh-coverage-points.md.

import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;

import 'mediamesh_coverage.dart';

/// Where points go unless changed: the CascadiaMesh analyzer.
const String defaultCoverageAnalyzer = 'https://analyzer.cascadiamesh.org';

/// The most points in one batch (the analyzer's limit).
const int coverageBatchMax = 500;

const String coverageSignPrefix = 'corescope-coverage:';
const String coverageDeletePrefix = 'corescope-coverage-delete:';

/// The upload address for what someone typed as the analyzer: "analyzer.
/// example.org", "https://analyzer.example.org/", or with a path (kept, so an
/// analyzer under a sub-path works). null when it isn't a web address.
Uri? coverageEndpoint(String analyzer) {
  var s = analyzer.trim();
  if (s.isEmpty) return null;
  if (!s.contains('://')) s = 'https://$s';
  final u = Uri.tryParse(s);
  if (u == null ||
      (u.scheme != 'https' && u.scheme != 'http') ||
      u.host.isEmpty ||
      u.host.contains(' ')) {
    return null;
  }
  var path = u.path;
  while (path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  return u.replace(
    path: '$path/api/mediamesh/coverage-points',
    query: null,
    fragment: null,
  );
}

/// What the radio signs for [body]: [prefix] and the hex SHA-256 of it.
List<int> coverageSignedMessage(String prefix, List<int> body) =>
    utf8.encode(prefix + crypto.sha256.convert(body).toString());

/// The samples still to send from radio [radioHex]: recorded by it, after
/// [sentUntil] (unix seconds), oldest first, in batches of at most [max].
List<List<CoverageSample>> coverageBatches(
  List<CoverageSample> samples,
  String radioHex,
  int sentUntil, {
  int max = coverageBatchMax,
}) {
  final key = radioHex.toLowerCase();
  final todo =
      samples
          .where(
            (s) =>
                s.radio == key &&
                s.time.millisecondsSinceEpoch ~/ 1000 > sentUntil,
          )
          .toList()
        ..sort((a, b) => a.time.compareTo(b.time));
  return [
    for (var i = 0; i < todo.length; i += max)
      todo.sublist(i, i + max > todo.length ? todo.length : i + max),
  ];
}

/// One batch's body (JSON, UTF-8) for radio [radioHex].
List<int> coverageBatchBody({
  required String radioHex,
  required List<CoverageSample> samples,
  required DateTime sent,
  required String app,
  required int mainBwHz,
}) {
  // radio2's setting: the one most of the repeaters heard use
  final seen = <(int, int), int>{};
  for (final s in samples) {
    for (final r in s.repeaters) {
      if (r.bwHz > 0 && r.sf > 0) {
        seen[(r.bwHz, r.sf)] = (seen[(r.bwHz, r.sf)] ?? 0) + 1;
      }
    }
  }
  var radio2 = (250000, 7);
  var most = 0;
  seen.forEach((k, n) {
    if (n > most) {
      most = n;
      radio2 = k;
    }
  });
  double r1(double v) => (v * 10).roundToDouble() / 10;
  return utf8.encode(
    jsonEncode({
      'v': 1,
      'radio': radioHex.toLowerCase(),
      'sent': sent.millisecondsSinceEpoch ~/ 1000,
      'app': app,
      'radio2': {'bw_hz': radio2.$1, 'sf': radio2.$2},
      'main_bw_hz': mainBwHz,
      'points': [
        for (final s in samples)
          {
            't': s.time.millisecondsSinceEpoch ~/ 1000,
            'lat': double.parse(s.lat.toStringAsFixed(6)),
            'lon': double.parse(s.lon.toStringAsFixed(6)),
            if (s.accuracy > 0) 'acc': r1(s.accuracy),
            if (s.speed > 0) 'speed': r1(s.speed),
            'reps': [
              for (final r in s.repeaters)
                {
                  'key': r.key,
                  'snr': r.snr,
                  'remote_snr': r.remoteSnr,
                  'margin': r1(r.margin),
                },
            ],
          },
      ],
    }),
  );
}

/// The body asking the analyzer to remove radio [radioHex]'s points.
List<int> coverageDeleteBody(String radioHex, DateTime sent) => utf8.encode(
  jsonEncode({
    'radio': radioHex.toLowerCase(),
    'sent': sent.millisecondsSinceEpoch ~/ 1000,
  }),
);

/// The analyzer's error message in a reply body, if it gave one.
String? coverageReplyError(String body) {
  try {
    final j = jsonDecode(body);
    if (j is Map && j['error'] is String) return j['error'] as String;
  } catch (_) {}
  return null;
}
