import '../connector/meshcore_connector.dart';
import '../models/radio_settings.dart';

/// MediaMesh: photos and voice clips on a second LoRa profile (`radio2`) of the
/// connected radio, while text stays on the main mesh. The radio scans both
/// profiles; the firmware decides which packets are media. The app only reads
/// and writes the radio's settings through the local CLI, with the command
/// names shared by Wadamesh and mikecarper/MeshCore:
///
/// - `get radio2`, `set radio2 MHz,kHz,sf,cr,rx|rxtx`, `set radio2 off`
/// - `get tx.media`, `set tx.media auto|radio|radio2|both|off`
/// - `get/set radio2.cross auto|on|off` (copy ordinary traffic onto radio2)
/// - `get radio2.status`, `get/set tempradio2 ...,minutes|off`
/// - `get/set tx.user key:<hex> <choice>`, `get/set tx.channel <slot> <choice>`
///
/// See documentation/media-mesh.md.
/// radio2's mode: off, listen only, or listen and send.
enum Radio2Mode {
  off('off'),
  rx('rx'),
  rxtx('rxtx');

  final String cli;
  const Radio2Mode(this.cli);

  static Radio2Mode fromCli(String text) => switch (text) {
    'rx' => Radio2Mode.rx,
    'rxtx' || 'rx&tx' => Radio2Mode.rxtx,
    _ => Radio2Mode.off,
  };
}

/// What goes on radio2.
enum MediaChoice {
  /// Photos and voice only: `tx.media radio2`, `radio2.cross off`.
  photosAndVoice,

  /// Everything, photos and voice included: `tx.media auto`,
  /// `radio2.cross on`.
  everything,

  /// Any other mix, set from the radio console.
  custom;

  static MediaChoice from({required String? media, required String? cross}) {
    if (media == 'radio2' && cross == 'off') return MediaChoice.photosAndVoice;
    if (media == 'auto' && cross == 'on') return MediaChoice.everything;
    return MediaChoice.custom;
  }
}

class MediaMeshSettings {
  final Radio2Mode mode;
  final MediaChoice media;
  final double frequencyMHz;
  final LoRaBandwidth bandwidth;
  final LoRaSpreadingFactor spreadingFactor;
  final LoRaCodingRate codingRate;

  const MediaMeshSettings({
    required this.mode,
    this.media = MediaChoice.photosAndVoice,
    required this.frequencyMHz,
    required this.bandwidth,
    required this.spreadingFactor,
    required this.codingRate,
  });

  bool get enabled => mode != Radio2Mode.off;

  /// 912.0 MHz, 125 kHz, SF7, CR 4/5: about twice as fast as SF7/62.5 for
  /// ~3 dB less range, and inside a BayMesh 3 cavity filter tuned for 910.525
  /// (flat 908.6-912.8 MHz), 1.5 MHz clear of the main channel.
  static const defaults = MediaMeshSettings(
    mode: Radio2Mode.off,
    frequencyMHz: 912.0,
    bandwidth: LoRaBandwidth.bw125,
    spreadingFactor: LoRaSpreadingFactor.sf7,
    codingRate: LoRaCodingRate.cr4_5,
  );

