import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/mediamesh_receipts.dart';

// What CoreScope's POST /api/mediamesh/receipts expects
// (cmd/server/mediamesh_receipts.go in the CascadiaMesh fork).
void main() {
  const radio =
      'AB01cd23ef45ab01cd23ef45ab01cd23ef45ab01cd23ef45ab01cd23ef45ab01';
  final r = MediaReceipt(
    sid: '1a2b3c4d',
    kind: 'photo',
    at: DateTime.fromMillisecondsSinceEpoch(1795300000 * 1000),
    total: 17,
    got: 16,
    asked: 1,
    rebuilt: 0,
    whole: true,
  );

  test('receipts go next to the coverage points', () {
    expect(
      receiptsEndpoint(
        'https://analyzer.cascadiamesh.org/api/mediamesh/coverage-points',
      ).toString(),
      'https://analyzer.cascadiamesh.org/api/mediamesh/receipts',
    );
    expect(
      receiptsEndpoint('http://192.168.1.5:3000/corescope/').toString(),
      'http://192.168.1.5:3000/corescope/api/mediamesh/receipts',
    );
    expect(receiptsEndpoint('not an address'), isNull);
  });

  test('session ids as the analyzer has them', () {
    expect(receiptSid('1A2B3C4D'), '1a2b3c4d');
    expect(receiptSid('2b'), '0000002b');
    expect(receiptSid('xyz'), isNull);
    expect(receiptSid('123456789'), isNull);
  });

  test('a batch body in the analyzer\'s format, and nothing else', () {
    final j =
        jsonDecode(
              utf8.decode(
                receiptsBatchBody(
                  radioHex: radio,
                  receipts: [r],
                  sent: DateTime.fromMillisecondsSinceEpoch(1795300100000),
                  app: 'MeshCore Open TAK 1.0',
                ),
              ),
            )
            as Map;
    expect(j['v'], 1);
    expect(j['radio'], radio.toLowerCase());
    expect(j['sent'], 1795300100);
    expect(j['receipts'], [
      {
        'sid': '1a2b3c4d',
        'kind': 'photo',
        'at': 1795300000,
        'total': 17,
        'got': 16,
        'asked': 1,
        'rebuilt': 0,
        'whole': true,
      },
    ]);
    expect(j.keys.toSet(), {'v', 'radio', 'sent', 'app', 'receipts'});
  });

  test('receipts survive being kept', () {
    final back = MediaReceipt.fromJson(jsonDecode(jsonEncode(r.toJson())))!;
    expect(back.sid, r.sid);
    expect(back.at, r.at);
    expect(back.asked, 1);
    expect(back.whole, isTrue);
    expect(MediaReceipt.fromJson({'sid': 1}), isNull);
  });
}
