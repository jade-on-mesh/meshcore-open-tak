import '../connector/meshcore_connector.dart';
import '../models/radio_settings.dart';

/// MediaMesh: photos and voice clips on a second LoRa profile (`radio2`) of the
/// connected radio, while text stays on the main mesh. The radio scans both
/// profiles; the firmware decides which packets are media. The app only reads
/// and writes the radio's settings through the local CLI, with the command
/// names shared by Wadamesh and mikecarper/MeshCore:
///
/// - `get radio2`, `set radio2 MHz,kHz,sf,cr,rxtx`, `set radio2 off`
/// - `get tx.media`, `set tx.media radio|radio2`
/// - `set radio2.cross off` (never copy ordinary traffic onto radio2)
///
/// See documentation/media-mesh.md.
class MediaMeshSettings {
  final bool enabled;
  final double frequencyMHz;
  final LoRaBandwidth bandwidth;
  final LoRaSpreadingFactor spreadingFactor;
  final LoRaCodingRate codingRate;

  const MediaMeshSettings({
    required this.enabled,
    required this.frequencyMHz,
    required this.bandwidth,
    required this.spreadingFactor,
    required this.codingRate,
  });

  /// 916 MHz, 250 kHz, SF7, CR 4/5: about four times faster than SF7/62.5.
  static const defaults = MediaMeshSettings(
    enabled: false,
    frequencyMHz: 916.0,
    bandwidth: LoRaBandwidth.bw250,
    spreadingFactor: LoRaSpreadingFactor.sf7,
    codingRate: LoRaCodingRate.cr4_5,
  );

  MediaMeshSettings copyWith({
    bool? enabled,
    double? frequencyMHz,
    LoRaBandwidth? bandwidth,
    LoRaSpreadingFactor? spreadingFactor,
    LoRaCodingRate? codingRate,
  }) => MediaMeshSettings(
    enabled: enabled ?? this.enabled,
    frequencyMHz: frequencyMHz ?? this.frequencyMHz,
    bandwidth: bandwidth ?? this.bandwidth,
    spreadingFactor: spreadingFactor ?? this.spreadingFactor,
    codingRate: codingRate ?? this.codingRate,
  );
}

/// What the connected firmware can do.
enum MediaMeshSupport {
  /// radio2 and media routing (`tx.media`).
  full,

  /// radio2 exists but media cannot be routed to it.
  noMediaRouting,

  /// No radio2 on this radio or firmware.
  none,
}

class MediaMeshState {
  final MediaMeshSupport support;
  final MediaMeshSettings settings;

  /// The radio's own reason when it cannot run radio2 (e.g. an LR1110 board).
  final String? detail;

  const MediaMeshState({
    required this.support,
    required this.settings,
    this.detail,
  });
}

/// One `get radio2` answer.
class Radio2Reply {
  final bool off;
  final double frequencyMHz;
  final LoRaBandwidth? bandwidth;
  final LoRaSpreadingFactor? spreadingFactor;
  final LoRaCodingRate? codingRate;
  final String mode;

  const Radio2Reply._({
    required this.off,
    this.frequencyMHz = 0,
    this.bandwidth,
    this.spreadingFactor,
    this.codingRate,
    this.mode = 'off',
  });

  static const Radio2Reply offReply = Radio2Reply._(off: true);

  bool get canTransmit => !off && mode == 'rxtx';

  /// Parses `> off`, `> off (manual)` or
  /// `> 916.000,250.00,7,5,rxtx[,preamble][; WARN ...]`. Returns null for
  /// anything else (errors, `Unknown command`).
  static Radio2Reply? tryParse(String reply) {
    var text = reply.trim();
    final bar = text.indexOf('|');
    if (bar == 2) text = text.substring(3); // correlation tag
    if (!text.startsWith('>')) return null;
    text = text.substring(1).trim();
    final semi = text.indexOf(';');
    if (semi >= 0) text = text.substring(0, semi).trim();
    if (text.startsWith('off')) return offReply;
    final parts = text.split(',').map((p) => p.trim()).toList();
    if (parts.length < 5) return null;
    final freq = double.tryParse(parts[0]);
    final bwKHz = double.tryParse(parts[1]);
    final sf = int.tryParse(parts[2]);
    final cr = int.tryParse(parts[3]);
    if (freq == null || bwKHz == null || sf == null || cr == null) return null;
    final mode = parts[4].split(' ').first;
    return Radio2Reply._(
      off: mode == 'off',
      frequencyMHz: freq,
      bandwidth: bandwidthFromKHz(bwKHz),
      spreadingFactor: _firstWhereOrNull(
        LoRaSpreadingFactor.values,
        (v) => v.value == sf,
      ),
      codingRate: _firstWhereOrNull(
        LoRaCodingRate.values,
        (v) => v.value == (cr <= 4 ? cr + 4 : cr),
      ),
      mode: mode,
    );
  }
}

T? _firstWhereOrNull<T>(Iterable<T> items, bool Function(T) test) {
  for (final item in items) {
    if (test(item)) return item;
  }
  return null;
}

