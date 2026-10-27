// Transfer test: a small test photo sent a few times to a contact or a
// channel. Receivers on this app download it at once (whatever their
// auto-download settings) and report back how it went in a hidden text:
//
//   VT1:<session id>:<ms>:<requests>:<got>/<total>
//
// by DM to the sender for a contact test, or on the channel for a channel
// test. Apps that don't know VT1 show it as a plain text.

import 'dart:math';
import 'dart:typed_data';

import 'av1_ffi.dart' show VoxRgbImage;

const String voxTransferReportPrefix = 'VT1:';

/// How a receiver marks the photo's caption, so it knows to fetch it now.
const String voxTransferTestMark = '⏱';

/// The caption of test photo [index] of [count] (both from 1).
String voxTransferTestCaption(int index, int count) =>
    'Transfer test $index/$count $voxTransferTestMark';

/// True for a caption [voxTransferTestCaption] made (a location tag after it
/// is allowed).
bool voxIsTransferTestCaption(String caption) => RegExp(
  r'^Transfer test \d+/\d+ '
  '$voxTransferTestMark',
).hasMatch(caption);

/// One receiver's report on one test photo.
class VoxTransferReport {
  final String sessionId;

  /// From hearing the photo's announcement to having all of it (or giving up).
  final int ms;

  /// Requests it sent.
  final int requests;
  final int got;
  final int total;

  const VoxTransferReport({
    required this.sessionId,
    required this.ms,
    required this.requests,
    required this.got,
    required this.total,
  });

  bool get complete => total > 0 && got >= total;

  String encode() =>
      '$voxTransferReportPrefix$sessionId:$ms:$requests:$got/$total';

  static bool looksLikeReport(String text) =>
      text.trimLeft().startsWith(voxTransferReportPrefix);

  static VoxTransferReport? tryParse(String text) {
    final m = RegExp(
      r'^VT1:([0-9A-Za-z]{1,16}):(\d{1,9}):(\d{1,5}):(\d{1,3})/(\d{1,3})$',
    ).firstMatch(text.trim());
    if (m == null) return null;
    final got = int.parse(m.group(4)!);
    final total = int.parse(m.group(5)!);
    if (total == 0 || got > total) return null;
    return VoxTransferReport(
      sessionId: m.group(1)!,
      ms: int.parse(m.group(2)!),
      requests: int.parse(m.group(3)!),
      got: got,
      total: total,
    );
  }
}

/// One test photo as sent, with the reports that came back, by receiver.
class VoxTransferRun {
  final int index;
  final String sessionId;
  final int totalPackets;
  final DateTime sentAt;
  final Map<String, VoxTransferReport> reports = {};
  DateTime? lastReportAt;

  /// Requests for it that reached this radio.
  int requestsServed = 0;

  VoxTransferRun({
    required this.index,
    required this.sessionId,
    required this.totalPackets,
    required this.sentAt,
  });
}

String _secs(int ms) => '${(ms / 1000).toStringAsFixed(1)} s';

int _median(List<int> v) {
  final s = [...v]..sort();
  if (s.isEmpty) return 0;
  final m = s.length ~/ 2;
  return s.length.isOdd ? s[m] : (s[m - 1] + s[m]) ~/ 2;
}

/// The results, as lines for a dialog and the log: a summary first, then
/// one line per run.
List<String> voxTransferSummary(List<VoxTransferRun> runs, {String? target}) {
  final reports = [for (final r in runs) ...r.reports.values];
  final receivers = {for (final r in runs) ...r.reports.keys};
  final ok = reports.where((r) => r.complete).toList();
  final lines = <String>[];
  if (target != null) lines.add('To $target, ${runs.length} photos');
  if (reports.isEmpty) {
    lines.add(
      'No reports came back. The receivers need this app, open, and the '
      'sender in reach for their report.',
    );
  } else {
    final pct = (100 * ok.length / reports.length).round();
    lines.add(
      'Complete: ${ok.length} of ${reports.length} downloads ($pct%)'
      '${receivers.length > 1 ? ' by ${receivers.length} receivers' : ''}',
    );
    if (ok.isNotEmpty) {
      final times = [for (final r in ok) r.ms];
      lines.add(
        'Time: median ${_secs(_median(times))}, '
        'best ${_secs(times.reduce(min))}, worst ${_secs(times.reduce(max))}',
      );
    }
    final asks = [for (final r in reports) r.requests];
    final retries = asks.fold<int>(0, (a, n) => a + max(0, n - 1));
    lines.add(
      'Requests: ${asks.fold<int>(0, (a, n) => a + n)} '
      '($retries retries, median ${_median(asks)} per download)',
    );
  }
  for (final run in runs) {
    final b = StringBuffer(
      '#${run.index} (${run.totalPackets} packets, '
      '${run.requestsServed} requests heard): ',
    );
    if (run.reports.isEmpty) {
      b.write('no report');
    } else {
      b.write(
        [
          for (final e in run.reports.entries)
            '${e.key} ${e.value.complete ? '✓' : '✗ ${e.value.got}/${e.value.total}'} '
                '${_secs(e.value.ms)}, ${e.value.requests} req',
        ].join('; '),
      );
    }
    lines.add(b.toString());
  }
  return lines;
}

/// The test photo: a colour gradient with a few shapes, so the encoder has
/// something real to code (a flat picture would be unusually small).
VoxRgbImage voxTransferTestImage({int width = 192, int height = 144}) {
  final rgb = Uint8List(width * height * 3);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final o = (y * width + x) * 3;
      final check = ((x ~/ 24) + (y ~/ 24)).isEven;
      final dx = x - width / 2, dy = y - height / 2;
      final ring = (sqrt(dx * dx + dy * dy) ~/ 12).isEven;
      rgb[o] = (255 * x / width).round();
      rgb[o + 1] = (255 * y / height).round();
      rgb[o + 2] = check ? (ring ? 220 : 60) : (ring ? 140 : 20);
    }
  }
  return VoxRgbImage(width, height, rgb);
}
