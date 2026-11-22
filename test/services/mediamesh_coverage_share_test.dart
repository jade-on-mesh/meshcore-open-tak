import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/mediamesh_coverage.dart';
import 'package:meshcore_open/services/mediamesh_coverage_share.dart';

// What CoreScope's POST /api/mediamesh/coverage-points expects
// (cmd/server/mediamesh_coverage_points.go in the CascadiaMesh fork).
void main() {
  const radio =
      'AB01cd23ef45ab01cd23ef45ab01cd23ef45ab01cd23ef45ab01cd23ef45ab01';
  CoverageSample sample(
    int t, {
    String r =
        'ab01cd23ef45ab01cd23ef45ab01cd23ef45ab01cd23ef45ab01cd23ef45ab01',
  }) => CoverageSample(
    lat: 47.6101234567,
    lon: -122.3249,
    time: DateTime.fromMillisecondsSinceEpoch(t * 1000),
    radio: r,
    speed: 1.34,
    accuracy: 6.0,
    repeaters: const [
      CoverageRepeater(
        key: '1ea5e195',
        name: 'First Hill',
        snr: 4.25,
        remoteSnr: 2.5,
        margin: 4.02,
        bwHz: 250000,
        sf: 7,
      ),
    ],
  );

  test('the analyzer address becomes its upload address', () {
    expect(
      coverageEndpoint(defaultCoverageAnalyzer).toString(),
      'https://analyzer.cascadiamesh.org/api/mediamesh/coverage-points',
    );
    expect(
      coverageEndpoint(' mesh.example.org/ ').toString(),
      'https://mesh.example.org/api/mediamesh/coverage-points',
    );
    expect(
      coverageEndpoint('http://192.168.1.5:3000/corescope/?x=1#y').toString(),
      'http://192.168.1.5:3000/corescope/api/mediamesh/coverage-points',
    );
    // the full address, as it is (not the path twice)
    expect(
      coverageEndpoint(
        'https://analyzer.cascadiamesh.org/api/mediamesh/coverage-points/',
      ).toString(),
      'https://analyzer.cascadiamesh.org/api/mediamesh/coverage-points',
    );
    expect(
      coverageEndpoint('https://analyzer.cascadiamesh.org').toString(),
      defaultCoverageAnalyzer,
    );
    expect(coverageEndpoint(''), isNull);
    expect(coverageEndpoint('ftp://example.org'), isNull);
    expect(coverageEndpoint('not an address'), isNull);
  });

  test('the signed text: the prefix and the body\'s SHA-256', () {
    expect(
      utf8.decode(coverageSignedMessage(coverageSignPrefix, utf8.encode('{}'))),
      'corescope-coverage:44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a',
    );
    expect(
      utf8.decode(
        coverageSignedMessage(coverageDeletePrefix, utf8.encode('{}')),
      ),
      startsWith('corescope-coverage-delete:'),
    );
  });

  test('only this radio\'s points not sent yet, oldest first, in batches', () {
    final all = [
      sample(300),
      sample(100),
      sample(200, r: 'ff' * 32),
      sample(400),
      sample(50),
    ];
    final b = coverageBatches(all, radio, 99, max: 2);
    expect(b.length, 2);
    expect(b[0].map((s) => s.time.millisecondsSinceEpoch ~/ 1000), [100, 300]);
    expect(b[1].map((s) => s.time.millisecondsSinceEpoch ~/ 1000), [400]);
    expect(coverageBatches(all, radio, 400), isEmpty);
    expect(coverageBatches(all, '', 0), isEmpty);
  });

  test(
    'Send now: points that don\'t say their radio go too, from the start',
    () {
      final all = [sample(300), sample(100, r: ''), sample(200, r: 'ff' * 32)];
      expect(coverageBatches(all, radio, 0).single.length, 1);
      final b = coverageBatches(all, radio, 0, unknownToo: true).single;
      expect(b.map((s) => s.time.millisecondsSinceEpoch ~/ 1000), [100, 300]);
      expect(coverageBatches(all, '', 0, unknownToo: true), isEmpty);
    },
  );

  test('sharing on by default: points from before it came on stay', () {
    // chosen (shareSince 0): from what has gone
    expect(coverageAutoFrom(500, 0), 500);
    // on by itself at 1000: nothing from before, then from what has gone
    expect(coverageAutoFrom(0, 1000), 1000);
    expect(coverageAutoFrom(1200, 1000), 1200);
  });

  test('the analyzer\'s reply: new and already had', () {
    expect(coverageReplyCounts('{"accepted":3,"duplicates":137}'), (3, 137));
    expect(coverageReplyCounts('{"accepted":5}'), (5, 0));
    expect(coverageReplyCounts('{"error":"nope"}'), isNull);
    expect(coverageReplyCounts('not json'), isNull);
  });

  test('a batch body in the analyzer\'s format', () {
    final j =
        jsonDecode(
              utf8.decode(
                coverageBatchBody(
                  radioHex: radio,
                  samples: [sample(1795000000)],
                  sent: DateTime.fromMillisecondsSinceEpoch(1795000100000),
                  app: 'MeshCore Open TAK 1.0',
                  mainBwHz: 62500,
                ),
              ),
            )
            as Map;
    expect(j['v'], 1);
    expect(j['radio'], radio.toLowerCase());
    expect(j['sent'], 1795000100);
    expect(j['radio2'], {'bw_hz': 250000, 'sf': 7});
    expect(j['main_bw_hz'], 62500);
    final p = (j['points'] as List).single as Map;
    expect(p['t'], 1795000000);
    expect(p['lat'], 47.610123);
    expect(p['speed'], 1.3);
    expect(p['acc'], 6.0);
    expect(p['reps'], [
      {'key': '1ea5e195', 'snr': 4.25, 'remote_snr': 2.5, 'margin': 4.0},
    ]);
    expect(
      jsonDecode(
        utf8.decode(
          coverageDeleteBody(radio, DateTime.fromMillisecondsSinceEpoch(5000)),
        ),
      ),
      {'radio': radio.toLowerCase(), 'sent': 5},
    );
    expect(
      coverageReplyError(
        '{"error":"this analyzer hasn\'t heard this radio yet"}',
      ),
      contains('heard'),
    );
    expect(coverageReplyError('<html>'), isNull);
  });

  test('samples keep their radio, speed and accuracy', () {
    final s = CoverageSample.fromJson(
      jsonDecode(jsonEncode(sample(10).toJson())),
    )!;
    expect(s.radio, startsWith('ab01'));
    expect(s.speed, 1.3);
    expect(s.accuracy, 6.0);
    expect(s.repeaters.single.bwHz, 250000);
    expect(s.repeaters.single.sf, 7);
    // a sample saved before these existed
    final old = CoverageSample.fromJson({
      'a': 47.6,
      'o': -122.3,
      't': 1,
      'p': [],
    })!;
    expect(old.radio, '');
    expect(old.speed, 0);
  });
}