LoRaBandwidth? bandwidthFromKHz(double khz) => _firstWhereOrNull(
  LoRaBandwidth.values,
  (bw) => (bw.hz / 1000.0 - khz).abs() < 0.06,
);

/// kHz as the CLI expects it: `250`, `62.5`, `31.25`, `7.8`.
String formatBandwidthKHz(LoRaBandwidth bw) {
  final khz = bw.hz / 1000.0;
  var text = khz.toStringAsFixed(2);
  text = text.replaceFirst(RegExp(r'0+$'), '');
  if (text.endsWith('.')) text = text.substring(0, text.length - 1);
  return text;
}

String buildSetRadio2Command(MediaMeshSettings s) =>
    'set radio2 ${s.frequencyMHz.toStringAsFixed(3)},'
    '${formatBandwidthKHz(s.bandwidth)},'
    '${s.spreadingFactor.value},${s.codingRate.value},rxtx';

/// `> radio2` / `> radio`, or null when the firmware does not know tx.media.
String? parseTxMediaReply(String reply) {
  var text = reply.trim();
  if (text.indexOf('|') == 2) text = text.substring(3);
  if (!text.startsWith('>')) return null;
  final value = text.substring(1).trim().split(RegExp(r'[\s;]')).first;
  return value == 'radio' || value == 'radio2' ? value : null;
}

bool isCliOk(String reply) {
  var text = reply.trim();
  if (text.indexOf('|') == 2) text = text.substring(3);
  return text.startsWith('OK');
}

/// The MediaMesh frequency must not be the main radio's channel.
bool sameChannelAsMain(
  MediaMeshSettings s, {
  required int? mainFreqHz,
  required int? mainBwHz,
  required int? mainSf,
}) {
  if (mainFreqHz == null || mainBwHz == null || mainSf == null) return false;
  return (s.frequencyMHz * 1000000 - mainFreqHz).abs() < 500 &&
      s.bandwidth.hz == mainBwHz &&
      s.spreadingFactor.value == mainSf;
}

class MediaMeshException implements Exception {
  final String message;
  MediaMeshException(this.message);
  @override
  String toString() => message;
}

/// Reads and writes MediaMesh on the connected radio.
class MediaMeshController {
  final MeshCoreConnector connector;
  MediaMeshController(this.connector);

  Future<String?> _cli(String command) async {
    try {
      return await connector.runLocalCliCommand(command);
    } catch (_) {
      return null; // no local CLI, or no answer
    }
  }

  Future<MediaMeshState> load() async {
    final radio2Text = await _cli('get radio2');
    final radio2 = radio2Text == null ? null : Radio2Reply.tryParse(radio2Text);
    if (radio2 == null) {
      return const MediaMeshState(
        support: MediaMeshSupport.none,
        settings: MediaMeshSettings.defaults,
      );
    }
    final summary = await _cli('get mediamesh');
    if (summary != null && summary.contains('unsupported')) {
      return const MediaMeshState(
        support: MediaMeshSupport.none,
        settings: MediaMeshSettings.defaults,
        detail: 'This radio can\'t run MediaMesh.',
      );
    }
    final mediaText = await _cli('get tx.media');
    final route = mediaText == null ? null : parseTxMediaReply(mediaText);
    var settings = MediaMeshSettings.defaults;
    if (!radio2.off) {
      settings = settings.copyWith(
        frequencyMHz: radio2.frequencyMHz,
        bandwidth: radio2.bandwidth,
        spreadingFactor: radio2.spreadingFactor,
        codingRate: radio2.codingRate,
      );
    }
    settings = settings.copyWith(
      enabled: radio2.canTransmit && route == 'radio2',
    );
    return MediaMeshState(
      support: route == null
          ? MediaMeshSupport.noMediaRouting
          : MediaMeshSupport.full,
      settings: settings,
    );
  }

  /// Applies [s]: on = radio2 listening and sending, no crossing, media on
  /// radio2; off = media back on the main radio and radio2 off.
  Future<void> apply(MediaMeshSettings s) async {
    if (s.enabled) {
      final set = await _cli(buildSetRadio2Command(s));
      if (set == null || !isCliOk(set)) {
        throw MediaMeshException(_reason(set, 'The radio rejected radio2'));
      }
      await _cli('set radio2.cross off');
      final media = await _cli('set tx.media radio2');
      if (media == null || !isCliOk(media)) {
        throw MediaMeshException(
          _reason(media, 'This firmware cannot send media on radio2'),
        );
      }
    } else {
      await _cli('set tx.media radio');
      final off = await _cli('set radio2 off');
      if (off == null || !isCliOk(off)) {
        throw MediaMeshException(
          _reason(off, 'The radio did not turn radio2 off'),
        );
      }
    }
  }

  static String _reason(String? reply, String fallback) {
    if (reply == null) return fallback;
    final text = reply.trim();
    if (text.startsWith('Error:')) return text.substring(6).trim();
    if (text.isEmpty || text == 'Unknown command') return fallback;
    return text;
  }
}
