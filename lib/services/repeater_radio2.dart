import '../models/radio_settings.dart';
import 'media_mesh.dart';

/// MediaMesh (radio2) on a repeater, room server or sensor, over remote admin.
///
/// The commands and replies are mikecarper/MeshCore's (docs/radio_profiles.md),
/// the same ones Wadamesh answers locally:
///
/// - `get radio2` / `set radio2 MHz,kHz,sf,cr,rx|rxtx[,preamble]` / `set radio2 off`
/// - `get radio2.cross` / `set radio2.cross auto|on|off`: forwarding between
///   the two profiles
/// - `get tx.reply` / `set tx.reply both|radio|radio2|auto|off [force]`:
///   which profile the repeater's own replies (CLI, logins, ACKs) go out on
/// - `get tempradio2` / `set tempradio2 ...,mode,minutes[,preamble]` / `off`
/// - `get radio2.status`: packet counters, switch timing, warnings
///
/// A remote `set radio2` or `set tempradio2` takes effect after the repeater
/// has sent its reply, so the admin hears the answer on the old channel.

/// Where the repeater's own replies go (`tx.reply`).
enum ReplyRoute {
  both('both'),
  radio('radio'),
  radio2('radio2'),
  auto('auto'),
  off('off');

  final String cli;
  const ReplyRoute(this.cli);

  static ReplyRoute? fromCli(String text) {
    for (final r in values) {
      if (r.cli == text) return r;
    }
    return null;
  }

  /// `force` only applies to these: replies on a listen-only radio2.
  bool get canForce => this == both || this == radio2;
}

/// `get tx.reply`: `> both`, `> both force`, `> radio2; radio2 TX unavailable`.
class TxReplySetting {
  final ReplyRoute route;
  final bool force;

  /// The repeater says the chosen radio2 cannot send right now.
  final bool radio2Unavailable;

  const TxReplySetting({
    required this.route,
    this.force = false,
    this.radio2Unavailable = false,
  });

  static TxReplySetting? tryParse(String reply) {
    final text = _strip(reply);
    if (!text.startsWith('>')) return null;
    final body = text.substring(1).trim();
    final words = body.split(';').first.trim().split(RegExp(r'\s+'));
    final route = ReplyRoute.fromCli(words.first);
    if (route == null) return null;
    return TxReplySetting(
      route: route,
      force: words.contains('force'),
      radio2Unavailable: body.contains('TX unavailable'),
    );
  }

  String get command =>
      'set tx.reply ${route.cli}${force && route.canForce ? ' force' : ''}';
}

/// What `radio2.cross` does on a repeater: whether packets heard on one
/// profile are forwarded on the other.
enum Radio2Cross {
  auto('auto'),
  on('on'),
  off('off');

  final String cli;
  const Radio2Cross(this.cli);

  static Radio2Cross? fromCli(String? text) {
    for (final c in values) {
      if (c.cli == text) return c;
    }
    return null;
  }
}

/// The repeater's main radio (`get radio`: `> 910.525,62.5,7,5[,preamble]`).
class MainRadio {
  final double frequencyMHz;
  final double bandwidthKHz;
  final int spreadingFactor;
  final int codingRate;

  const MainRadio({
    required this.frequencyMHz,
    required this.bandwidthKHz,
    required this.spreadingFactor,
    required this.codingRate,
  });

  static MainRadio? tryParse(String reply) {
    final text = _strip(reply);
    if (!text.startsWith('>')) return null;
    final parts = text
        .substring(1)
        .split(';')
        .first
        .split(',')
        .map((p) => p.trim())
        .toList();
    if (parts.length < 4) return null;
    final f = double.tryParse(parts[0]);
    final bw = double.tryParse(parts[1]);
    final sf = int.tryParse(parts[2]);
    final cr = int.tryParse(parts[3]);
    if (f == null || bw == null || sf == null || cr == null) return null;
    return MainRadio(
      frequencyMHz: f,
      bandwidthKHz: bw,
      spreadingFactor: sf,
      codingRate: cr <= 4 ? cr + 4 : cr,
    );
  }
}

/// A radio2 profile as the admin edits it.
class Radio2Profile {
  final Radio2Mode mode;
  final double frequencyMHz;
  final LoRaBandwidth bandwidth;
  final LoRaSpreadingFactor spreadingFactor;
  final LoRaCodingRate codingRate;

  /// Symbols; null lets the firmware work it out (recommended).
  final int? preamble;

  const Radio2Profile({
    required this.mode,
    required this.frequencyMHz,
    required this.bandwidth,
    required this.spreadingFactor,
    required this.codingRate,
    this.preamble,
  });

  static const defaults = Radio2Profile(
    mode: Radio2Mode.off,
    frequencyMHz: 911.15,
    bandwidth: LoRaBandwidth.bw125,
    spreadingFactor: LoRaSpreadingFactor.sf7,
    codingRate: LoRaCodingRate.cr4_5,
  );

  /// From `get radio2`; an off radio2 keeps [fallback]'s figures.
  static Radio2Profile fromReply(Radio2Reply r, {Radio2Profile? fallback}) {
    final base = fallback ?? defaults;
    if (r.off) return base.copyWith(mode: Radio2Mode.off);
    return Radio2Profile(
      mode: Radio2Mode.fromCli(r.mode),
      frequencyMHz: r.frequencyMHz,
      bandwidth: r.bandwidth ?? base.bandwidth,
      spreadingFactor: r.spreadingFactor ?? base.spreadingFactor,
      codingRate: r.codingRate ?? base.codingRate,
      preamble: r.preambleAuto ? null : r.preamble,
    );
  }

