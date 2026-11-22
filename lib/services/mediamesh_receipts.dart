// MeshCore Open TAK - MediaMesh delivery receipts.
//
// Observers hear only the pieces of a clip that pass near them, so the
// analyzer can't tell from them whether a photo, video or voice clip arrived.
// This phone can. With "Share delivery receipts" on, each clip it receives
// (or gives up on after asking for it) becomes a receipt: the clip's session
// id (on the air in every piece already), its piece counts and whether it
// ended up whole. Never its content, who sent it, the channel, or where the
// phone was. Receipts go to the analyzer coverage points go to, signed by the
// connected radio over "corescope-receipt:" + the hex SHA-256 of the body
// (CoreScope's POST /api/mediamesh/receipts, docs/mediamesh-receipts.md).

import 'dart:convert';

import 'mediamesh_coverage_share.dart';

const String receiptSignPrefix = 'corescope-receipt:';
const String receiptDeletePrefix = 'corescope-receipt-delete:';
const String _coveragePath = '/api/mediamesh/coverage-points';
const String _receiptsPath = '/api/mediamesh/receipts';

/// The most receipts in one batch (the analyzer's limit), and kept waiting.
const int receiptBatchMax = 500;
const int receiptsKeptMax = 1000;

/// What this phone got of one clip.
class MediaReceipt {
  /// The clip's session id, 8 hex digits.
  final String sid;

  /// photo, video, voice (or unknown).
  final String kind;

  /// When it finished: whole, or given up on.
  final DateTime at;
  final int total;

  /// Pieces that came over the air.
  final int got;

  /// Of those, pieces that came after this phone asked again for missing ones.
  final int asked;

  /// Pieces rebuilt from parity or repair packets.
  final int rebuilt;
  final bool whole;

  const MediaReceipt({
    required this.sid,
    required this.kind,
    required this.at,
    required this.total,
    required this.got,
    required this.asked,
    required this.rebuilt,
    required this.whole,
  });

  Map<String, dynamic> toJson() => {
    'sid': sid,
    'kind': kind,
    'at': at.millisecondsSinceEpoch ~/ 1000,
    'total': total,
    'got': got,
    'asked': asked,
    'rebuilt': rebuilt,
    'whole': whole,
  };

  static MediaReceipt? fromJson(Object? j) {
    if (j is! Map) return null;
    final sid = j['sid'], at = j['at'];
    if (sid is! String || at is! int) return null;
    int n(String k) => j[k] is int ? j[k] as int : 0;
    return MediaReceipt(
      sid: sid,
      kind: j['kind'] is String ? j['kind'] as String : 'unknown',
      at: DateTime.fromMillisecondsSinceEpoch(at * 1000),
      total: n('total'),
      got: n('got'),
      asked: n('asked'),
      rebuilt: n('rebuilt'),
      whole: j['whole'] == true,
    );
  }
}

/// A clip's session id as the analyzer has it: 8 lowercase hex digits, or
/// null when it isn't one.
String? receiptSid(String sessionId) {
  final s = sessionId.trim().toLowerCase();
  final v = int.tryParse(s, radix: 16);
  if (v == null || v < 0 || v > 0xFFFFFFFF) return null;
  return v.toRadixString(16).padLeft(8, '0');
}

/// Where receipts go, from the analyzer coverage points go to.
Uri? receiptsEndpoint(String analyzer) {
  final u = coverageEndpoint(analyzer);
  if (u == null) return null;
  final path = u.path.endsWith(_coveragePath)
      ? u.path.substring(0, u.path.length - _coveragePath.length) +
            _receiptsPath
      : u.path + _receiptsPath;
  return Uri(
    scheme: u.scheme,
    host: u.host,
    port: u.hasPort ? u.port : null,
    path: path,
  );
}

/// One batch's body (JSON, UTF-8) for radio [radioHex].
List<int> receiptsBatchBody({
  required String radioHex,
  required List<MediaReceipt> receipts,
  required DateTime sent,
  required String app,
}) => utf8.encode(
  jsonEncode({
    'v': 1,
    'radio': radioHex.toLowerCase(),
    'sent': sent.millisecondsSinceEpoch ~/ 1000,
    'app': app,
    'receipts': [for (final r in receipts) r.toJson()],
  }),
);