  MediaMeshSettings copyWith({
    Radio2Mode? mode,
    MediaChoice? media,
    double? frequencyMHz,
    LoRaBandwidth? bandwidth,
    LoRaSpreadingFactor? spreadingFactor,
    LoRaCodingRate? codingRate,
  }) => MediaMeshSettings(
    mode: mode ?? this.mode,
    media: media ?? this.media,
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

  /// The live `get radio2.status` figures, when the radio has them.
  final Radio2Status? status;

  /// A running `tempradio2`, or null.
  final TempRadio2? temp;

  /// The radio's own reason when it cannot run radio2 (e.g. an LR1110 board).
  final String? detail;

  const MediaMeshState({
    required this.support,
    required this.settings,
    this.status,
    this.temp,
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

  /// The preamble in symbols, when the reply gives one.
  final int? preamble;

  /// True when the firmware works the preamble out itself (`(auto)`).
  final bool preambleAuto;

  const Radio2Reply._({
    required this.off,
    this.frequencyMHz = 0,
    this.bandwidth,
    this.spreadingFactor,
    this.codingRate,
    this.mode = 'off',
    this.preamble,
    this.preambleAuto = true,
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
    final preambleText = parts.length > 5 ? parts[5] : '';
    final preamble = int.tryParse(preambleText.split(' ').first);
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
      preamble: preamble,
      preambleAuto: preamble == null || preambleText.contains('auto'),
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

String _profileTuple(MediaMeshSettings s, Radio2Mode mode) =>
    '${s.frequencyMHz.toStringAsFixed(3)},'
    '${formatBandwidthKHz(s.bandwidth)},'
    '${s.spreadingFactor.value},${s.codingRate.value},${mode.cli}';

/// `set radio2 ...`; an off mode still writes the profile as `rxtx`.
String buildSetRadio2Command(MediaMeshSettings s) => 'set radio2 '
    '${_profileTuple(s, s.mode == Radio2Mode.off ? Radio2Mode.rxtx : s.mode)}';

/// `set tempradio2 f,bw,sf,cr,rxtx,minutes`: [s] replaces radio2 for
/// [minutes] (1-10080).
String buildTempRadio2Command(MediaMeshSettings s, int minutes) =>
    'set tempradio2 ${_profileTuple(s, Radio2Mode.rxtx)},$minutes';

String _stripTag(String reply) {
  var text = reply.trim();
  if (text.indexOf('|') == 2) text = text.substring(3);
  return text;
}

/// `get radio2.cross`: `auto`, `on` or `off`, or null.
String? parseCrossReply(String reply) {
  final text = _stripTag(reply);
  if (!text.startsWith('>')) return null;
  final value = text.substring(1).trim().split(RegExp(r'[\s;]')).first;
  return const {'auto', 'on', 'off'}.contains(value) ? value : null;
}

/// The figures of `get radio2.status`:
/// `> rxtx; RX=12,40 TX=3,9 switches=5120 errors=0 max=1203us
/// preamble=32,64; test=4/4 ready budget=1324us; WARN ...`.
class Radio2Status {
  final String mode;
  final List<int> rx;
  final List<int> tx;
  final int? switchUs;
  final bool switchMeasured;
  final List<String> warnings;

  /// Profile switches so far, failed ones, and the longest in µs.
  final int? switches;
  final int? switchErrors;
  final int? longestSwitchUs;

  /// Preamble in symbols: main, radio2.
  final List<int>? preamble;

  /// A remote radio2 change is waiting for its reply to go out (repeaters):
  /// the previous channel is still in use.
  final bool pending;

  const Radio2Status({
    required this.mode,
    required this.rx,
    required this.tx,
    this.switchUs,
    this.switchMeasured = false,
    this.warnings = const [],
    this.switches,
    this.switchErrors,
    this.longestSwitchUs,
    this.preamble,
    this.pending = false,
  });

  static Radio2Status? tryParse(String reply) {
    final text = _stripTag(reply);
    if (!text.startsWith('>')) return null;
    final body = text.substring(1).trim();
    if (body.startsWith('radio2 change pending')) {
      return const Radio2Status(
        mode: 'pending',
        rx: [0, 0],
        tx: [0, 0],
        pending: true,
      );
    }
    final mode = body.split(RegExp(r'[\s;]')).first;
    int? one(String key) {
      final m = RegExp('$key=(\\d+)').firstMatch(body);
      return m == null ? null : int.parse(m.group(1)!);
    }

    List<int> pair(String key) {
      final m = RegExp('$key=(\\d+),(\\d+)').firstMatch(body);
      if (m == null) return const [0, 0];
      return [int.parse(m.group(1)!), int.parse(m.group(2)!)];
    }

    final budget = RegExp(r'budget=(\d+)us').firstMatch(body);
    final warnings = <String>[];
    for (final part in body.split(';')) {
      final p = part.trim();
      if (p.startsWith('WARN') || p.startsWith('short override')) {
        warnings.add(p.startsWith('WARN ') ? p.substring(5) : p);
      }
    }
    final pre = RegExp(r'preamble=(\d+),(\d+)').firstMatch(body);
    final longest = RegExp(r'max=(\d+)us').firstMatch(body);
    return Radio2Status(
      mode: mode,
      rx: pair('RX'),
      tx: pair('TX'),
      switchUs: budget == null ? null : int.parse(budget.group(1)!),
      switchMeasured: body.contains(' ready'),
      warnings: warnings,
      switches: one('switches'),
      switchErrors: one('errors'),
      longestSwitchUs: longest == null ? null : int.parse(longest.group(1)!),
      preamble: pre == null
          ? null
          : [int.parse(pre.group(1)!), int.parse(pre.group(2)!)],
    );
  }
}

/// A running `tempradio2`: `> 910.500,500.000,8,5,rxtx,40 (auto);
/// 0d2h0m (120 min) left`.
class TempRadio2 {
  final double frequencyMHz;
  final int minutesLeft;

  const TempRadio2({required this.frequencyMHz, required this.minutesLeft});

  /// Null for `> off` and anything that is not an answer.
  static TempRadio2? tryParse(String reply) {
    final r = Radio2Reply.tryParse(reply);
    if (r == null || r.off) return null;
    final m = RegExp(r'\((\d+) min\) left').firstMatch(reply);
    return TempRadio2(
      frequencyMHz: r.frequencyMHz,
      minutesLeft: m == null ? 0 : int.parse(m.group(1)!),
    );
  }
}

/// Where one contact's or channel's traffic is sent (`tx.user`, `tx.channel`).
enum TxChoice {
  auto('auto'),
  radio('radio'),
  radio2('radio2'),
  both('both'),
  off('off');

  final String cli;
  const TxChoice(this.cli);

  static TxChoice? fromCli(String text) {
    for (final c in TxChoice.values) {
      if (c.cli == text) return c;
    }
    return null;
  }
}

/// One `get/set tx.user` or `tx.channel` answer:
/// `> tx.user "Alice" key:0123456789AB radio2; active=radio2` or
/// `OK - tx.channel 2 "#r2-ops" radio2; active=radio2 (#r2- channel)`.
class TxRouteReply {
  final TxChoice choice;

  /// Where the next packet would go now: `radio`, `radio2`, `both` or `none`.
  final String active;

  /// An `#r2-` channel: always radio2, set by its name.
  final bool boundByName;

  /// radio2 was chosen but cannot send right now.
  final bool radio2Unavailable;

  const TxRouteReply({
    required this.choice,
    required this.active,
    this.boundByName = false,
    this.radio2Unavailable = false,
  });

  static TxRouteReply? tryParse(String reply) {
    final text = _stripTag(reply);
    final m = RegExp(
      r'^(?:OK - |> )tx\.(?:user|channel) .* (auto|radio|radio2|both|off); '
      r'active=(\S+)',
    ).firstMatch(text);
    if (m == null) return null;
    final choice = TxChoice.fromCli(m.group(1)!);
    if (choice == null) return null;
    return TxRouteReply(
      choice: choice,
      active: m.group(2)!,
      boundByName: text.contains('(#r2- channel)'),
      radio2Unavailable: text.contains('radio2 unavailable'),
    );
  }
}

/// `key:` + the first 16 bytes of a contact's public key, as `tx.user` takes it.
String txUserTarget(String publicKeyHex) {
  final hex = publicKeyHex.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
  return 'key:${hex.length > 32 ? hex.substring(0, 32) : hex}';
}

/// The tx.media choice (`auto`, `radio`, `radio2`, `both` or `off`; newer
/// firmware adds `; active=...`), or null when the firmware does not know
/// tx.media.
String? parseTxMediaReply(String reply) {
  var text = reply.trim();
  if (text.indexOf('|') == 2) text = text.substring(3);
  if (!text.startsWith('>')) return null;
  final value = text.substring(1).trim().split(RegExp(r'[\s;]')).first;
  const known = {'auto', 'radio', 'radio2', 'both', 'off'};
  return known.contains(value) ? value : null;
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
    final crossText = await _cli('get radio2.cross');
    final cross = crossText == null ? null : parseCrossReply(crossText);
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
      mode: radio2.off ? Radio2Mode.off : Radio2Mode.fromCli(radio2.mode),
      // Untouched routing (auto/auto) reads as the photos-and-voice preset
      // that turning radio2 on applies.
      media: radio2.off && route == 'auto' && cross == 'auto'
          ? MediaChoice.photosAndVoice
          : MediaChoice.from(media: route, cross: cross),
    );
    final statusText = await _cli('get radio2.status');
    final tempText = await _cli('get tempradio2');
    return MediaMeshState(
      support: route == null
          ? MediaMeshSupport.noMediaRouting
          : MediaMeshSupport.full,
      settings: settings,
      status: statusText == null ? null : Radio2Status.tryParse(statusText),
      temp: tempText == null ? null : TempRadio2.tryParse(tempText),
    );
  }

  /// The live figures only, for a periodic refresh.
  Future<(Radio2Status?, TempRadio2?)> refreshStatus() async {
    final statusText = await _cli('get radio2.status');
    final tempText = await _cli('get tempradio2');
    return (
      statusText == null ? null : Radio2Status.tryParse(statusText),
      tempText == null ? null : TempRadio2.tryParse(tempText),
    );
  }

  /// Applies [s]: the radio2 profile and mode, then (with radio2 on) what
  /// goes on it. Off sends media back to the main radio and turns radio2 off.
  /// A [MediaChoice.custom] choice leaves the routing as the radio has it.
  Future<void> apply(MediaMeshSettings s) async {
    if (s.enabled) {
      await _ok(buildSetRadio2Command(s), 'The radio rejected radio2');
      switch (s.media) {
        case MediaChoice.photosAndVoice:
          await _ok('set radio2.cross off', 'The radio kept radio2.cross');
          await _ok(
            'set tx.media radio2',
            'This firmware cannot send media on radio2',
          );
        case MediaChoice.everything:
          await _ok('set radio2.cross on', 'The radio kept radio2.cross');
          await _ok('set tx.media auto', 'The radio kept tx.media');
        case MediaChoice.custom:
          break;
      }
    } else {
      await _cli('set tx.media radio');
      await _ok('set radio2 off', 'The radio did not turn radio2 off');
    }
  }

  /// Replaces radio2 with [s] for [minutes]; the saved radio2 comes back
  /// afterwards (or on a reboot).
  Future<void> startTemporary(MediaMeshSettings s, int minutes) =>
      _ok(buildTempRadio2Command(s, minutes), 'The radio rejected tempradio2');

  Future<void> stopTemporary() =>
      _ok('set tempradio2 off', 'The radio kept tempradio2');

  /// `get tx.user` for a contact, or null when the firmware has no tx.user.
  Future<TxRouteReply?> getUserRoute(String publicKeyHex) async {
    final r = await _cli('get tx.user ${txUserTarget(publicKeyHex)}');
    return r == null ? null : TxRouteReply.tryParse(r);
  }

  Future<TxRouteReply> setUserRoute(String publicKeyHex, TxChoice c) =>
      _route('set tx.user ${txUserTarget(publicKeyHex)} ${c.cli}');

  /// `get tx.channel` for a channel slot.
  Future<TxRouteReply?> getChannelRoute(int slot) async {
    final r = await _cli('get tx.channel $slot');
    return r == null ? null : TxRouteReply.tryParse(r);
  }

  Future<TxRouteReply> setChannelRoute(int slot, TxChoice c) =>
      _route('set tx.channel $slot ${c.cli}');

  Future<TxRouteReply> _route(String command) async {
    final r = await _cli(command);
    final parsed = r == null ? null : TxRouteReply.tryParse(r);
    if (parsed == null) {
      throw MediaMeshException(_reason(r, 'The radio did not save this'));
    }
    return parsed;
  }

  Future<void> _ok(String command, String fallback) async {
    final r = await _cli(command);
    if (r == null || !isCliOk(r)) throw MediaMeshException(_reason(r, fallback));
  }

  static String _reason(String? reply, String fallback) {
    if (reply == null) return fallback;
    final text = reply.trim();
    if (text.startsWith('Error:')) return text.substring(6).trim();
    if (text.isEmpty || text == 'Unknown command') return fallback;
    return text;
  }
}