  Radio2Profile copyWith({
    Radio2Mode? mode,
    double? frequencyMHz,
    LoRaBandwidth? bandwidth,
    LoRaSpreadingFactor? spreadingFactor,
    LoRaCodingRate? codingRate,
    int? Function()? preamble,
  }) => Radio2Profile(
    mode: mode ?? this.mode,
    frequencyMHz: frequencyMHz ?? this.frequencyMHz,
    bandwidth: bandwidth ?? this.bandwidth,
    spreadingFactor: spreadingFactor ?? this.spreadingFactor,
    codingRate: codingRate ?? this.codingRate,
    preamble: preamble == null ? this.preamble : preamble(),
  );

  /// `MHz,kHz,sf,cr,mode`; off writes `rxtx` (only used for temporary runs).
  String tuple({Radio2Mode? as}) {
    final m = as ?? (mode == Radio2Mode.off ? Radio2Mode.rxtx : mode);
    return '${frequencyMHz.toStringAsFixed(3)},'
        '${formatBandwidthKHz(bandwidth)},'
        '${spreadingFactor.value},${codingRate.value},${m.cli}';
  }

  /// `set radio2 ...` for this profile, or `set radio2 off`.
  String get setCommand => mode == Radio2Mode.off
      ? 'set radio2 off'
      : 'set radio2 ${tuple()}${preamble == null ? '' : ',$preamble'}';

  /// `set tempradio2 ...,minutes[,preamble]` (1-10080 minutes).
  String tempCommand(int minutes) =>
      'set tempradio2 ${tuple()},$minutes${preamble == null ? '' : ',$preamble'}';

  /// Same channel as the main radio: radio2 must differ from it.
  bool sameChannelAs(MainRadio? main) {
    if (main == null) return false;
    return (frequencyMHz - main.frequencyMHz).abs() < 0.0005 &&
        (bandwidth.hz - main.bandwidthKHz * 1000).abs() < 1 &&
        spreadingFactor.value == main.spreadingFactor;
  }

  bool sameAs(Radio2Profile o) =>
      mode == o.mode &&
      (frequencyMHz - o.frequencyMHz).abs() < 0.0005 &&
      bandwidth == o.bandwidth &&
      spreadingFactor == o.spreadingFactor &&
      codingRate == o.codingRate &&
      preamble == o.preamble;

  /// Rough time on air for a 100-byte packet, in ms (Semtech's formula), to
  /// show how much faster radio2 is than the main mesh.
  static double airtimeMs({
    required double bandwidthHz,
    required int sf,
    required int cr,
    int payload = 100,
    int preamble = 16,
  }) {
    final ts = (1 << sf) / bandwidthHz * 1000;
    final de = (sf >= 11 && bandwidthHz <= 125000) ? 1 : 0;
    final n = 8 * payload - 4 * sf + 28 + 16;
    final symbols =
        8 + ((n / (4 * (sf - 2 * de))).ceil().clamp(0, 1 << 30)) * cr;
    return (preamble + 4.25) * ts + symbols * ts;
  }
}

/// A refusal from the repeater (`Error: ...`) or no answer at all.
class Radio2CommandException implements Exception {
  final String message;

  /// The firmware only allows this change over USB on this role.
  final bool needsUsb;

  Radio2CommandException(this.message, {this.needsUsb = false});

  @override
  String toString() => message;
}

/// Sends one CLI line to the repeater and returns its reply (without the
/// `XX|` tag); throws when nothing comes back.
typedef RemoteCli = Future<String> Function(String command);

class RepeaterRadio2Controller {
  final RemoteCli _send;
  RepeaterRadio2Controller(this._send);

  /// `get <key>`; null for an error or `Unknown command` reply, which means
  /// this firmware has no such setting.
  Future<String?> get(String key) async {
    final reply = await _send('get $key');
    final text = _strip(reply);
    return text.startsWith('>') ? text : null;
  }

  Future<Radio2Reply?> radio2() async {
    final r = await get('radio2');
    return r == null ? null : Radio2Reply.tryParse(r);
  }

  Future<MainRadio?> mainRadio() async {
    final r = await get('radio');
    return r == null ? null : MainRadio.tryParse(r);
  }

  Future<Radio2Cross?> cross() async {
    final r = await get('radio2.cross');
    return r == null ? null : Radio2Cross.fromCli(parseCrossReply(r));
  }

  Future<TxReplySetting?> txReply() async {
    final r = await get('tx.reply');
    return r == null ? null : TxReplySetting.tryParse(r);
  }

  /// The running temporary radio2, or null when there is none.
  Future<TempRadio2?> temp() async {
    final r = await get('tempradio2');
    return r == null ? null : TempRadio2.tryParse(r);
  }

  Future<Radio2Status?> status() async {
    final r = await get('radio2.status');
    return r == null ? null : Radio2Status.tryParse(r);
  }

  Future<String> applyProfile(Radio2Profile p) => _ok(p.setCommand);

  Future<String> setCross(Radio2Cross c) => _ok('set radio2.cross ${c.cli}');

  Future<String> setTxReply(TxReplySetting s) => _ok(s.command);

  Future<String> startTemp(Radio2Profile p, int minutes) =>
      _ok(p.tempCommand(minutes));

  Future<String> stopTemp() => _ok('set tempradio2 off');

  Future<String> _ok(String command) async {
    final reply = _strip(await _send(command));
    if (reply.startsWith('OK')) return reply;
    throw Radio2CommandException(
      reply.startsWith('Error:') ? reply.substring(6).trim() : reply,
      needsUsb: reply.contains('local USB'),
    );
  }
}

String _strip(String reply) {
  var text = reply.trim();
  if (text.indexOf('|') == 2) text = text.substring(3).trimLeft();
  return text;
}
