// MeshCore Open TAK - on-demand voice messages over MeshCore.
//
// Send: record -> Codec2 -> clip kept locally -> only a VE3 text envelope goes
// out. Listeners pull the audio when they press play, using the cheapest
// transport that can work:
//
//   1. Direct (raw data along a known route). Cheapest on air.
//   2. No route yet but the sender is a contact: a silent `VR3:` DM. It floods,
//      and its ACK exchange gives both radios a direct route; the sender then
//      answers over raw data.
//   3. Channel fallback (sender not a contact, or direct failed): the request
//      and the packets are flooded as GRP_DATA on the channel the envelope
//      was posted in. Every listener on the channel collects them, so one
//      transfer serves everyone who taps the clip.

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../connector/meshcore_connector.dart';
import '../connector/meshcore_protocol.dart';
import '../models/channel.dart';
import '../models/contact.dart';
import '../services/media_lockdown.dart';
import '../services/otp_service.dart';
import '../services/media_mesh.dart'
    show MediaAirProfile, Radio2Reply, loadMediaAirProfile;
import '../services/media_mesh_nearby.dart';
import '../services/image_chunk_transport.dart'
    show parseChannelDataFrame, respCodeChannelDataRecv;
import 'voice_clip_store.dart';
import 'av1_ffi.dart';
import 'image_codec.dart';
import 'mimi.dart';
import 'resample.dart';
import 'voice_codec.dart';
import 'voice_codec_choice.dart';
import 'voice_dsp.dart';
import 'vox_fec.dart';
import 'vox_gaps.dart';
import 'vox_voice_enhance.dart';
import 'voice_wire.dart';
import 'walkie_wire.dart';
import 'vox_timing.dart';
import '../utils/lora_airtime.dart';
import 'wav.dart';
import '../team/photo_mosaic_prefs.dart';

enum VoxClipStatus { remote, requesting, receiving, complete, unavailable }

/// Playback of one clip: decoding it (Mimi takes a few seconds), then audio.
enum VoxPlayback { idle, preparing, playing }

@immutable
/// How a downloaded clip's packets reached this radio (Wadamesh MediaMesh).
enum VoxReceivedVia {
  mainMesh,
  mediaMesh,
  both;

  /// From a bit mask: bit 0 main mesh, bit 1 radio2. Null for 0.
  static VoxReceivedVia? fromMask(int? mask) => switch ((mask ?? 0) & 3) {
    1 => VoxReceivedVia.mainMesh,
    2 => VoxReceivedVia.mediaMesh,
    3 => VoxReceivedVia.both,
    _ => null,
  };

  /// The connected radio has radio2 on (its last `get radio2` answer). Set
  /// by [VoxVoiceService].
  static bool connectedRadioHasRadio2 = false;

  /// What to show for something this radio received, null for nothing.
  /// Wadamesh tags each frame with the radio it came in on. An untagged
  /// frame from a radio without radio2 came over the main mesh; from one
  /// with radio2 (keymindCascade doesn't tag frames) it could have come
  /// either way, so nothing is claimed.
  static VoxReceivedVia? forReceived(int? mask) =>
      fromMask(mask) ??
      (connectedRadioHasRadio2 ? null : VoxReceivedVia.mainMesh);
}

class VoxClipState {
  final VoxClipStatus status;
  final int received;
  final int total;
  final String? message;

  /// For a finished download: which radio profile it came over, when the
  /// radio said (Wadamesh with MediaMesh on).
  final VoxReceivedVia? via;

  /// The MediaMesh repeater that relayed its last radio2 packet, as hex
  /// ("1ffb"), when the radio said.
  final String? viaRepeater;

  const VoxClipState(
    this.status, {
    this.received = 0,
    this.total = 0,
    this.message,
    this.via,
    this.viaRepeater,
  });

  double get progress => total == 0 ? 0 : received / total;
}

enum _Method {
  direct,
  dmRequest,
  channel,

  /// A raw request with an empty path: every radio in range hears it, and
  /// any that holds the clip (or part of it) answers zero-hop. For a clip
  /// whose packets were heard at 0 hops, when no route is known.
  zeroHop,
}

/// A recording encoded and ready to send (and to preview).
@immutable
class VoxEncodedClip {
  final VoxVoiceMode mode;
  final Uint8List bits;
  final int durationSeconds;
  const VoxEncodedClip(this.mode, this.bits, this.durationSeconds);
}

/// One line of the VOX voice diagnostic log (shown from a voice bubble).
@immutable
class VoxLogEntry {
  final DateTime time;
  final String sessionId; // '' when not tied to a clip
  final String text;
  const VoxLogEntry(this.time, this.sessionId, this.text);

  @override
  String toString() {
    final t = time.toIso8601String().substring(11, 23);
    return sessionId.isEmpty ? '$t $text' : '$t [$sessionId] $text';
  }
}

class _IncomingClip {
  final VoxVoiceEnvelope envelope;
  final Map<int, Uint8List> packets = {};

  /// Parity packets heard (vox_fec.dart): info byte -> `[lastLen][parity]`.
  final Map<int, Uint8List> parity = {};

  /// Packets rebuilt from parity rather than received.
  int rebuilt = 0;

  /// Fewest hops any of its channel packets came over (99: none seen).
  int minHops = 99;

  /// The zero-hop raw request has been tried since the last reset.
  bool triedZeroHop = false;
  VoxClipStatus status = VoxClipStatus.remote;
  String? message;
  Contact? sender;
  int? channelIndex;
  int attempts = 0;
  int directFailures = 0;

  /// Every request's salt, so retries for the same packets differ.
  final VoxSaltCounter salts = VoxSaltCounter();

  /// The channel fallback has been tried since the last manual retry.
  bool triedChannel = false;

  /// Ask the sender to reply along our request's path (true) or along its
  /// own stored route (false). Flipped whenever a direct request gets
  /// nothing back, so one-way links get both chances.
  bool askReplyAlongPath = true;
  bool sentDmRequest = false;
  _Method? lastMethod;
  int packetsAtLastAttempt = 0;
  int stalls = 0;

  /// Highest packet index asked for in the latest request (sent last).
  int expectedLast = -1;
  Timer? watchdog;

  /// Some packet came through a repeater (or by a way that doesn't say):
  /// packets can arrive out of order, so a gap may still fill.
  bool relayed = false;

  /// When the last new packet of the current burst came in (null: the next
  /// one starts a burst, its gap being the round trip, not the pacing).
  DateTime? rxLast;

  /// The burst's gap between packets, smoothed, and how many gaps that's from.
  int rxGapMs = 0;
  int rxGaps = 0;

  void noteArrival(DateTime now) {
    final last = rxLast;
    if (last != null) {
      final g = now.difference(last).inMilliseconds;
      if (g >= 0 && g < 60000) {
        rxGapMs = rxGaps == 0 ? g : (rxGapMs * 3 + g) ~/ 4;
        rxGaps++;
      }
    }
    rxLast = now;
  }

  _IncomingClip(this.envelope);

  bool get isComplete => packets.length >= envelope.totalPackets;

  List<int> get missing => [
    for (var i = 0; i < envelope.totalPackets; i++)
      if (!packets.containsKey(i)) i,
  ];

  Uint8List joined() {
    final b = BytesBuilder(copy: false);
    for (var i = 0; i < envelope.totalPackets; i++) {
      final p = packets[i];
      if (p != null) b.add(p);
    }
    return b.toBytes();
  }
}

class VoxVoiceService extends ChangeNotifier {
  VoxVoiceService(this._connector, {VoxClipStore? store})
    : _store = store ?? VoxClipStore() {
    _sub = _connector.receivedFrames.listen(_onFrame);
    _connector.voxControlTextInterceptor = _onControlText;
    _connector.voxIncomingTextObserver = _onIncomingText;
    unawaited(_loadTestSettings());
    unawaited(_loadReceivedVia());
    mimi.addListener(notifyListeners);
    enhancer.addListener(_onEnhancerChanged);
  }

  // ------------------------------- which radio profile clips came over

  static const _kReceivedVia = 'vox_received_via';
  static const _maxReceivedVia = 400;

  /// sid -> bit mask of the profiles its packets arrived on (bit 0 main mesh,
  /// bit 1 radio2). Kept for finished clips so the label survives a restart.
  final Map<String, int> _viaMask = {};

  static const _kReceivedViaHop = 'vox_received_via_hop';

  /// sid -> the MediaMesh repeater (path hash, hex) its last radio2 packet
  /// came through, for "Received via MediaMesh (1ffb)".
  final Map<String, String> _viaHop = {};

  Future<void> _loadReceivedVia() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kReceivedVia);
      if (raw == null) return;
      final map = jsonDecode(raw);
      if (map is! Map) return;
      for (final e in map.entries) {
        if (e.key is String && e.value is int) {
          _viaMask.putIfAbsent(e.key as String, () => e.value as int);
        }
      }
      final hops = prefs.getString(_kReceivedViaHop);
      final hmap = hops == null ? null : jsonDecode(hops);
      if (hmap is Map) {
        for (final e in hmap.entries) {
          if (e.key is String && e.value is String) {
            _viaHop.putIfAbsent(e.key as String, () => e.value as String);
          }
        }
      }
      notifyListeners();
    } catch (_) {}
  }

  /// Last (radio, hops) logged per clip: logs when it first arrives and
  /// whenever that changes, so the info log shows which radio carried it.
  final Map<String, String> _arrivalLogged = {};

  void _logArrival(String sid, int? via, int? hops, [Uint8List? lastHop]) {
    final radio = switch (via) {
      0 => 'main mesh (radio tagged it)',
      1 => 'MediaMesh / radio2',
      _ => 'untagged (radio does not say which)',
    };
    // The last relay's path hash says which repeater it came through.
    final last =
        hops != null && hops > 0 && lastHop != null && lastHop.isNotEmpty
        ? ', last hop ${_hex(lastHop)}'
        : '';
    final key = '$radio, ${hops == null ? 'direct/raw' : '$hops hops'}$last';
    if (_arrivalLogged[sid] == key) return;
    _arrivalLogged[sid] = key;
    if (_arrivalLogged.length > 64) {
      _arrivalLogged.remove(_arrivalLogged.keys.first);
    }
    _logEvent('packets arriving via $key', sid);
  }

  void _noteVia(String sid, int? via, [Uint8List? lastHop]) {
    if (via == null) return;
    // The MediaMesh repeater this radio2 packet came through, the latest kept.
    if (via == 1 && lastHop != null && lastHop.isNotEmpty) {
      final hex = StringBuffer();
      for (final b in lastHop) {
        hex.write(b.toRadixString(16).padLeft(2, '0'));
      }
      _viaHop.remove(sid);
      _viaHop[sid] = hex.toString();
      while (_viaHop.length > _maxReceivedVia) {
        _viaHop.remove(_viaHop.keys.first);
      }
    }
    // Heard on radio2: a MediaMesh is on the air here, and busy just now.
    if (via == 1) {
      MediaMeshNearby.instance.markHeard();
      _r2HeardAt = DateTime.now();
    }
    // Re-inserted, so the most recent clips are the ones kept.
    final old = _viaMask.remove(sid) ?? 0;
    _viaMask[sid] = old | (1 << via);
    while (_viaMask.length > _maxReceivedVia) {
      _viaMask.remove(_viaMask.keys.first);
    }
  }

  Future<void> _saveReceivedVia() async {
    try {
      final done = {
        for (final e in _viaMask.entries)
          if (_bits.containsKey(e.key)) e.key: e.value,
      };
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kReceivedVia, jsonEncode(done));
      final hops = {
        for (final e in _viaHop.entries)
          if (_bits.containsKey(e.key)) e.key: e.value,
      };
      await prefs.setString(_kReceivedViaHop, jsonEncode(hops));
    } catch (_) {}
  }

  /// The Mimi neural codec (download state + inference).
  final VoxMimi mimi = VoxMimi();

  static const _kPreferMimi = 'vox_prefer_mimi';
  bool _preferMimi = true;

  /// Send new clips with Mimi when its model is downloaded (else Codec2).
  bool get preferMimi => _preferMimi;

  static const _kCodec2Mode = 'vox_codec2_mode';
  VoxVoiceMode _codec2Mode = voxDefaultVoiceMode;

  /// The Codec2 rate clips are recorded in when they go out as Codec2 (one of
  /// [voxCodec2RecordModes]).
  VoxVoiceMode get codec2Mode => _codec2Mode;

  Future<void> setCodec2Mode(VoxVoiceMode mode) async {
    if (!voxCodec2RecordModes.contains(mode) || mode == _codec2Mode) return;
    _codec2Mode = mode;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kCodec2Mode, mode.wireId);
    } catch (_) {}
  }

  /// The codec the next recording will be sent with.
  VoxVoiceMode get sendMode =>
      _preferMimi && mimi.isReady ? VoxVoiceMode.mimi : _codec2Mode;

  // ----------------------------------- per-chat codec: Codec2 for radios

  static const _kCodec2Targets = 'vox_codec2_targets';
  static const _kMimiTargets = 'vox_mimi_targets';
  static const _kCodecHeard = 'vox_codec_heard';
  final VoxCodecChoice _codecs = VoxCodecChoice();

  /// Key for a contact's per-chat voice settings.
  static String contactTarget(Contact c) => 'c:${c.publicKeyHex}';

  /// Key for a channel's per-chat voice settings.
  static String channelTarget(Channel ch) => 'ch:${ch.pskHex}';

  /// Whether clips to [target] go out as Codec2, so radios that can't run Mimi
  /// (Wadamesh on a T-Deck, say) can play them: switched on for the chat, or
  /// chosen automatically from what the chat sends us ([autoCodec2]).
  bool forcesCodec2(String? target) =>
      _codecs.forcesCodec2(target, now: DateTime.now());

  /// Codec2 because of what the chat sent: a contact whose latest clip was
  /// Codec2, or a channel where someone sent Codec2 in the last two weeks.
  bool autoCodec2(String? target) =>
      _codecs.autoCodec2(target, now: DateTime.now());

  /// The per-chat switch is on (rather than Codec2 being automatic).
  bool manualCodec2(String? target) => _codecs.manualCodec2(target);

  /// The switch was turned off against the automatic choice.
  bool manualMimi(String? target) => _codecs.manualMimi(target);

  Future<void> setForcesCodec2(String target, bool v) async {
    if (!_codecs.setManual(target, v, now: DateTime.now())) return;
    notifyListeners();
    await _saveCodecChoices(heard: false);
  }

  Future<void> _saveCodecChoices({bool heard = true}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_kCodec2Targets, _codecs.manualCodec2Targets);
      await prefs.setStringList(_kMimiTargets, _codecs.manualMimiTargets);
      if (heard) await prefs.setString(_kCodecHeard, _codecs.heardJson());
    } catch (_) {}
  }

  /// Notes which codec a chat's incoming clip used (see [VoxCodecChoice]).
  void _learnCodec(
    VoxVoiceEnvelope env, {
    String? senderKeyHex,
    int? channelIndex,
    DateTime? at,
  }) {
    if (!env.mode.isAudio) return;
    String? target;
    if (channelIndex != null) {
      for (final ch in _connector.channels) {
        if (ch.index == channelIndex) {
          target = channelTarget(ch);
          break;
        }
      }
    } else if (senderKeyHex != null && senderKeyHex.isNotEmpty) {
      final c = contactByKeyHex(senderKeyHex);
      target = c != null ? contactTarget(c) : 'c:$senderKeyHex';
    }
    if (target == null) return;
    final now = DateTime.now();
    final changed = _codecs.learn(
      target,
      mimi: env.mode.isMimi,
      at: at != null && at.isBefore(now) ? at : now,
      now: now,
    );
    if (changed) {
      _logEvent(
        forcesCodec2(target)
            ? 'replies to this chat now go out as Codec2 (it sent Codec2)'
            : 'replies to this chat go out as ${sendMode.label} again',
        env.sessionId,
      );
      notifyListeners();
    }
    unawaited(_saveCodecChoices());
  }

  /// The codec the next recording to [target] will be sent with.
  VoxVoiceMode sendModeFor(String? target) =>
      forcesCodec2(target) ? _codec2Mode : sendMode;

  // ------------------------------------------- photos: VOX or AI sketch

  static const _kPhotoAiSketch = 'vox_photo_ai_sketch';
  bool _photoAiSketch = false;
  static const _kPhotoAiSketchHd = 'vox_photo_ai_sketch_hd';
  bool _photoAiSketchHd = false;

  /// With [photoAiSketch]: the HD kind (AEIC ft2 on ncnn, ~1.4 KB,
  /// lib/vox/aeic_hd_service.dart) rather than the ~150 B one.
  bool get photoAiSketchHd => _photoAiSketchHd;

  Future<void> setPhotoAiSketchHd(bool v) async {
    _photoAiSketchHd = v;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kPhotoAiSketchHd, v);
    } catch (_) {}
  }

  /// Send photos as an AI sketch (AEIC, ~150 B) instead of a Mesh photo
  /// (AV1, real pixels). Off by default: VOX is the default.
  bool get photoAiSketch => _photoAiSketch;

  Future<void> setPhotoAiSketch(bool v) async {
    _photoAiSketch = v;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kPhotoAiSketch, v);
    } catch (_) {}
  }

  Future<void> setPreferMimi(bool v) async {
    _preferMimi = v;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kPreferMimi, v);
    } catch (_) {}
  }

  // ------------------------------------------------- testing: forced route

  static const _kForceRoute = 'vox_force_repeater_route';
  static const _kForceRouteKeys = 'vox_force_repeater_keys';

  bool _forceRepeaterRoute = false;
  List<String> _forcedRepeaterKeys = const [];

  /// Testing aid: send all voice raw data along [forcedRepeaterKeys] even
  /// when the two radios can hear each other directly.
  bool get forceRepeaterRoute => _forceRepeaterRoute;

  /// Public keys (hex) of the repeaters to route through, in order from the
  /// requester to the sender. Replies use the reverse order.
  List<String> get forcedRepeaterKeys => _forcedRepeaterKeys;

  /// The forced route as path bytes, or null when the toggle is off/empty.
  Uint8List? get forcedRoute {
    if (!_forceRepeaterRoute || _forcedRepeaterKeys.isEmpty) return null;
    return Uint8List.fromList([
      for (final k in _forcedRepeaterKeys)
        int.parse(k.substring(0, 2), radix: 16),
    ]);
  }

  /// Names for the forced route, for display ("Hilltop → Ridge").
  String forcedRouteLabel() => _forcedRepeaterKeys
      .map((k) {
        for (final c in _connector.contacts) {
          if (c.publicKeyHex == k) return c.name;
        }
        return k.substring(0, 2);
      })
      .join(' → ');

  Future<void> _loadTestSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _forceRepeaterRoute = prefs.getBool(_kForceRoute) ?? false;
      _forcedRepeaterKeys = prefs.getStringList(_kForceRouteKeys) ?? const [];
      _preferMimi = prefs.getBool(_kPreferMimi) ?? true;
      _enhanceVoice = prefs.getBool(_kEnhanceVoice) ?? true;
      _onEnhancerChanged();
      final c2 = VoxVoiceMode.fromWireId(
        prefs.getInt(_kCodec2Mode) ?? voxDefaultVoiceMode.wireId,
      );
      _codec2Mode = c2 != null && voxCodec2RecordModes.contains(c2)
          ? c2
          : voxDefaultVoiceMode;
      _photoAiSketch = prefs.getBool(_kPhotoAiSketch) ?? false;
      _photoAiSketchHd = prefs.getBool(_kPhotoAiSketchHd) ?? false;
      _codecs.load(
        codec2: prefs.getStringList(_kCodec2Targets),
        mimi: prefs.getStringList(_kMimiTargets),
        heardJson: prefs.getString(_kCodecHeard),
      );
      _autoPlay = prefs.getBool(_kAutoPlay) ?? true;
      _autoDownloadChannels = prefs.getBool(_kAutoChannels) ?? false;
      _pushChannelClips = prefs.getBool(_kPushChannel) ?? true;
      notifyListeners();
    } catch (_) {}
  }

  Future<void> setForceRepeaterRoute(bool enabled, List<String> keys) async {
    _forceRepeaterRoute = enabled;
    _forcedRepeaterKeys = List.unmodifiable(keys);
    _logEvent(
      enabled && keys.isNotEmpty
          ? 'testing: forcing voice via ${forcedRouteLabel()} (${_hex(forcedRoute!)})'
          : 'testing: forced repeater route off',
    );
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kForceRoute, enabled);
      await prefs.setStringList(_kForceRouteKeys, keys);
    } catch (_) {}
  }

  /// Chat contacts, for picking a link-test target.
  List<Contact> get chatContacts {
    final list = [
      for (final c in _connector.contacts)
        if (c.type == advTypeChat) c,
    ]..sort((a, b) => a.name.compareTo(b.name));
    return list;
  }

  /// Repeaters and room servers known to the radio, nearest first.
  List<Contact> get repeaterCandidates {
    final list = [
      for (final c in _connector.contacts)
        if (c.type == advTypeRepeater || c.type == advTypeRoom) c,
    ];
    int hops(Contact c) => c.pathLength < 0 ? 99 : c.pathLength;
    list.sort((a, b) {
      final h = hops(a).compareTo(hops(b));
      return h != 0 ? h : a.name.compareTo(b.name);
    });
    return list;
  }

  /// Longest clip VOX will record. 20 s at 1200 bps is 20 packets.
  static const Duration maxClipLength = Duration(seconds: 20);

  static const int _storeMagic = 0xC2;

  final MeshCoreConnector _connector;
  final VoxClipStore _store;
  late final StreamSubscription<Uint8List> _sub;

  /// Complete clips we can play or serve: sid -> (mode, codec2 bytes).
  final Map<String, Uint8List> _bits = {};
  final Map<String, VoxVoiceMode> _modes = {};
  final Set<String> _ownClips = {};

  final Map<String, _IncomingClip> _incoming = {};

  /// Packets for sessions we have not seen an envelope for yet.
  final Map<String, Map<int, Uint8List>> _orphans = {};
  final Set<String> _orphansRelayed = {};

  /// Last time any channel packet for a session was heard (serve dedupe).
  final Map<String, DateTime> _lastChannelPacket = {};
  final Map<String, DateTime> _recentServes = {};
  final Map<String, int> _serveGen = {};
  final Random _rng = Random();

  /// Companion protocol frame limit (MAX_FRAME_SIZE in the firmware).
  static const int _maxCompanionFrame = 172;

  Future<void> _serveChain = Future.value();

  final List<VoxLogEntry> _log = [];

  /// Bumps on every new log line (the diagnostics sheet listens to it).
  final ValueNotifier<int> logVersion = ValueNotifier(0);

  /// Recent voice events, oldest first.
  List<VoxLogEntry> get log => List.unmodifiable(_log);

  void _logEvent(String text, [String sid = '']) {
    _log.add(VoxLogEntry(DateTime.now(), sid, text));
    if (_log.length > 300) _log.removeRange(0, _log.length - 300);
    logVersion.value++;
    debugPrint('VOX ${_log.last}');
  }

  String _hex(List<int> b) => b.isEmpty
      ? '(0 hop)'
      : b.map((v) => v.toRadixString(16).padLeft(2, '0')).join(',');

  String radioSummary() {
    final sf = _connector.currentSf;
    final bw = _connector.currentBwHz;
    final cr = _connector.currentCr;
    final self = _connector.selfPublicKey;
    final m = _mediaAir;
    // Photos and voice may go out on radio2 with its own settings: then the
    // airtime is radio2's, not the main radio's shown first.
    return 'self=${self == null ? '?' : voxKey6Hex(self)} '
        'main radio SF${sf ?? '?'}/${bw == null ? '?' : bw / 1000}kHz/CR4/${cr ?? '?'}; '
        '${m == null ? 'photos and voice on the main radio' : 'photos and voice on radio2 SF${m.spreadingFactor}/${m.bandwidthKhz}kHz/CR4/${m.codingRate}'}, '
        'packetAir≈${_packetAir().inMilliseconds}ms';
  }

  bool get isAvailable => voxCodecAvailable;
  String? get unavailableReason => voxCodecUnavailableReason;

  // ------------------------------------------------- push-to-talk (walkie)

  /// Push-to-talk packets heard on a channel, for WalkieService.
  void Function(Uint8List payload, int channelIndex, int? via, int? hops)?
  liveTalkHandler;

  /// Talks played live: their voice messages don't auto-play again.
  final Set<String> _heardLive = {};

  void markHeardLive(String sid) {
    _heardLive.add(sid);
    if (_heardLive.length > 64) _heardLive.remove(_heardLive.first);
  }

  /// Session ids heard (or sent) as push-to-talk, for clips announced by
  /// versions without the talk caption.
  final Set<String> _talkSids = {};

  void _noteTalk(String sid) {
    if (!_talkSids.add(sid)) return;
    if (_talkSids.length > 200) _talkSids.remove(_talkSids.first);
  }

  /// [env] is a push-to-talk (shown with a waveform, not as a plain voice
  /// message).
  bool isTalk(VoxVoiceEnvelope env) =>
      env.isTalk || _talkSids.contains(env.sessionId);

  final Map<String, List<double>> _waves = {};

  /// While a clip is arriving: each packet's loudness in [_kPartialSlices]
  /// slices (null: not here yet), decoded once per packet.
  final Map<String, List<List<double>?>> _partialWaves = {};
  static const int _kPartialSlices = 8;

  /// The clip's loudness in [voxWaveBars] bars (0..1), filling in as its
  /// packets arrive (heard live or fetched): a bar not heard yet is -1. Null
  /// before any packet (or for Mimi, or without Codec2 on this platform).
  List<double>? waveformFor(VoxVoiceEnvelope env) {
    final sid = env.sessionId;
    final cached = _waves[sid];
    if (cached != null) return cached;
    final bits = _bits[sid];
    if (env.mode.isMimi || env.isImage) return null;
    if (bits == null) return _partialWaveform(env);
    _partialWaves.remove(sid);
    try {
      final dec = VoxCodec2Stream(env.mode);
      final Int16List pcm;
      try {
        pcm = dec.decode(bits);
      } finally {
        dec.dispose();
      }
      final wave = voxWaveform(pcm);
      _waves[sid] = wave;
      if (_waves.length > 100) _waves.remove(_waves.keys.first);
      return wave;
    } catch (_) {
      return null;
    }
  }

  List<double>? _partialWaveform(VoxVoiceEnvelope env) {
    final sid = env.sessionId;
    final clip = _incoming[sid];
    final total = env.totalPackets;
    if (clip == null || clip.packets.isEmpty || total <= 0) return null;
    if (!voxCodecAvailable) return null;
    final slices = _partialWaves.putIfAbsent(
      sid,
      () => List<List<double>?>.filled(total, null),
    );
    if (slices.length != total) return null;
    if (_partialWaves.length > 16) {
      _partialWaves.remove(_partialWaves.keys.first);
    }
    for (final e in clip.packets.entries) {
      final i = e.key;
      if (i < 0 || i >= total || slices[i] != null) continue;
      try {
        final dec = VoxCodec2Stream(env.mode);
        final Int16List pcm;
        try {
          pcm = dec.decode(e.value);
        } finally {
          dec.dispose();
        }
        slices[i] = voxSliceLevels(pcm, _kPartialSlices);
      } catch (_) {
        return null;
      }
    }
    return voxPartialWaveform(slices, _kPartialSlices);
  }

  /// One second of a talk heard live: it also fills in the talk's voice
  /// message (the same session id and packet numbers as its VE3 clip).
  void acceptLivePacket(
    String sid,
    int index,
    Uint8List codec, {
    int? via,
    int? hops,
  }) {
    if (codec.isEmpty || index >= voxMaxPackets) return;
    _noteTalk(sid);
    _logArrival(sid, via, hops); // in the voice log: this talk was heard live
    _lastChannelPacket[sid] = DateTime.now();
    _onPacket(
      VoxVoicePacket(sessionId: sid, index: index, codecData: codec),
      via: via,
      hops: hops,
    );
  }

  /// Pause between a talk's packets: [direct] goes radio to radio, otherwise
  /// it floods through repeaters (and must not talk over their relays).
  Duration walkieGap({required bool direct}) =>
      direct ? _zeroHopGap() : _packetGap(flood: true);

  /// Announces a finished talk on [channel] as an ordinary voice message
  /// (VE3 on the main mesh), with the session id its packets went out under,
  /// and keeps it to serve to anyone who missed it.
  Future<VoxVoiceEnvelope> announceTalk(
    Channel channel,
    String sid,
    Uint8List bits, {
    required int durationSeconds,
  }) async {
    final packets = voxPacketize(sid, bits, walkieMode);
    if (packets.isEmpty) throw StateError('Talk is empty');
    _remember(sid, walkieMode, bits, own: true);
    final env = VoxVoiceEnvelope(
      sessionId: sid,
      mode: walkieMode,
      totalPackets: packets.length,
      durationSeconds: durationSeconds,
      caption: walkieTalkCaption,
    );
    _noteTalk(sid);
    _logEvent(
      'talk: ${packets.length} packets sent live on channel ${channel.name}; '
      'announcing it as a voice message',
      sid,
    );
    await _connector.sendChannelMessage(channel, env.encode());
    notifyListeners();
    return env;
  }

  // ---------------------------------------------------------------- sending

  /// Encodes a 48 kHz recording with [sendModeFor] [target] (Mimi or
  /// Codec2).
  Future<VoxEncodedClip> encodeRecording(
    Int16List pcm48k, {
    String? target,
  }) async {
    final maxIn = maxClipLength.inMilliseconds * voxRecordSampleRate ~/ 1000;
    final clipped = pcm48k.length > maxIn
        ? Int16List.sublistView(pcm48k, 0, maxIn)
        : pcm48k;
    final seconds = max(1, (clipped.length / voxRecordSampleRate).ceil());
    final mode = sendModeFor(target);
    if (mode.isMimi) {
      final audio24 = await compute(_decimateJob, (clipped, 2));
      final bits = await mimi.encode(audio24);
      return VoxEncodedClip(mode, bits, seconds);
    }
    if (!voxCodecAvailable) {
      throw StateError(voxCodecUnavailableReason ?? 'Codec2 unavailable');
    }
    final pcm8 = await compute(_prepJob, clipped);
    final bits = await compute(_encodeJob, _EncodeJob(pcm8, mode));
    return VoxEncodedClip(mode, bits, seconds);
  }

  /// What the listener will hear, as a WAV file (as decoded, not enhanced:
  /// radios and apps without the enhancer play it like this).
  Future<Uint8List> previewWav(VoxEncodedClip clip) =>
      _decodeToWav(clip.mode, clip.bits, enhance: false);

  Future<Uint8List> _decodeToWav(
    VoxVoiceMode mode,
    Uint8List bits, {
    bool enhance = true,
  }) async {
    if (mode.isMimi) {
      final audio = await mimi.decode(bits);
      return voxPcm16ToWav(
        voxFloatToPcm16(audio),
        sampleRate: VoxMimiSpec.sampleRate,
      );
    }
    if (enhance && enhancesVoice) {
      return _wavFromRaw(await compute(_decodeRawJob, _DecodeJob(bits, mode)));
    }
    final pcm = await compute(_decodeJob, _DecodeJob(bits, mode));
    return voxPcm16ToWav(pcm, sampleRate: voxPlayRate);
  }

  /// Decoded 8 kHz Codec2 as a WAV to play: enhanced when that's on, else
  /// levelled and upsampled (voxPlayClip).
  Future<Uint8List> _wavFromRaw(Int16List raw) async {
    if (enhancesVoice) {
      try {
        final sw = Stopwatch()..start();
        final pcm = await enhancer.enhance(raw);
        _logEvent(
          'enhanced ${(raw.length / voxCodecRate).toStringAsFixed(1)} s '
          'in ${sw.elapsedMilliseconds}ms',
        );
        return voxPcm16ToWav(pcm, sampleRate: VoxVoiceEnhanceModel.outRate);
      } catch (e) {
        _logEvent('enhance failed, playing as decoded: $e');
      }
    }
    return voxPcm16ToWav(
      await compute(voxPlayClip, raw),
      sampleRate: voxPlayRate,
    );
  }

  // ------------------------------------------------- playing with gaps

  /// Clips played with gaps while incomplete: the rest arriving doesn't
  /// play them again on its own.
  final Set<String> _partialPlayed = {};

  /// Whether [env] can play now with silence for missing packets
  /// (voxCanPlayPartial: Codec2, most of it here).
  bool canPlayPartial(VoxVoiceEnvelope env) {
    if (_bits.containsKey(env.sessionId) || !voxCodecAvailable) return false;
    final clip = _incoming[env.sessionId];
    return clip != null &&
        voxCanPlayPartial(env.mode, clip.packets.length, env.totalPackets);
  }

  /// Plays [env] as far as it has come, silence where packets are missing.
  Future<void> playPartial(VoxVoiceEnvelope env) async {
    final clip = _incoming[env.sessionId];
    if (clip == null || !canPlayPartial(env)) return;
    _partialPlayed.add(env.sessionId);
    if (_partialPlayed.length > 64) _partialPlayed.remove(_partialPlayed.first);
    _logEvent(
      'playing with gaps: ${clip.packets.length}/${env.totalPackets} here, '
      'missing ${_indexList(clip.missing)}; still fetching the rest',
      env.sessionId,
    );
    await _playWith(env, () => _partialWav(clip));
  }

  Future<Uint8List?> _partialWav(_IncomingClip clip) async {
    final env = clip.envelope;
    final plan = voxGapPlan(Map.of(clip.packets), env.totalPackets, env.mode);
    final raw = await compute(
      _decodeGapsJob,
      _GapsJob(
        [for (final g in plan) g.bits],
        [for (final g in plan) g.silenceSamples],
        env.mode,
      ),
    );
    return _wavFromRaw(raw);
  }

  // ------------------------------------------------ AI voice enhancement

  /// Fills in the upper band of received Codec2 clips when they play.
  final VoxVoiceEnhancer enhancer = VoxVoiceEnhancer.instance;

  static const _kEnhanceVoice = 'vox_enhance_voice';
  bool _enhanceVoice = true;

  /// Whether Codec2 clips are enhanced when the model is downloaded.
  bool get enhanceVoice => _enhanceVoice;

  /// Whether Codec2 clips play enhanced right now.
  bool get enhancesVoice => _enhanceVoice && enhancer.isReady;

  bool _enhancedBefore = false;
  void _onEnhancerChanged() {
    // Decoded clips are cached as WAVs: drop them when what they'd sound like
    // changes, so the next play is decoded again.
    if (enhancesVoice != _enhancedBefore) {
      _enhancedBefore = enhancesVoice;
      _wavCache.clear();
    }
    notifyListeners();
  }

  Future<void> setEnhanceVoice(bool v) async {
    _enhanceVoice = v;
    _onEnhancerChanged();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kEnhanceVoice, v);
    } catch (_) {}
  }

  VoxVoiceEnvelope _register(VoxEncodedClip clip) {
    final sid = voxNewSessionId();
    final packets = voxPacketize(sid, clip.bits, clip.mode);
    if (packets.isEmpty) throw StateError('Recording is empty');
    _remember(sid, clip.mode, clip.bits, own: true);
    return VoxVoiceEnvelope(
      sessionId: sid,
      mode: clip.mode,
      totalPackets: packets.length,
      durationSeconds: clip.durationSeconds,
    );
  }

  /// Keeps [clip] ready to serve without announcing it in a chat (used for
  /// photos and voice notes attached to team pins). Returns its envelope.
  VoxVoiceEnvelope registerClip(VoxEncodedClip clip) {
    final env = _register(clip);
    _logEvent(
      'registered ${env.totalPackets}-packet ${clip.mode.label} attachment',
      env.sessionId,
    );
    notifyListeners();
    return env;
  }

  /// [VoxEncodedClip] for a photo, for [registerClip].
  VoxEncodedClip imageClip(VoxEncodedImage image) => _imageClip(image);

  /// The contact whose public key starts with [hexPrefix], if any.
  Contact? contactByKeyPrefix(String hexPrefix) {
    final p = hexPrefix.toLowerCase();
    for (final c in _connector.contacts) {
      if (c.publicKeyHex.toLowerCase().startsWith(p)) return c;
    }
    return null;
  }

  /// Sends [clip] to [contact], with [caption] in the same message (cut to
  /// what fits).
  Future<VoxVoiceEnvelope> sendClipToContact(
    Contact contact,
    VoxEncodedClip clip, {
    String caption = '',
  }) async {
    await _ensureMediaAllowed();
    final env = _register(clip).withCaption(
      voxFitCaption(caption, voxCaptionMaxBytes(maxContactMessageBytes())),
    );
    unawaited(_refreshMediaAir()); // ready before the first request
    _logEvent(
      'sent ${env.totalPackets}-packet ${clip.mode.label} '
      '${clip.mode.isImage ? '(${clip.bits.length}B)' : 'clip'} to ${contact.name} '
      '(route ${contact.pathLength < 0 ? 'flood' : '${contact.pathLength} hops'})',
      env.sessionId,
    );
    await _connector.sendMessage(contact, env.encode());
    notifyListeners();
    return env;
  }

  /// The longest text message [channel] carries in one packet: less on an
  /// OTP channel, which never splits a message.
  int maxChannelTextBytes(Channel channel) =>
      _connector.isChannelOtpEnabled(channel.index)
      ? OtpService.maxPlaintextBytesForChannel(_connector.selfName)
      : maxChannelMessageBytes(_connector.selfName);

  /// Sends [clip] on [channel], with [caption] in the same message (cut to
  /// what fits).
  Future<VoxVoiceEnvelope> sendClipToChannel(
    Channel channel,
    VoxEncodedClip clip, {
    String caption = '',
  }) async {
    await _ensureMediaAllowed();
    final env = _register(clip).withCaption(
      voxFitCaption(caption, voxCaptionMaxBytes(maxChannelTextBytes(channel))),
    );
    unawaited(_refreshMediaAir()); // ready before the first request
    _logEvent(
      'sent ${env.totalPackets}-packet ${clip.mode.label} clip to channel ${channel.name}',
      env.sessionId,
    );
    await _connector.sendChannelMessage(channel, env.encode());
    if (_pushChannelClips && _connector.supportsChannelData) {
      // After the announcement has had time to arrive: a T-Deck keeps only
      // packets for a clip it has heard announced.
      final sid = env.sessionId;
      final index = channel.index;
      final lead = voxPushLead(_mainAirtime(env.encode().length));
      _logEvent('pushing in ${lead.inMilliseconds}ms', sid);
      unawaited(
        Future<void>.delayed(lead).then((_) => _pushToChannel(sid, index)),
      );
    }
    notifyListeners();
    return env;
  }

  /// Airtime on the main mesh of a channel message with [textBytes] of
  /// text: MeshCore's header, channel hash and MAC, the encrypted timestamp,
  /// type and "name: " prefix (padded to the cipher block), and a flood path
  /// still empty. Null when the radio's settings aren't known.
  Duration? _mainAirtime(int textBytes) {
    final sf = _connector.currentSf;
    final bwHz = _connector.currentBwHz;
    if (sf == null || bwHz == null || bwHz <= 0) return null;
    final plain = 5 + 34 + textBytes; // timestamp, type, sender name prefix
    final cipher = ((plain + 15) ~/ 16) * 16;
    if (sf < 5 || sf > 12) return null;
    return loraTimeOnAir(
      payloadBytes: 2 + 1 + 2 + cipher,
      spreadingFactor: sf,
      bandwidthHz: bwHz,
      codingRate: (_connector.currentCr ?? 5).clamp(5, 8),
      // Time-sharing radios run a longer preamble on the main mesh too.
      preambleSymbols: 40,
    );
  }

  /// Clips pushed to the radios in range, and when, so their own "send me
  /// everything" requests (which cross the push on the air) are not served
  /// a second time.
  final Map<String, DateTime> _pushedAt = {};

  void _pushToChannel(String sid, int channel) {
    if (!_connector.isConnected || !_bits.containsKey(sid)) return;
    final total = voxPacketize(sid, _bits[sid]!, _modes[sid]!).length;
    final key = '$sid/ch$channel';
    final burst = _channelBursts.putIfAbsent(
      key,
      () => _ChannelBurst(sid, channel),
    );
    burst.pending.addAll(List<int>.generate(total, (i) => i));
    burst.addParity(total, image: _modes[sid]!.isImage);
    burst.pushing = true;
    _pushedAt[sid] = DateTime.now();
    _pushedAt.removeWhere(
      (_, t) => DateTime.now().difference(t) > const Duration(minutes: 10),
    );
    _logEvent('pushing $total packets zero-hop to the channel', sid);
    if (burst.running) return;
    burst.running = true;
    _serveChain = _serveChain
        .then((_) => _runChannelBurst(key, burst))
        .catchError((_) {});
  }

  /// A listener in range asking for the whole clip while it is being
  /// pushed, or just after: the push is bringing it. Its later request for
  /// whatever it missed names those packets, and is served.
  bool _coveredByPush(String sid, {required bool all, required int? hops}) {
    if (!all || hops != 0) return false;
    final at = _pushedAt[sid];
    if (at == null) return false;
    final pushing = _channelBursts.values.any(
      (b) => b.sid == sid && b.pushing && b.running,
    );
    // Just after it, a request may still be crossing it on the air. Later
    // than that, "everything" means the push never reached them: served.
    return pushing ||
        DateTime.now().difference(at) < const Duration(seconds: 3);
  }

  void _remember(
    String sid,
    VoxVoiceMode mode,
    Uint8List bits, {
    bool own = false,
  }) {
    _bits[sid] = bits;
    _modes[sid] = mode;
    if (own) _ownClips.add(sid);
    final stored = Uint8List(bits.length + 2)
      ..[0] = _storeMagic
      ..[1] = mode.wireId
      ..setRange(2, bits.length + 2, bits);
    unawaited(_store.save(sid, stored));
  }

  Future<bool> _loadFromStore(String sid) async {
    if (_bits.containsKey(sid)) return true;
    final raw = await _store.load(sid);
    if (raw == null || raw.isEmpty) return false;
    if (raw.length > 2 && raw[0] == _storeMagic) {
      final mode = VoxVoiceMode.fromWireId(raw[1]);
      if (mode == null) return false;
      _bits[sid] = Uint8List.sublistView(raw, 2);
      _modes[sid] = mode;
    } else {
      // Clips saved by the first VOX build had no header (always 1200).
      _bits[sid] = raw;
      _modes[sid] = VoxVoiceMode.mode1200;
    }
    return true;
  }

  // -------------------------------------------------------------- receiving

  VoxClipState stateFor(VoxVoiceEnvelope env) {
    final sid = env.sessionId;
    if (_bits.containsKey(sid)) {
      final r2 = ((_viaMask[sid] ?? 0) & 2) != 0;
      return VoxClipState(
        VoxClipStatus.complete,
        received: env.totalPackets,
        total: env.totalPackets,
        via: _ownClips.contains(sid)
            ? null
            : VoxReceivedVia.forReceived(_viaMask[sid]),
        viaRepeater: _ownClips.contains(sid) || !r2 ? null : _viaHop[sid],
      );
    }
    final clip = _incoming[sid];
    if (clip == null) {
      return VoxClipState(VoxClipStatus.remote, total: env.totalPackets);
    }
    return VoxClipState(
      clip.status,
      received: clip.packets.length,
      total: env.totalPackets,
      message: clip.message,
    );
  }

  /// Registers an envelope shown in a chat so packets that arrive for it
  /// (e.g. because someone else on the channel asked) are kept, and checks
  /// the disk cache so clips received earlier play after a restart.
  Future<bool> warmUp(
    VoxVoiceEnvelope env, {
    Contact? sender,
    int? channelIndex,
  }) async {
    final sid = env.sessionId;
    if (await _loadFromStore(sid)) {
      notifyListeners();
      return true;
    }
    final clip = _incoming.putIfAbsent(sid, () => _IncomingClip(env));
    clip.sender ??= sender;
    clip.channelIndex ??= channelIndex;
    final parityOrphan = _orphans.remove(voxFecParitySid(sid));
    _orphansRelayed.remove(voxFecParitySid(sid));
    if (parityOrphan != null) clip.parity.addAll(parityOrphan);
    final orphan = _orphans.remove(sid);
    if (_orphansRelayed.remove(sid)) clip.relayed = true;
    if (orphan != null) {
      for (final e in orphan.entries) {
        _acceptPacket(clip, e.key, e.value, notify: false);
      }
      notifyListeners();
    }
    return _bits.containsKey(sid);
  }

  Contact? contactByName(String name) {
    final n = _normalizeName(name);
    if (n.isEmpty) return null;
    for (final c in _connector.contacts) {
      if (c.type == advTypeChat && _normalizeName(c.name) == n) return c;
    }
    return null;
  }

  Contact? contactByKeyHex(String keyHex) {
    for (final c in _connector.contacts) {
      if (c.publicKeyHex == keyHex) return c;
    }
    return null;
  }

  Contact? _contactByKey6(String key6) {
    for (final c in _connector.contacts) {
      if (c.publicKeyHex.toLowerCase().startsWith(key6)) return c;
    }
    return null;
  }

  static String _normalizeName(String s) =>
      s.replaceAll(RegExp(r'[️‍]'), '').trim().toLowerCase();

  /// Starts (or retries) fetching the audio for [env].
  Future<void> requestClip(
    VoxVoiceEnvelope env, {
    Contact? sender,
    int? channelIndex,
  }) async {
    if (await warmUp(env, sender: sender, channelIndex: channelIndex)) return;
    final clip = _incoming[env.sessionId]!;
    if (clip.status == VoxClipStatus.requesting ||
        clip.status == VoxClipStatus.receiving) {
      return;
    }
    if (sender != null) clip.sender = sender;
    if (channelIndex != null) clip.channelIndex = channelIndex;
    clip.attempts = 0;
    clip.stalls = 0;
    clip.directFailures = 0;
    clip.triedChannel = false;
    clip.askReplyAlongPath = true;
    // A manual retry may follow a route change: the flooded DM step (which
    // refreshes both radios' routes) gets another turn.
    clip.sentDmRequest = false;
    await _attempt(clip);
  }

  _Method? _chooseMethod(_IncomingClip clip) {
    if (forcedRoute != null) return _Method.direct;
    final sender = clip.sender;
    final route = sender == null ? null : _directRoute(sender);
    // Its packets came 0 hops: whoever sent them is in range, and so may be
    // others holding it. One zero-hop request reaches them all, with no
    // route needed (there often is none: "route to X: none (flood)").
    if (clip.minHops == 0 && !clip.triedZeroHop && clip.packets.isNotEmpty) {
      return _Method.zeroHop;
    }
    final canChannel =
        clip.channelIndex != null && _connector.supportsChannelData;
    // Two requests in a row got nothing back: the direct path isn't working
    // right now, so try the channel (it floods, and anyone holding the clip
    // can answer) before going round the direct options again.
    if (canChannel && clip.stalls >= 2 && !clip.triedChannel) {
      return _Method.channel;
    }
    if (sender != null) {
      // 1. Known route: plain raw request (works when both radios have routes).
      if (route != null && clip.directFailures == 0) return _Method.direct;
      // 2. No answer, or no route: flooded VR3 DM. Its ACK + reciprocal path
      //    exchange gives BOTH radios a fresh direct route to each other.
      if (!clip.sentDmRequest) return _Method.dmRequest;
      // 3. Routes should now exist: raw request again.
      if (route != null && clip.directFailures < 3) return _Method.direct;
    }
    if (canChannel) return _Method.channel;
    if (sender != null && route != null) return _Method.direct;
    if (sender != null) return _Method.dmRequest;
    return null;
  }

  Future<void> _attempt(_IncomingClip clip) async {
    final self = _connector.selfPublicKey;
    if (self == null || !_connector.isConnected) {
      _fail(clip, 'Not connected to a radio');
      return;
    }
    final method = _chooseMethod(clip);
    if (method == null) {
      _logEvent(
        'no way to fetch: sender=${clip.sender?.name ?? 'unknown'} '
        'channel=${clip.channelIndex}',
        clip.envelope.sessionId,
      );
      _fail(
        clip,
        clip.sender == null
            ? 'Sender is not in your contacts, and this radio cannot use '
                  'channel data (update the companion firmware)'
            : 'No route to ${clip.sender!.name}',
      );
      return;
    }
    clip.attempts++;
    clip.lastMethod = method;
    clip.rxLast = null; // the next packet starts a new burst
    if (method == _Method.channel) clip.triedChannel = true;
    if (method == _Method.zeroHop) clip.triedZeroHop = true;
    final sc = clip.sender;
    if (sc != null) {
      final fresh = contactByKeyHex(sc.publicKeyHex) ?? sc;
      _logEvent(
        'route to ${fresh.name}: ${fresh.pathLength < 0 ? 'none (flood)' : '${fresh.pathLength} hops ${_hex(fresh.path)}'}'
        '${fresh.pathHashWidth != 1 ? ' (${fresh.pathHashWidth}-byte hashes)' : ''}',
        clip.envelope.sessionId,
      );
    }
    clip.packetsAtLastAttempt = clip.packets.length;
    final missingNow = clip.missing;
    clip.expectedLast = missingNow.isEmpty
        ? clip.envelope.totalPackets - 1
        : missingNow.last;
    // A retry before any packet came in lists the packets rather than asking
    // for "all", so it can be salted (an unsalted repeat is dropped as already
    // seen). It names the first voxSaltedFetchIndices; the next asks for the
    // rest.
    final listAll =
        clip.packets.isEmpty &&
        clip.attempts > 1 &&
        clip.envelope.totalPackets > 0;
    List<int>? want = clip.packets.isEmpty ? null : clip.missing;
    if (listAll) {
      want = List.generate(clip.envelope.totalPackets, (i) => i);
      clip.expectedLast =
          min(clip.envelope.totalPackets, voxSaltedFetchIndices) - 1;
    }
    final req = VoxVoiceFetchRequest(
      sessionId: clip.envelope.sessionId,
      requesterKey6: voxKey6Hex(self),
      missingIndices: want,
      saltOk: true,
    );
    clip.status = VoxClipStatus.requesting;
    clip.message = switch (method) {
      _Method.direct =>
        forcedRoute != null
            ? 'Requesting via ${forcedRouteLabel()} (forced)…'
            : 'Requesting from ${clip.sender?.name ?? 'sender'}…',
      _Method.dmRequest => 'Finding a route to ${clip.sender?.name}…',
      _Method.channel => 'Requesting on the channel…',
      _Method.zeroHop => 'Asking radios in range…',
    };
    notifyListeners();
    try {
      switch (method) {
        case _Method.direct:
          final forced = forcedRoute;
          final route = forced ?? _directRoute(clip.sender!)!;
          _logEvent(
            'attempt ${clip.attempts}: raw request to ${clip.sender?.name ?? 'sender'} '
            'via ${_hex(route)}${forced != null ? ' (FORCED)' : ''} (${req.missingIndices == null ? 'all' : '${req.missingIndices!.length} missing'})',
            clip.envelope.sessionId,
          );
          // Tell the sender how we reached it, so it answers the same way
          // back rather than over its own (possibly stale) route to us.
          final withPath = VoxVoiceFetchRequest(
            sessionId: req.sessionId,
            requesterKey6: req.requesterKey6,
            missingIndices: req.missingIndices,
            saltOk: true,
            requesterPath: clip.askReplyAlongPath ? route : null,
          );
          if (!clip.askReplyAlongPath) {
            _logEvent(
              'asking the sender to reply over its own route this time',
              clip.envelope.sessionId,
            );
          }
          await _connector.sendFrame(
            buildSendRawDataFrame(
              path: route,
              payload: withPath.encode(salt: clip.salts.next()),
            ),
            waitForGenericAck: true,
          );
        case _Method.dmRequest:
          clip.sentDmRequest = true;
          // Make the DM flood even if we have a (possibly one-way) route, so
          // the sender's radio learns a route back to us.
          if (clip.sender!.pathLength >= 0) {
            await _connector.clearContactPath(clip.sender!);
            _logEvent(
              'cleared route to ${clip.sender!.name} to force a flood',
              clip.envelope.sessionId,
            );
          }
          _logEvent(
            'attempt ${clip.attempts}: VR3 DM (flood) to ${clip.sender!.name}',
            clip.envelope.sessionId,
          );
          await _connector.sendFrame(
            buildSendTextMsgFrame(
              clip.sender!.publicKey,
              VoxVoiceTextRequest.encode(req),
            ),
            waitForGenericAck: true,
          );
        case _Method.zeroHop:
          _logEvent(
            'attempt ${clip.attempts}: zero-hop request to radios in range '
            '(packets came 0 hops) for ${_indexList(clip.missing)}',
            clip.envelope.sessionId,
          );
          final zr = VoxVoiceFetchRequest(
            sessionId: req.sessionId,
            requesterKey6: req.requesterKey6,
            missingIndices: req.missingIndices,
            saltOk: true,
            requesterPath: const [], // answer zero-hop
          );
          await _connector.sendFrame(
            buildSendRawDataFrame(
              path: Uint8List(0),
              payload: zr.encode(salt: clip.salts.next()),
            ),
            waitForGenericAck: true,
          );
        case _Method.channel:
          _logEvent(
            'attempt ${clip.attempts}: request on channel ${clip.channelIndex} '
            'for ${clip.packets.isEmpty ? 'all' : _indexList(clip.missing)}',
            clip.envelope.sessionId,
          );
          final ok = await _connector.sendChannelDataBlobs(
            [req.encode(salt: clip.salts.next())],
            channelIndex: clip.channelIndex!,
            dataType: voxChannelDataType,
            interChunkDelay: Duration.zero,
          );
          if (!ok) throw StateError('channel send failed');
      }
    } catch (e) {
      _logEvent(
        'attempt ${clip.attempts} send failed: $e',
        clip.envelope.sessionId,
      );
      if (method != _Method.channel && method != _Method.zeroHop) {
        clip.directFailures++;
      }
      if (clip.attempts < voxAttemptBudget(clip.envelope.totalPackets)) {
        await _attempt(clip);
      } else {
        _fail(clip, 'Could not send request: $e');
      }
      return;
    }
    _armWatchdog(clip);
  }

  /// Repeaters between us and the clip's sender.
  int _clipHops(_IncomingClip clip) =>
      forcedRoute?.length ?? max(clip.sender?.pathLength ?? 3, 0);

  Duration _waitFor(_IncomingClip clip) {
    final hops = _clipHops(clip) + 1;
    // One radio transmission of a full voice packet, plus each repeater's
    // retransmit delay and the firmware/BLE turnaround.
    final hopMs = _packetAir().inMilliseconds * 2 + 700;
    final perPacket = _burstGap(clip);
    // Trips before the first voice packet lands: request out + packet back.
    // A DM request also needs path return + reciprocal path first.
    final trips = switch (clip.lastMethod) {
      _Method.dmRequest => 5,
      _Method.channel => 3,
      _ => 2,
    };
    final wait = clip.lastMethod == _Method.zeroHop
        // In range: the answer is a packet away (holders wait up to 4.5 s).
        ? Duration(milliseconds: 2 * hopMs + 6000)
        : Duration(milliseconds: trips * hops * hopMs + 8000);
    // Once packets flow, the stream is live: silence for a few packet gaps
    // means its tail was lost, not that the request is still on its way.
    return clip.status == VoxClipStatus.receiving
        ? voxStallWait(perPacket)
        : wait;
  }

  void _armWatchdog(_IncomingClip clip) {
    clip.watchdog?.cancel();
    final wait = voxStallBackoff(_waitFor(clip), clip.stalls);
    clip.watchdog = Timer(wait, () => _onWatchdog(clip));
  }

  /// Packets are arriving for a clip nobody here asked for: a push, or a
  /// transfer for another listener. When they stop with some missing and
  /// at least half here, ask for the rest rather than leave it unfinished.
  void _armPassiveFinish(_IncomingClip clip) {
    clip.watchdog?.cancel();
    final gap = clip.relayed ? _packetGap(flood: true) : _zeroHopGap();
    // Everyone in range hears the same push stop: spread their requests.
    final jitter = Duration(milliseconds: _rng.nextInt(1500));
    clip.watchdog = Timer(voxStallWait(gap) + jitter, () {
      if (clip.isComplete || clip.status != VoxClipStatus.remote) return;
      if (!_connector.isConnected) return;
      if (!voxShouldFinishPassive(
        received: clip.packets.length,
        total: clip.envelope.totalPackets,
      )) {
        return;
      }
      _logEvent(
        'packets stopped at ${clip.packets.length}/'
        '${clip.envelope.totalPackets}: asking for the rest',
        clip.envelope.sessionId,
      );
      unawaited(requestClip(clip.envelope));
    });
  }

  Future<void> _onWatchdog(_IncomingClip clip) async {
    if (clip.isComplete) return;
    final progressed = clip.packets.length > clip.packetsAtLastAttempt;
    final total = clip.envelope.totalPackets;
    final stallBudget = voxStallBudget(clip.packets.length, total);
    _logEvent(
      'timeout after ${clip.lastMethod?.name}: '
      '${clip.packets.length}/${clip.envelope.totalPackets} packets'
      '${clip.isComplete ? '' : ', missing ${_indexList(clip.missing)}'}',
      clip.envelope.sessionId,
    );
    final sid = clip.envelope.sessionId;
    if (!progressed &&
        !_partialPlayed.contains(sid) &&
        (_tapSids.contains(sid) || (_autoSids.contains(sid) && _autoPlay)) &&
        !_micBusy &&
        _phase == VoxPlayback.idle &&
        canPlayPartial(clip.envelope) &&
        clip.packets.length >= (total * voxPartialAutoShare).ceil()) {
      // Waiting for the last packet or two can take minutes: play what's
      // here now, and the whole clip is a tap away once it's in.
      unawaited(playPartial(clip.envelope));
    }
    if (progressed) {
      clip.stalls = 0;
    } else {
      clip.stalls++;
      if (clip.lastMethod != _Method.channel &&
          clip.lastMethod != _Method.zeroHop) {
        clip.directFailures++;
      }
      if (clip.lastMethod == _Method.direct) {
        // Nothing came back: try the other return route next time.
        clip.askReplyAlongPath = !clip.askReplyAlongPath;
      }
      // Stuck for a while: let the channel (anyone holding it can answer)
      // and, once, a fresh flooded route have another go.
      if (clip.stalls < stallBudget && clip.stalls % 3 == 0) {
        clip.triedChannel = false;
        clip.triedZeroHop = false;
      }
      if (clip.stalls == 4) clip.sentDmRequest = false;
    }
    final channelLeft =
        clip.channelIndex != null &&
        _connector.supportsChannelData &&
        !clip.triedChannel;
    if ((clip.stalls < stallBudget || channelLeft) &&
        clip.attempts < voxAttemptBudget(total)) {
      await _attempt(clip);
      return;
    }
    _fail(
      clip,
      clip.packets.isEmpty
          ? '${clip.envelope.isImage ? 'Photo' : 'Voice'} unavailable right now. Tap to retry.'
          : 'Got ${clip.packets.length}/${clip.envelope.totalPackets}. '
                'Tap to retry.',
    );
  }

  void _fail(_IncomingClip clip, String message) {
    clip.watchdog?.cancel();
    clip.status = VoxClipStatus.unavailable;
    clip.message = message;
    notifyListeners();
  }

  /// Decoded audio as a WAV file, or null if the clip is not complete.
  /// Results are cached, and a decode already running is shared, so a clip
  /// pre-decoded on arrival plays at once.
  Future<Uint8List?> wavFor(VoxVoiceEnvelope env) {
    final sid = env.sessionId;
    final cached = _wavCache.remove(sid);
    if (cached != null) {
      _wavCache[sid] = cached; // most recently used last
      return Future.value(cached);
    }
    return _decoding[sid] ??= () async {
      try {
        await _loadFromStore(sid);
        final bits = _bits[sid];
        if (bits == null || !canPlay(env)) return null;
        final sw = Stopwatch()..start();
        final wav = await _decodeToWav(_modes[sid] ?? env.mode, bits);
        _logEvent('decoded in ${sw.elapsedMilliseconds}ms', sid);
        _wavCache[sid] = wav;
        while (_wavCache.length > _wavCacheSize) {
          _wavCache.remove(_wavCache.keys.first);
        }
        return wav;
      } catch (e) {
        _logEvent('decode failed: $e', sid);
        return null;
      } finally {
        _decoding.remove(sid);
      }
    }();
  }

  static const _wavCacheSize = 6;
  final Map<String, Uint8List> _wavCache = {};
  final Map<String, Future<Uint8List?>> _decoding = {};

  /// Whether this device can decode [env]'s codec right now.
  bool canPlay(VoxVoiceEnvelope env) => env.mode.isImage
      ? false
      : env.mode.isMimi
      ? mimi.isReady
      : voxCodecAvailable;

  // ----------------------------------------------------------------- images

  /// Whether this build can encode and show AV1 image messages.
  bool get imagesAvailable => VoxAv1.isAvailable;

  /// Decoded pictures, most recently used last.
  final Map<String, VoxRgbImage> _imageCache = {};
  final Map<String, Future<VoxRgbImage?>> _imageDecoding = {};

  /// The received (or sent) picture for [env], decoded off the UI thread.
  /// Null until the clip is complete, or if it can't be decoded.
  Future<VoxRgbImage?> imageFor(VoxVoiceEnvelope env) {
    final sid = env.sessionId;
    final cached = _imageCache.remove(sid);
    if (cached != null) {
      _imageCache[sid] = cached;
      return Future.value(cached);
    }
    return _imageDecoding[sid] ??= () async {
      try {
        await _loadFromStore(sid);
        final bits = _bits[sid];
        if (bits == null || !imagesAvailable) return null;
        final sw = Stopwatch()..start();
        final img = await compute(_decodeImageJob, bits);
        if (img == null) {
          _logEvent('image did not decode', sid);
          return null;
        }
        _logEvent('image decoded in ${sw.elapsedMilliseconds}ms', sid);
        _imageCache[sid] = img;
        while (_imageCache.length > 12) {
          _imageCache.remove(_imageCache.keys.first);
        }
        return img;
      } finally {
        _imageDecoding.remove(sid);
      }
    }();
  }

  /// Thumbnails decoded from photos' first two packets (most recent last).
  final Map<String, VoxRgbImage> _thumbCache = {};
  final Set<String> _thumbDecoding = {};
  final Set<String> _thumbFailed = {};

  /// The small thumbnail a photo carries in its first two packets, once they
  /// are here: shown while the rest downloads. Null until then (or for
  /// a photo from a version that sends none); decoding starts on the first
  /// call and [notifyListeners] says when it's ready.
  VoxRgbImage? thumbFor(VoxVoiceEnvelope env) {
    if (!env.isImage || !imagesAvailable) return null;
    final sid = env.sessionId;
    final cached = _thumbCache[sid];
    if (cached != null ||
        _thumbDecoding.contains(sid) ||
        _thumbFailed.contains(sid)) {
      return cached;
    }
    final first = _thumbPrefix(sid);
    if (first == null || voxImageThumbObus(first) == null) return null;
    _thumbDecoding.add(sid);
    unawaited(() async {
      try {
        final img = await compute(_decodeThumbJob, first);
        if (img == null) {
          _thumbFailed.add(sid);
          return;
        }
        _thumbCache[sid] = img;
        while (_thumbCache.length > 24) {
          _thumbCache.remove(_thumbCache.keys.first);
        }
        notifyListeners();
      } finally {
        _thumbDecoding.remove(sid);
      }
    }());
    return null;
  }

  /// The start of a photo's payload, as far as its packets have come in order
  /// (up to the [voxThumbPackets] the thumbnail is in): where thumbFor looks.
  Uint8List? _thumbPrefix(String sid) {
    final whole = _bits[sid];
    if (whole != null) return whole;
    final pk = _incoming[sid]?.packets ?? _orphans[sid];
    if (pk == null || pk[0] == null) return null;
    final b = BytesBuilder(copy: false);
    for (var i = 0; i < voxThumbPackets && pk[i] != null; i++) {
      b.add(pk[i]!);
    }
    return b.toBytes();
  }

  /// Encodes a picture for sending, off the UI thread.
  Future<VoxEncodedImage> encodeImage(
    VoxRgbImage ref,
    VoxImageDetail detail, {
    VoxFocusRegions focus = VoxFocusRegions.none,
    bool useFocus = true,
  }) => compute(_encodeImageJob, _ImageEncodeJob(ref, detail, focus, useFocus));

  Future<VoxVoiceEnvelope> sendImageToContact(
    Contact contact,
    VoxEncodedImage image, {
    String caption = '',
  }) => sendClipToContact(
    contact,
    _imageClip(image),
    caption: PhotoMosaicPrefs.tagged(caption),
  );

  Future<VoxVoiceEnvelope> sendImageToChannel(
    Channel channel,
    VoxEncodedImage image, {
    String caption = '',
  }) => sendClipToChannel(
    channel,
    _imageClip(image),
    caption: PhotoMosaicPrefs.tagged(caption),
  );

  VoxEncodedClip _imageClip(VoxEncodedImage image) => VoxEncodedClip(
    VoxVoiceMode.av1Image,
    image.payload,
    voxAspectCode(image.aspect),
  );

  // --------------------------------------------------------------- playback

  static const _kAutoPlay = 'vox_autoplay';
  static const _kAutoChannels = 'vox_autoplay_channels';
  static const _kPushChannel = 'vox_push_channel';
  bool _pushChannelClips = true;

  /// Send a channel photo or voice clip to the radios in range straight
  /// away, zero-hop, instead of waiting for each listener to ask: it is
  /// there when they open it, and the requests and their round trips are
  /// saved. Listeners further away still ask, and get it relayed.
  bool get pushChannelClips => _pushChannelClips;

  Future<void> setPushChannelClips(bool v) async {
    _pushChannelClips = v;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kPushChannel, v);
    } catch (_) {}
  }

  bool _autoPlay = true;
  bool _autoDownloadChannels = false;

  /// Download and play incoming voice DMs as soon as they arrive.
  bool get autoPlay => _autoPlay;

  /// With [autoPlay], also download channel clips on arrival. Off by
  /// default: every listener pulls its own copy, which adds airtime on a busy
  /// channel. Channel clips that arrive anyway (someone else's channel
  /// transfer) still auto-play.
  bool get autoDownloadChannels => _autoDownloadChannels;

  Future<void> setAutoPlay(bool v) async {
    _autoPlay = v;
    if (!v) {
      _autoSids.clear();
      _autoQueue.clear();
    }
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kAutoPlay, v);
    } catch (_) {}
  }

  Future<void> setAutoDownloadChannels(bool v) async {
    _autoDownloadChannels = v;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kAutoChannels, v);
    } catch (_) {}
  }

  AudioPlayer? _player;
  String? _playSid;
  VoxPlayback _phase = VoxPlayback.idle;
  int _playGen = 0;
  Duration _playLength = Duration.zero;

  /// Playback position as a 0..1 fraction of the clip playing now.
  final ValueNotifier<double> playbackFraction = ValueNotifier(0);

  /// Clips the user tapped before they were downloaded: play on arrival.
  final Set<String> _tapSids = {};

  /// Clips fetched (or watched) because of auto-play.
  final Set<String> _autoSids = {};
  final List<VoxVoiceEnvelope> _autoQueue = [];
  bool _micBusy = false;

  VoxPlayback playbackFor(VoxVoiceEnvelope env) =>
      env.sessionId == _playSid ? _phase : VoxPlayback.idle;

  /// Length of the clip playing now (zero when idle).
  Duration get playbackLength => _playLength;

  /// Set while the recorder is open so nothing auto-plays into the mic.
  set micBusy(bool busy) {
    if (busy == _micBusy) return;
    _micBusy = busy;
    if (busy) {
      unawaited(stopPlayback());
    } else {
      _playNextQueued();
    }
  }

  /// Plays [env] now, replacing whatever is playing.
  Future<void> play(VoxVoiceEnvelope env) => _playWith(env, () => wavFor(env));

  Future<void> _playWith(
    VoxVoiceEnvelope env,
    Future<Uint8List?> Function() load,
  ) async {
    final sid = env.sessionId;
    final gen = ++_playGen;
    await _player?.stop();
    _playSid = sid;
    _phase = VoxPlayback.preparing;
    playbackFraction.value = 0;
    notifyListeners();
    final sw = Stopwatch()..start();
    final wav = await load();
    if (gen != _playGen) return; // stopped or replaced while decoding
    if (wav == null) {
      _endPlayback();
      return;
    }
    _playLength = _wavDuration(wav);
    final player = _player ??= _createPlayer();
    _phase = VoxPlayback.playing;
    notifyListeners();
    _logEvent('playing (ready after ${sw.elapsedMilliseconds}ms)', sid);
    try {
      await player.play(BytesSource(wav));
    } catch (e) {
      _logEvent('playback failed: $e', sid);
      if (gen == _playGen) _endPlayback();
    }
  }

  Future<void> stopPlayback() async {
    if (_phase == VoxPlayback.idle) return;
    _playGen++;
    _autoQueue.clear();
    await _player?.stop();
    _endPlayback(playNext: false);
  }

  AudioPlayer _createPlayer() {
    final p = AudioPlayer();
    p.onPlayerComplete.listen((_) => _endPlayback());
    p.onPositionChanged.listen((pos) {
      final ms = _playLength.inMilliseconds;
      if (ms > 0 && _phase == VoxPlayback.playing) {
        playbackFraction.value = (pos.inMilliseconds / ms).clamp(0.0, 1.0);
      }
    });
    return p;
  }

  void _endPlayback({bool playNext = true}) {
    _phase = VoxPlayback.idle;
    _playSid = null;
    _playLength = Duration.zero;
    playbackFraction.value = 0;
    notifyListeners();
    if (playNext) _playNextQueued();
  }

  void _playNextQueued() {
    if (_micBusy || _phase != VoxPlayback.idle || _autoQueue.isEmpty) return;
    unawaited(play(_autoQueue.removeAt(0)));
  }

  static Duration _wavDuration(Uint8List wav) {
    if (wav.length <= 44) return Duration.zero;
    final bd = ByteData.sublistView(wav);
    final rate = bd.getUint32(24, Endian.little);
    if (rate == 0) return Duration.zero;
    return Duration(microseconds: (wav.length - 44) * 500000 ~/ rate);
  }

  /// Fetches [env] and plays it as soon as it is complete (a tap on a clip
  /// that hasn't been downloaded yet).
  Future<void> requestAndPlay(
    VoxVoiceEnvelope env, {
    Contact? sender,
    int? channelIndex,
  }) async {
    _tapSids.add(env.sessionId);
    _autoSids.remove(env.sessionId);
    await requestClip(env, sender: sender, channelIndex: channelIndex);
    if (_bits.containsKey(env.sessionId) && _tapSids.remove(env.sessionId)) {
      if (env.isImage) {
        unawaited(imageFor(env));
      } else {
        unawaited(play(env));
      }
    }
  }

  /// Called by the connector for every new incoming chat message.
  void _onIncomingText(
    String text, {
    String? senderKeyHex,
    String? senderName,
    int? channelIndex,
    DateTime? timestamp,
  }) {
    final env = VoxVoiceEnvelope.tryParse(text);
    if (env == null) return;
    _learnCodec(
      env,
      senderKeyHex: senderKeyHex,
      channelIndex: channelIndex,
      at: timestamp,
    );
    final sid = env.sessionId;
    // Don't auto-play a backlog synced from the radio after a reconnect.
    if (timestamp != null &&
        DateTime.now().difference(timestamp) > const Duration(minutes: 15)) {
      return;
    }
    if (_bits.containsKey(sid) || _ownClips.contains(sid)) return;
    final sender = senderKeyHex != null
        ? contactByKeyHex(senderKeyHex)
        : (senderName == null ? null : contactByName(senderName));
    if (!_autoPlay) {
      // Not downloaded by itself: a photo's thumbnail still comes, from its
      // first two packets alone.
      _probeThumb(env, sender: sender, channelIndex: channelIndex);
      return;
    }
    if (_heardLive.contains(sid)) {
      // A push-to-talk heard as it was spoken: kept, not played again.
      unawaited(warmUp(env, sender: sender, channelIndex: channelIndex));
      return;
    }
    _autoSids.add(sid);
    if (env.isImage) {
      if (!imagesAvailable) {
        _autoSids.remove(sid);
        return;
      }
    } else if (!canPlay(env)) {
      _logEvent('auto-play skipped: Mimi model not downloaded', sid);
      _autoSids.remove(sid);
      return;
    }
    if (channelIndex != null && !_autoDownloadChannels) {
      _logEvent('auto-play: watching channel clip (not auto-downloading)', sid);
      unawaited(warmUp(env, sender: sender, channelIndex: channelIndex));
      _probeThumb(env, sender: sender, channelIndex: channelIndex);
      return;
    }
    _logEvent('auto-play: downloading new clip', sid);
    unawaited(requestClip(env, sender: sender, channelIndex: channelIndex));
  }

  /// Photos whose thumbnail has been asked for on its own, so it's asked once.
  final Set<String> _thumbProbed = {};

  /// A photo that isn't being downloaded: ask for its first two packets
  /// alone, which carry the thumbnail (312 bytes), so the bubble shows the
  /// picture before anyone taps. Not when they came anyway: a channel's
  /// sender pushes its photos to the radios in range, and another listener's
  /// ask brings them to everyone on the channel, so each waits a little
  /// (spread out) first.
  void _probeThumb(VoxVoiceEnvelope env, {Contact? sender, int? channelIndex}) {
    if (!env.isImage || !imagesAvailable) return;
    final sid = env.sessionId;
    if (!_thumbProbed.add(sid)) return;
    if (_thumbProbed.length > 64) _thumbProbed.remove(_thumbProbed.first);
    final onChannel = channelIndex != null;
    final wait = Duration(
      milliseconds: onChannel
          ? voxThumbProbeChannelWaitMs + _rng.nextInt(voxThumbProbeSpreadMs)
          : voxThumbProbeDirectWaitMs + _rng.nextInt(1000),
    );
    Timer(
      wait,
      () => unawaited(
        _sendThumbProbe(env, sender: sender, channelIndex: channelIndex),
      ),
    );
  }

  /// Asks for the thumbnail's packets ([attempt] of [voxThumbProbeTries],
  /// only those not here yet); not here by the
  /// next check, asks again. After the last, the bubble just offers the
  /// download, as it does all along: a probe never holds up a tap.
  Future<void> _sendThumbProbe(
    VoxVoiceEnvelope env, {
    Contact? sender,
    int? channelIndex,
    int attempt = 1,
  }) async {
    final sid = env.sessionId;
    await warmUp(env, sender: sender, channelIndex: channelIndex);
    final clip = _incoming[sid];
    final self = _connector.selfPublicKey;
    if (clip == null ||
        clip.status != VoxClipStatus.remote ||
        (clip.packets.containsKey(0) &&
            voxImageThumbObus(_thumbPrefix(sid) ?? Uint8List(0)) != null) ||
        self == null ||
        !_connector.isConnected) {
      return;
    }
    if (attempt < voxThumbProbeTries) {
      Timer(
        Duration(
          milliseconds:
              voxThumbProbeRetryMs + _rng.nextInt(voxThumbProbeSpreadMs),
        ),
        () => unawaited(
          _sendThumbProbe(
            env,
            sender: sender,
            channelIndex: channelIndex,
            attempt: attempt + 1,
          ),
        ),
      );
    }
    final req = VoxVoiceFetchRequest(
      sessionId: sid,
      requesterKey6: voxKey6Hex(self),
      missingIndices: [
        for (var i = 0; i < voxThumbPackets; i++)
          if (!clip.packets.containsKey(i)) i,
      ],
      saltOk: true,
    );
    try {
      final ch = channelIndex;
      if (ch != null && _connector.supportsChannelData) {
        _logEvent(
          'thumbnail: asking the channel for its packets ($attempt)',
          sid,
        );
        await _connector.sendChannelDataBlobs(
          [req.encode(salt: clip.salts.next())],
          channelIndex: ch,
          dataType: voxChannelDataType,
          interChunkDelay: Duration.zero,
        );
        return;
      }
      final s = clip.sender;
      final route = s == null ? null : _directRoute(s);
      // A DM photo with no route: not worth a flooded request for a
      // thumbnail; it comes with the photo on a tap.
      if (s == null || route == null) return;
      _logEvent('thumbnail: asking ${s.name} for its packets ($attempt)', sid);
      final withPath = VoxVoiceFetchRequest(
        sessionId: sid,
        requesterKey6: req.requesterKey6,
        missingIndices: req.missingIndices,
        saltOk: true,
        requesterPath: route,
      );
      await _connector.sendFrame(
        buildSendRawDataFrame(
          path: route,
          payload: withPath.encode(salt: clip.salts.next()),
        ),
        waitForGenericAck: true,
      );
    } catch (e) {
      _logEvent('thumbnail request failed: $e', sid);
    }
  }

  void _onClipComplete(VoxVoiceEnvelope env) {
    final sid = env.sessionId;
    final clip = _incoming[sid];
    if (clip != null && clip.rebuilt > 0) {
      _logEvent(
        'complete, ${clip.rebuilt} of its packets rebuilt from parity',
        sid,
      );
    }
    if (!env.isImage && _partialPlayed.contains(sid)) {
      // Heard already with gaps: ready to play whole, not played again.
      _tapSids.remove(sid);
      _autoSids.remove(sid);
      _logEvent('complete now: tap to hear it without gaps', sid);
      if (canPlay(env)) unawaited(wavFor(env));
      return;
    }
    if (env.isImage) {
      _tapSids.remove(sid);
      _autoSids.remove(sid);
      unawaited(imageFor(env)); // decode now so it shows at once
      return;
    }
    if (_tapSids.remove(sid)) {
      _autoSids.remove(sid);
      unawaited(play(env));
    } else if (_autoSids.remove(sid) && _autoPlay && canPlay(env)) {
      _autoQueue.add(env);
      unawaited(wavFor(env)); // start decoding even if something is playing
      _playNextQueued();
    } else if (canPlay(env)) {
      unawaited(wavFor(env)); // pre-decode so a tap plays at once
    }
  }

  // ------------------------------------------------------------ inbound data

  void _onFrame(Uint8List frame) {
    if (frame.isEmpty) return;
    if (frame[0] == pushCodeRawData) {
      final push = RawDataPush.tryParse(frame);
      if (push != null) {
        final p = push.payload;
        final sid = p.length >= 5 ? voxSessionIdFromBytes(p, 1) : '';
        final what = p.isEmpty
            ? 'empty'
            : VoxVoicePacket.isVoicePacket(p)
            ? 'voice packet #${p.length > 5 ? p[5] : '?'}'
                  '${p[0] == voxVoicePacketSaltedMagic ? ' (salted)' : ''}'
            : p[0] == voxVoiceFetchMagic
            ? 'fetch request'
            : p[0] == _pingMagic
            ? 'PING'
            : p[0] == _pongMagic
            ? 'PONG'
            : 'other (0x${p[0].toRadixString(16)})';
        _logEvent(
          'raw rx $what, ${p.length}B, SNR ${push.snr} RSSI ${push.rssi}',
          sid,
        );
        _onPayload(push.payload, channelIndex: null, via: push.via);
      }
    } else if (frame[0] == respCodeChannelDataRecv) {
      final parsed = parseChannelDataFrame(frame);
      if (parsed != null && parsed.dataType == voxChannelDataType) {
        _onPayload(
          parsed.payload,
          channelIndex: parsed.channelIndex,
          via: parsed.via,
          hops: parsed.hopCount,
          lastHop: parsed.lastHop,
        );
      }
    }
  }

  void _onPayload(
    Uint8List payload, {
    required int? channelIndex,
    int? via,
    int? hops,
    Uint8List? lastHop,
  }) {
    if (payload.isEmpty) return;
    // An untagged frame: find out whether this radio has radio2, for the
    // "Received via" label (cached for minutes, so not asked per packet).
    if (via == null) unawaited(_refreshMediaAir());
    if (walkieIsLivePayload(payload)) {
      // Push-to-talk (walkie_service.dart): only ever sent on a channel.
      if (channelIndex != null) {
        _noteVia(voxSessionIdFromBytes(payload, 1), via);
        liveTalkHandler?.call(payload, channelIndex, via, hops);
      }
      return;
    }
    switch (payload[0]) {
      case voxVoicePacketMagic:
      case voxVoicePacketSaltedMagic:
        final pkt = VoxVoicePacket.tryParse(payload);
        if (pkt == null) return;
        if (channelIndex != null) {
          _lastChannelPacket[pkt.sessionId] = DateTime.now();
        }
        _logArrival(
          pkt.sessionId,
          via,
          channelIndex == null ? null : hops,
          lastHop,
        );
        _onPacket(
          pkt,
          via: via,
          hops: channelIndex == null ? null : hops,
          lastHop: lastHop,
        );
      case _pingMagic:
        _onPing(payload);
        return;
      case _pongMagic:
        _onPong(payload);
        return;
      case voxVoiceFetchMagic:
        final req = VoxVoiceFetchRequest.tryParse(payload);
        if (req == null) return;
        final self = _connector.selfPublicKey;
        if (self != null && req.requesterKey6 == voxKey6Hex(self)) {
          return; // our own request, heard back from a repeater
        }
        if (channelIndex != null) {
          _onChannelRequest(req, channelIndex, hops);
        } else {
          _queueServe(req, viaChannel: null);
        }
    }
  }

  bool _onControlText(String senderKeyHex, String text) {
    if (!VoxVoiceTextRequest.looksLikeRequest(text)) return false;
    final req = VoxVoiceTextRequest.tryParse(text);
    _logEvent(
      req == null
          ? 'VR3 DM from ${senderKeyHex.substring(0, 12)} could not be parsed'
          : 'VR3 DM request from ${req.requesterKey6}',
      req?.sessionId ?? '',
    );
    if (req != null) _queueServe(req, viaChannel: null, waitForRoute: true);
    return true; // never show VR3 control messages in the chat
  }

  void _onPacket(
    VoxVoicePacket pkt, {
    int? via,
    int? hops,
    Uint8List? lastHop,
  }) {
    final sid = pkt.sessionId;
    _noteHeard(sid, pkt.index, onChannel: hops != null);
    if (_bits.containsKey(sid)) return;
    // A parity packet (vox_fec.dart): its session id is its clip's, XORed.
    final dataSid = voxFecDataSid(sid);
    if (_bits.containsKey(dataSid)) return;
    final forClip = _incoming[dataSid];
    if (forClip != null) {
      _acceptParity(forClip, pkt.index, pkt.codecData);
      return;
    }
    _noteVia(sid, via, lastHop);
    // Raw data doesn't say how far it came: treat it as relayed.
    final relayed = hops == null || hops > 0;
    final clip = _incoming[sid];
    if (clip != null && hops != null && hops < clip.minHops) {
      clip.minHops = hops;
    }
    if (clip == null) {
      final o = _orphans.putIfAbsent(sid, () => {});
      o[pkt.index] = pkt.codecData;
      if (relayed) _orphansRelayed.add(sid);
      if (_orphans.length > 32) {
        _orphansRelayed.remove(_orphans.keys.first);
        _orphans.remove(_orphans.keys.first);
      }
      return;
    }
    if (relayed) clip.relayed = true;
    // During a repair, say where each missing packet came from.
    if (clip.attempts > 0 &&
        clip.packetsAtLastAttempt > 0 &&
        !clip.packets.containsKey(pkt.index) &&
        clip.envelope.totalPackets - clip.packetsAtLastAttempt <= 24) {
      _logEvent(
        'got #${pkt.index} ${hops == null
            ? 'by raw data'
            : hops == 0
            ? 'zero-hop on the channel'
            : '$hops hops on the channel'}'
        '${lastHop != null && lastHop.isNotEmpty && (hops ?? 0) > 0 ? ' via ${_hex(lastHop)}' : ''}',
        sid,
      );
    }
    _acceptPacket(clip, pkt.index, pkt.codecData);
  }

  void _acceptPacket(
    _IncomingClip clip,
    int index,
    Uint8List data, {
    bool notify = true,
  }) {
    if (clip.isComplete || index >= clip.envelope.totalPackets) return;
    final fresh = !clip.packets.containsKey(index);
    clip.packets[index] = data;
    if (fresh && clip.parity.isNotEmpty && !clip.isComplete) _rebuild(clip);
    if (fresh &&
        (clip.status == VoxClipStatus.requesting ||
            clip.status == VoxClipStatus.receiving)) {
      clip.noteArrival(DateTime.now());
    }
    final sid = clip.envelope.sessionId;
    if (clip.isComplete) {
      clip.watchdog?.cancel();
      clip.status = VoxClipStatus.complete;
      _remember(sid, clip.envelope.mode, clip.joined());
      if (_viaMask.containsKey(sid)) unawaited(_saveReceivedVia());
      _onClipComplete(clip.envelope);
    } else if (clip.status == VoxClipStatus.requesting ||
        clip.status == VoxClipStatus.receiving) {
      clip.status = VoxClipStatus.receiving;
      clip.message = null;
      if (index == clip.expectedLast) {
        // The sender has sent its last packet, so the gaps are final: ask
        // for them again right away instead of waiting out the timeout.
        clip.watchdog?.cancel();
        final wait = voxGapRequestDelay(
          relayed: clip.relayed,
          packetGap: _burstGap(clip),
          zeroHopGap: _zeroHopGap(),
        );
        _logEvent(
          'last packet in, ${clip.missing.length} missing; re-requesting in '
          '${wait.inMilliseconds}ms',
          sid,
        );
        clip.watchdog = Timer(wait, () => _onWatchdog(clip));
      } else {
        _armWatchdog(clip);
      }
    } else if (clip.status == VoxClipStatus.remote &&
        clip.channelIndex != null) {
      _armPassiveFinish(clip);
    }
    if (notify) notifyListeners();
  }

  /// Packets of [sid] heard from other nodes lately (index -> when), for not
  /// sending what someone else just sent (NACK suppression).
  final Map<String, Map<int, DateTime>> _heardIdx = {};

  /// Another node sent packet [index] of [sid]: note it, and if one of our
  /// channel bursts for that clip still has it to send, leave it out.
  void _noteHeard(String sid, int index, {required bool onChannel}) {
    final now = DateTime.now();
    (_heardIdx[sid] ??= {})[index] = now;
    if (_heardIdx.length > 48) _heardIdx.remove(_heardIdx.keys.first);
    if (!onChannel) return;
    for (final b in _channelBursts.values) {
      if (b.sid == sid && !b.pushing && b.pending.remove(index)) {
        b.suppressed++;
      }
    }
  }

  /// Indices of [sid] heard from another node since [t].
  Set<int> _heardSince(String sid, DateTime t) => {
    for (final e in (_heardIdx[sid] ?? const <int, DateTime>{}).entries)
      if (e.value.isAfter(t)) e.key,
  };

  /// What we can send of [sid]: the whole clip, or the packets of one
  /// arriving here (null: nothing).
  _Held? _heldPackets(String sid) {
    final bits = _bits[sid];
    final mode = _modes[sid];
    if (bits != null && mode != null) {
      final pk = voxPacketize(sid, bits, mode);
      return _Held(
        {for (final p in pk) p.index: p.codecData},
        pk.length,
        whole: true,
        image: mode.isImage,
      );
    }
    final clip = _incoming[sid];
    if (clip == null || clip.packets.isEmpty) return null;
    return _Held(
      Map.of(clip.packets),
      clip.envelope.totalPackets,
      whole: false,
      image: clip.envelope.isImage,
    );
  }

  /// The part of an incomplete clip [req] asks for that we hold, or null.
  _Held? _partialFor(VoxVoiceFetchRequest req) {
    final held = _heldPackets(req.sessionId);
    if (held == null || held.whole) return held;
    final want = req.missingIndices;
    if (want == null) return held;
    return want.any(held.packets.containsKey) ? held : null;
  }

  /// A parity packet for [clip]: kept, and any block it completes rebuilt.
  void _acceptParity(_IncomingClip clip, int info, Uint8List data) {
    if (clip.isComplete || clip.parity.containsKey(info)) return;
    clip.parity[info] = data;
    if (clip.packets.isEmpty) return;
    final before = clip.packets.length;
    _rebuild(clip);
    if (clip.packets.length == before) return;
    // Run the arrival bookkeeping (completion, watchdogs) once.
    final i = clip.packets.keys.last;
    final d = clip.packets.remove(i)!;
    _acceptPacket(clip, i, d);
  }

  /// Packets of [clip] that its parity can bring back, put in place.
  void _rebuild(_IncomingClip clip) {
    final got = voxFecRebuild(
      total: clip.envelope.totalPackets,
      present: clip.packets,
      parity: clip.parity,
    );
    if (got.isEmpty) return;
    clip.packets.addAll(got);
    clip.rebuilt += got.length;
    _logEvent(
      'rebuilt ${_indexList(got.keys)} from parity (no request needed)',
      clip.envelope.sessionId,
    );
  }

  /// Packet indices as a short list: "#3-5, #10".
  static String _indexList(Iterable<int> indices) {
    final v = indices.toSet().toList()..sort();
    if (v.isEmpty) return 'none';
    final parts = <String>[];
    var a = v.first, b = v.first;
    for (final i in v.skip(1)) {
      if (i == b + 1) {
        b = i;
        continue;
      }
      parts.add(a == b ? '#$a' : '#$a-$b');
      a = b = i;
    }
    parts.add(a == b ? '#$a' : '#$a-$b');
    return parts.length > 8
        ? '${parts.take(8).join(', ')} and ${parts.length - 8} more'
        : parts.join(', ');
  }

  // ---------------------------------------------------------------- serving

  void _onChannelRequest(
    VoxVoiceFetchRequest req,
    int channelIndex,
    int? hops,
  ) {
    final self = _connector.selfPublicKey;
    if (self != null && req.requesterKey6 == voxKey6Hex(self)) return;
    unawaited(() async {
      final whole = await _loadFromStore(req.sessionId);
      // Part of it is worth sending too: another listener often lacks
      // exactly the packets we got.
      if (!whole && _partialFor(req) == null) return;
      final own = _ownClips.contains(req.sessionId);
      // The original sender answers right away. Anyone else holding the clip
      // only steps in if nobody has started sending it a few seconds later;
      // a partial copy waits longer still, for a whole one.
      final delay = own
          ? const Duration(milliseconds: 300)
          : Duration(
              milliseconds: (whole ? 5000 : 8000) + Random().nextInt(3000),
            );
      final asked = DateTime.now();
      await Future<void>.delayed(delay);
      final heard = _lastChannelPacket[req.sessionId];
      if (!own && heard != null && heard.isAfter(asked)) return;
      _queueChannelBurst(req, channelIndex, hops);
    }());
  }

  // ------------------------------------------------- channel bursts
  //
  // One burst per clip per channel, whoever asks. Every listener's request
  // adds the packets it lacks to the burst's pending set; nothing restarts.
  // (It used to: each new listener's request replaced the burst in progress
  // and began again from packet 1, so with a few listeners a photo went out
  // over and over.) Packets go out in index order, each listener's missing
  // ones folded in as they arrive.
  //
  // When everyone who asked was heard directly (0 hops), the burst goes out
  // zero-hop: direct with an empty path, heard by every radio in range and
  // relayed by no repeater. With nothing to wait for but the packet itself,
  // the next one follows right after. A listener further away turns the rest
  // of the burst into floods, spaced for the repeaters' relays.

  final Map<String, _ChannelBurst> _channelBursts = {};

  void _queueChannelBurst(VoxVoiceFetchRequest req, int channel, int? hops) {
    if (_coveredByPush(
      req.sessionId,
      all: req.missingIndices == null,
      hops: hops,
    )) {
      _logEvent(
        '${req.requesterKey6} (in range) asks for all of it: being pushed',
        req.sessionId,
      );
      return;
    }
    final key = '${req.sessionId}/ch$channel';
    final sig =
        '$key/${req.requesterKey6}|${req.missingIndices?.join(',') ?? 'all'}';
    final now = DateTime.now();
    final last = _recentServes[sig];
    if (last != null && now.difference(last) < const Duration(seconds: 6)) {
      _logEvent('ignoring a repeated request', req.sessionId);
      return; // the same request heard twice (direct and via a repeater)
    }
    _recentServes[sig] = now;
    _recentServes.removeWhere(
      (_, t) => now.difference(t) > const Duration(minutes: 10),
    );
    final held = _heldPackets(req.sessionId);
    if (held == null) return;
    final total = held.total;
    final burst = _channelBursts.putIfAbsent(
      key,
      () => _ChannelBurst(req.sessionId, channel),
    );
    final wanted = req.missingIndices ?? List<int>.generate(total, (i) => i);
    final before = burst.pending.length;
    burst.pending.addAll(
      wanted.where((i) => i >= 0 && i < total && held.packets.containsKey(i)),
    );
    // Everything asked for: the parity goes too, so whatever it misses of
    // this pass mends itself.
    if (req.missingIndices == null && held.whole) {
      burst.addParity(total, image: held.image);
    }
    burst.saltOk = burst.saltOk && req.saltOk;
    burst.maxHops = max(burst.maxHops, hops ?? 3);
    _logEvent(
      '${req.requesterKey6} asks for ${req.missingIndices == null ? 'all' : _indexList(wanted)} '
      '(${hops ?? '?'} hops)${held.whole ? '' : ', we hold ${held.packets.length}/$total'}: '
      '${burst.pending.length - before} added, ${burst.pending.length} pending',
      req.sessionId,
    );
    if (burst.running) return;
    burst.running = true;
    _serveChain = _serveChain
        .then((_) => _runChannelBurst(key, burst))
        .catchError((_) {});
  }

  /// When a photo or voice packet from someone else was last heard on radio2
  /// (MediaMesh), for listening before talking there.
  DateTime? _r2HeardAt;

  /// Packets that waited for MediaMesh to go quiet (shown in the log).
  int _lbtWaits = 0;

  /// Listen before talk on MediaMesh (voxLbtHold): returns once radio2 has
  /// been quiet a packet's airtime and a random bit, or after 20 s of waiting.
  Future<void> _radio2Quiet(String sid) async {
    final start = DateTime.now();
    final quiet = voxLbtQuietMs(
      _packetAir().inMilliseconds,
      _rng.nextInt(1 << 30),
    );
    var noted = false;
    while (true) {
      final now = DateTime.now();
      final heard = _r2HeardAt;
      final since = heard == null ? null : now.difference(heard).inMilliseconds;
      if (!voxLbtHold(
        sinceHeardMs: since,
        quietMs: quiet,
        waitedMs: now.difference(start).inMilliseconds,
      )) {
        return;
      }
      if (!noted) {
        noted = true;
        _lbtWaits++;
        _logEvent(
          'MediaMesh busy: waiting for it to go quiet ($_lbtWaits so far)',
          sid,
        );
      }
      await Future<void>.delayed(Duration(milliseconds: quiet - since!));
    }
  }

  Future<void> _runChannelBurst(String key, _ChannelBurst burst) async {
    try {
      await _refreshMediaAir();
      if (!_mediaAllowed) {
        _logEvent('not sending: it would go out on the main mesh', burst.sid);
        return;
      }
      // Gather a moment first: several listeners' requests for the same
      // clip usually come within a few seconds of each other, and one burst
      // answers them all (each adds what it lacks). Meanwhile, packets heard
      // from another holder come off the list (_noteHeard). A push answers
      // no request and goes at once.
      if (!burst.pushing) {
        await Future<void>.delayed(
          Duration(milliseconds: 2000 + _rng.nextInt(1000)),
        );
      }
      final held = _heldPackets(burst.sid);
      if (held == null) return;
      List<Uint8List>? parity;
      // Listen before the burst, briefly: the request that started it may
      // still be relayed. Within the burst the gaps do this. A push answers
      // no request, and its lead after the announcement already went by.
      if (!burst.pushing) await _waitBriefQuiet();
      var sent = 0;
      var zeroHopSent = 0;
      var paritySent = 0;
      while (burst.pending.isNotEmpty && _connector.isConnected) {
        final index = burst.pending.first;
        burst.pending.remove(index);
        Uint8List payload;
        if (index >= _ChannelBurst.parityBase) {
          if (!held.whole) continue;
          parity ??= voxFecEncode(burst.sid, [
            for (var i = 0; i < held.total; i++) held.packets[i]!,
          ], image: held.image);
          final k = index - _ChannelBurst.parityBase;
          if (k >= parity.length) continue;
          payload = parity[k];
          paritySent++;
        } else {
          final data = held.packets[index];
          if (data == null) continue;
          payload = VoxVoicePacket(
            sessionId: burst.sid,
            index: index,
            codecData: data,
          ).encode(salt: burst.saltOk ? _rng.nextInt(256) : null);
        }
        final zeroHop = burst.maxHops == 0;
        await _radio2Quiet(burst.sid);
        try {
          await _connector.sendChannelDataPacket(
            channelIndex: burst.channel,
            dataType: voxChannelDataType,
            payload: payload,
            zeroHop: zeroHop,
          );
        } catch (e) {
          _logEvent('burst stopped at packet $index: $e', burst.sid);
          return;
        }
        sent++;
        if (zeroHop) zeroHopSent++;
        _lastChannelPacket[burst.sid] = DateTime.now();
        if (burst.pending.isNotEmpty) {
          await Future<void>.delayed(
            zeroHop ? _zeroHopGap() : _packetGap(flood: true),
          );
        }
      }
      _logEvent(
        'sent $sent packets on channel ${burst.channel}'
        '${paritySent > 0 ? ', $paritySent of them parity' : ''}'
        '${zeroHopSent > 0 ? ' ($zeroHopSent zero-hop)' : ''}'
        '${burst.suppressed > 0 ? '; ${burst.suppressed} left out, heard from another node' : ''}',
        burst.sid,
      );
    } finally {
      burst.running = false;
      if (burst.pushing) _pushedAt[burst.sid] = DateTime.now(); // its end
      if (_channelBursts[key] == burst) _channelBursts.remove(key);
    }
  }

  /// Up to 1.5 s for 300 ms without a packet heard (either radio).
  Future<void> _waitBriefQuiet() async {
    final until = DateTime.now().add(const Duration(milliseconds: 1500));
    while (DateTime.now().isBefore(until)) {
      if (DateTime.now().difference(_connector.lastRadioRxTime) >=
          const Duration(milliseconds: 300)) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  /// Between zero-hop packets nobody relays: the packet's own airtime, plus
  /// a little for the radio to turn round and the listeners to read it out.
  /// The gap to expect between [clip]'s packets: the model's, or the one
  /// they're actually coming at once a few are in (voxBurstGap).
  Duration _burstGap(_IncomingClip clip) => voxBurstGap(
    model: _packetGap(
      flood: clip.lastMethod == _Method.channel,
      hops: _clipHops(clip),
    ),
    seen: Duration(milliseconds: clip.rxGapMs),
    samples: clip.rxGaps,
    floor: _zeroHopGap(),
  );

  Duration _zeroHopGap() =>
      Duration(milliseconds: max(150, _packetAir().inMilliseconds + 60));

  void _queueServe(
    VoxVoiceFetchRequest req, {
    required int? viaChannel,
    bool waitForRoute = false,
  }) {
    final path = req.requesterPath;
    if (_coveredByPush(
      req.sessionId,
      all: req.missingIndices == null,
      hops: path?.length,
    )) {
      _logEvent(
        '${req.requesterKey6} (in range) asks for all of it: being pushed',
        req.sessionId,
      );
      return;
    }
    final key =
        '${req.sessionId}/${viaChannel == null ? req.requesterKey6 : 'ch$viaChannel'}';
    final sig = '$key|${req.missingIndices?.join(',') ?? 'all'}';
    final last = _recentServes[sig];
    final now = DateTime.now();
    if (last != null && now.difference(last) < const Duration(seconds: 6)) {
      _logEvent('ignoring duplicate request from $key', req.sessionId);
      return; // same request again (e.g. heard twice)
    }
    _recentServes[sig] = now;
    // A newer request for the same clip from the same listener replaces any
    // burst still in progress, so we never keep sending stale packets.
    final gen = (_serveGen[key] ?? 0) + 1;
    _serveGen[key] = gen;
    _recentServes.removeWhere(
      (_, t) => now.difference(t) > const Duration(minutes: 10),
    );
    _serveChain = _serveChain
        .then((_) => _serve(req, viaChannel, waitForRoute, key, gen))
        .catchError((_) {});
  }

  /// Longest raw-data path we accept from a request (keeps frames in size).
  static const int _maxRawPathBytes = 8;

  Future<void> _serve(
    VoxVoiceFetchRequest req,
    int? viaChannel,
    bool waitForRoute,
    String key,
    int gen,
  ) async {
    if (_serveGen[key] != gen) return; // superseded while queued
    await _refreshMediaAir();
    if (!_mediaAllowed) {
      _logEvent(
        'not answering: it would go out on the main mesh',
        req.sessionId,
      );
      return;
    }
    final whole = await _loadFromStore(req.sessionId);
    final held = whole ? _heldPackets(req.sessionId) : _partialFor(req);
    if (held == null) {
      _logEvent('asked for a clip we do not have', req.sessionId);
      return;
    }
    // A zero-hop request (an empty path) reached every radio in range: let
    // the sender go first, and anyone else wait a moment and leave out what
    // they hear someone else send meanwhile.
    final own = _ownClips.contains(req.sessionId);
    final asked = DateTime.now();
    if (!own && req.requesterPath != null && req.requesterPath!.isEmpty) {
      await Future<void>.delayed(
        Duration(milliseconds: (whole ? 1000 : 2500) + _rng.nextInt(2000)),
      );
    }
    final heard = _heardSince(req.sessionId, asked);
    final wanted = req.missingIndices?.toSet();
    final packets = [
      for (var i = 0; i < held.total; i++)
        if ((wanted == null || wanted.contains(i)) &&
            held.packets.containsKey(i) &&
            !heard.contains(i))
          VoxVoicePacket(
            sessionId: req.sessionId,
            index: i,
            codecData: held.packets[i]!,
          ),
    ];
    if (packets.isEmpty) {
      if (heard.isNotEmpty) {
        _logEvent('another node is answering: not sending', req.sessionId);
      }
      return;
    }
    if (!held.whole) {
      _logEvent(
        'we hold ${held.packets.length}/${held.total}: serving the '
        '${packets.length} asked for that we have',
        req.sessionId,
      );
    }
    // The whole clip asked for: its parity follows.
    final parity = wanted == null && held.whole
        ? voxFecEncode(req.sessionId, [
            for (var i = 0; i < held.total; i++) held.packets[i]!,
          ], image: held.image)
        : const <Uint8List>[];

    if (viaChannel != null) {
      _logEvent(
        'serving ${packets.length} packets on channel $viaChannel',
        req.sessionId,
      );
      await _connector.sendChannelDataBlobs(
        [
          for (final p in packets)
            p.encode(salt: req.saltOk ? _rng.nextInt(256) : null),
          ...parity,
        ],
        channelIndex: viaChannel,
        dataType: voxChannelDataType,
        interChunkDelay: _packetGap(flood: true),
      );
      _lastChannelPacket[req.sessionId] = DateTime.now();
      return;
    }

    // Direct: needs the requester as a contact with a usable route. After a
    // VR3 DM the route arrives a few seconds later via the path exchange.
    final deadline = DateTime.now().add(
      waitForRoute ? const Duration(seconds: 25) : const Duration(seconds: 3),
    );
    final forced = forcedRoute;
    final viaRequest = req.requesterPath;
    Uint8List? route = forced != null
        ? Uint8List.fromList(forced.reversed.toList())
        // The way the request just reached us, reversed: known to work now.
        : viaRequest != null && viaRequest.length <= _maxRawPathBytes
        ? Uint8List.fromList(viaRequest.reversed.toList())
        : null;
    if (forced == null && viaRequest != null) {
      _logEvent(
        'replying along the request\'s path (${viaRequest.isEmpty ? 'direct' : _hex(Uint8List.fromList(viaRequest))})',
        req.sessionId,
      );
    }
    while (route == null) {
      final requester = _contactByKey6(req.requesterKey6);
      route = requester == null ? null : _directRoute(requester);
      if (route != null || DateTime.now().isAfter(deadline)) break;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    if (route == null) {
      final requester = _contactByKey6(req.requesterKey6);
      _logEvent(
        requester == null
            ? 'cannot answer ${req.requesterKey6}: not in contacts'
            : requester.pathHashWidth != 1
            ? 'cannot answer ${requester.name}: ${requester.pathHashWidth}-byte path hashes are not supported for raw data'
            : 'cannot answer ${requester.name}: no direct route back '
                  '(waited ${waitForRoute ? 25 : 3}s)',
        req.sessionId,
      );
      return;
    }
    final gap = _packetGap(flood: false, hops: route.length);
    _logEvent(
      'serving ${packets.length} packets to ${req.requesterKey6} via ${_hex(route)}'
      ', ${gap.inMilliseconds}ms apart'
      '${forced != null ? ' (FORCED)' : ''}',
      req.sessionId,
    );
    for (var i = 0; i < packets.length; i++) {
      if (!_connector.isConnected) return;
      if (_serveGen[key] != gen) {
        _logEvent(
          'stopped after $i/${packets.length}: a newer request replaced this one',
          req.sessionId,
        );
        return;
      }
      if (i > 0) await Future<void>.delayed(gap);
      await _radio2Quiet(req.sessionId);
      try {
        // Salt each send so a resend is never dropped as a duplicate by a
        // radio that saw an earlier copy; skip it if the frame would not fit.
        final fits =
            2 + route.length + packets[i].encode().length + 1 <=
            _maxCompanionFrame;
        await _connector.sendFrame(
          buildSendRawDataFrame(
            path: route,
            payload: packets[i].encode(
              salt: req.saltOk && fits ? _rng.nextInt(256) : null,
            ),
          ),
          waitForGenericAck: true,
        );
      } catch (e) {
        _logEvent('serve stopped at packet $i: $e', req.sessionId);
        return;
      }
    }
    var paritySent = 0;
    for (final p in parity) {
      if (!_connector.isConnected || _serveGen[key] != gen) break;
      if (2 + route.length + p.length > _maxCompanionFrame) break;
      await Future<void>.delayed(gap);
      await _radio2Quiet(req.sessionId);
      try {
        await _connector.sendFrame(
          buildSendRawDataFrame(path: route, payload: p),
          waitForGenericAck: true,
        );
        paritySent++;
      } catch (_) {
        break;
      }
    }
    _logEvent(
      'served all ${packets.length} packets'
      '${paritySent > 0 ? ' and $paritySent parity' : ''}',
      req.sessionId,
    );
  }

  // ---------------------------------------------------------------- routing

  /// Path bytes for a direct send, or null if there is no usable direct path.
  /// Raw data cannot be flooded, and the firmware reads the path length as a
  /// byte count, so multi-byte path hashes are not supported yet.
  Uint8List? _directRoute(Contact c) {
    if (c.pathHashWidth != 1) return null;
    if (c.pathOverride != null) {
      if (c.pathOverride! < 0) return null;
      final bytes = c.pathOverrideBytes ?? Uint8List(0);
      return Uint8List.fromList(bytes.take(c.pathOverride!).toList());
    }
    if (c.pathLength < 0 || c.path.length < c.pathLength) return null;
    return Uint8List.fromList(c.path.sublist(0, c.pathLength));
  }

  // Where this radio sends photos and voice (MediaAirProfile): radio2's
  // profile when they go on radio2 alone. Asked once per connected radio and
  // again every few minutes; a radio that can't say is asked again only after
  // a reconnect or ten minutes.
  MediaAirProfile? _mediaAir;
  String? _mediaAirRadio;
  DateTime? _mediaAirAt;
  Future<void>? _mediaAirLoading;

  Future<void> _refreshMediaAir() {
    final radio = _connector.isConnected ? _connector.selfPublicKeyHex : null;
    final at = _mediaAirAt;
    final fresh =
        radio == _mediaAirRadio &&
        at != null &&
        DateTime.now().difference(at) <
            (_mediaAir != null
                ? const Duration(minutes: 3)
                : const Duration(minutes: 10));
    if (radio == null || fresh) {
      if (radio == null) {
        _mediaAir = null;
        VoxReceivedVia.connectedRadioHasRadio2 = false;
      }
      return Future.value();
    }
    return _mediaAirLoading ??= () async {
      MediaAirProfile? air;
      try {
        air = await loadMediaAirProfile((c) async {
          try {
            final reply = await _connector
                .runLocalCliCommand(c)
                .timeout(const Duration(seconds: 4));
            if (c == 'get radio2') {
              final r2 = reply == null ? null : Radio2Reply.tryParse(reply);
              final had = VoxReceivedVia.connectedRadioHasRadio2;
              VoxReceivedVia.connectedRadioHasRadio2 = r2 != null && !r2.off;
              if (had != VoxReceivedVia.connectedRadioHasRadio2) {
                notifyListeners();
              }
            }
            return reply;
          } catch (_) {
            return null;
          }
        });
      } catch (_) {
        air = null;
      }
      _mediaAir = air;
      _mediaAirRadio = radio;
      _mediaAirAt = DateTime.now();
      _mediaAirLoading = null;
      if (air != null) {
        _logEvent(
          'photos and voice go on radio2: pacing for SF${air.spreadingFactor}'
          '/${air.bandwidthKhz} kHz, ${_packetAir().inMilliseconds} ms a packet',
        );
      }
    }();
  }

  /// The radio2 profile changed (the MediaMesh settings were saved): ask again
  /// before the next transfer.
  void mediaRoutingChanged() => _mediaAirAt = null;

  /// Photos and voice go out only on MediaMesh (radio2) alone, unless the
  /// developer switch allows the main mesh (MediaLockdown).
  bool get _mediaAllowed =>
      MediaLockdown.devAllowMain.value || _mediaAir != null;

  /// Whether this radio can send photos and voice now (asks it if needed).
  Future<bool> canSendMedia() async {
    if (MediaLockdown.devAllowMain.value) return true;
    _mediaAirAt = null; // ask afresh: the user may just have set it up
    await _refreshMediaAir();
    return _mediaAir != null;
  }

  Future<void> _ensureMediaAllowed() async {
    if (!await canSendMedia()) throw const MediaBlockedException();
  }

  /// Airtime of [packets] full packets where photos and voice go out
  /// (radio2 when they go there alone, else the main radio); null when the
  /// radio's settings aren't known.
  Duration? mediaAirtime(int packets) {
    if (_mediaAir == null &&
        (_connector.currentSf == null || _connector.currentBwHz == null)) {
      return null;
    }
    return _packetAir() * packets;
  }

  /// Airtime of one full voice packet with the radio's current settings, or
  /// radio2's when photos and voice go out on radio2 alone.
  Duration _packetAir() {
    final m = _mediaAir;
    if (m != null && _connector.isConnected) {
      return voxEstimateAirtime(
        totalPackets: 1,
        codecBytesPerPacket: voxMaxCodecBytesPerPacket,
        spreadingFactor: m.spreadingFactor,
        bandwidthKhz: m.bandwidthKhz,
        codingRate: m.codingRate,
        preambleSymbols: m.preamble,
      );
    }
    final sf = _connector.currentSf;
    final bwHz = _connector.currentBwHz;
    if (sf == null || bwHz == null || bwHz <= 0) {
      return const Duration(milliseconds: 1200);
    }
    return voxEstimateAirtime(
      totalPackets: 1,
      codecBytesPerPacket: voxMaxCodecBytesPerPacket,
      spreadingFactor: sf,
      bandwidthKhz: bwHz / 1000,
      codingRate: _connector.currentCr ?? 5,
    );
  }

  /// Pause between voice packets so we do not talk over our own relays.
  ///
  /// A stock repeater waits a random 0..1.5 airtimes (direct.txdelay 0.3)
  /// before relaying, then spends a full airtime relaying. Within earshot of
  /// that repeater, our next packet must not start until the relay is done,
  /// or the two collide. The repeater may use a slower coding rate than us,
  /// hence the 1.15 margin. Only the first two relays are near enough to
  /// matter; further hops pipeline.
  Duration _packetGap({required bool flood, int hops = 0}) {
    final air = _packetAir().inMilliseconds;
    if (flood) return Duration(milliseconds: max(800, air * 4 + 150));
    if (hops <= 0) return Duration(milliseconds: max(400, air * 2 + 150));
    final relayAir = air * 1.15;
    final h = min(hops, 2);
    return Duration(milliseconds: (air + h * 2.5 * relayAir + 400).round());
  }

  // ------------------------------------------------------- link test (ping)
  //
  // VOX-only raw packets to test raw-data transport independently of voice:
  //   ping [0x70][nonce:4][requesterKey6:6][pathLen][path...]
  //   pong [0x50][nonce:4][responderKey6:6]
  // The ping carries the path it was sent on; the other side replies along
  // the reverse of that path, so no settings are needed on the receiver.

  static const int _pingMagic = 0x70; // 'p'
  static const int _pongMagic = 0x50; // 'P'
  final Map<int, (DateTime, String)> _pingsOut = {};
  final Map<int, DateTime> _pongsAnswered = {};

  /// Routes a link test will try towards [target], labelled for the log.
  List<(String, Uint8List)> linkTestRoutes(Contact target) {
    final routes = <(String, Uint8List)>[
      ('no repeaters (0 hop)', Uint8List(0)),
    ];
    final r = _directRoute(target);
    if (r != null && r.isNotEmpty) routes.add(('contact route', r));
    final f = forcedRoute;
    if (f != null) routes.add(('forced ${forcedRouteLabel()}', f));
    return routes;
  }

  /// Sends one ping per route to [target], a few seconds apart.
  Future<void> sendLinkTest(Contact target) async {
    final self = _connector.selfPublicKey;
    if (self == null || !_connector.isConnected) {
      _logEvent('link test: not connected');
      return;
    }
    _logEvent('link test to ${target.name} (${voxKey6Hex(target.publicKey)})');
    final rng = Random();
    for (final (label, path) in linkTestRoutes(target)) {
      final nonce = rng.nextInt(1 << 31);
      final b = BytesBuilder()
        ..addByte(_pingMagic)
        ..add([
          nonce >> 24 & 255,
          nonce >> 16 & 255,
          nonce >> 8 & 255,
          nonce & 255,
        ])
        ..add(self.sublist(0, 6))
        ..addByte(path.length)
        ..add(path);
      _pingsOut[nonce] = (DateTime.now(), label);
      try {
        await _connector.sendFrame(
          buildSendRawDataFrame(path: path, payload: b.toBytes()),
          waitForGenericAck: true,
        );
        _logEvent(
          'PING sent via $label ${_hex(path)} (#${nonce.toRadixString(16)})',
        );
      } catch (e) {
        _logEvent('PING via $label could not be sent: $e');
      }
      await Future<void>.delayed(const Duration(seconds: 4));
    }
    unawaited(
      Future<void>.delayed(const Duration(seconds: 30), () {
        final now = DateTime.now();
        _pingsOut.removeWhere((nonce, v) {
          final old = now.difference(v.$1) > const Duration(seconds: 25);
          if (old) {
            _logEvent('no PONG via ${v.$2} (#${nonce.toRadixString(16)})');
          }
          return old;
        });
      }),
    );
  }

  int _nonceAt(List<int> p, int o) =>
      (p[o] << 24) | (p[o + 1] << 16) | (p[o + 2] << 8) | p[o + 3];

  Future<void> _onPing(Uint8List p) async {
    if (p.length < 12) return;
    final nonce = _nonceAt(p, 1);
    final key6 = voxKey6Hex(p.sublist(5, 11));
    final self = _connector.selfPublicKey;
    if (self == null || key6 == voxKey6Hex(self)) return;
    final n = p[11];
    if (p.length < 12 + n) return;
    final back = Uint8List.fromList(p.sublist(12, 12 + n).reversed.toList());
    final last = _pongsAnswered[nonce];
    if (last != null && DateTime.now().difference(last).inSeconds < 10) return;
    _pongsAnswered[nonce] = DateTime.now();
    _logEvent(
      'PING from $key6 (sent via ${_hex(p.sublist(12, 12 + n))}); '
      'answering via ${_hex(back)}',
    );
    final b = BytesBuilder()
      ..addByte(_pongMagic)
      ..add(p.sublist(1, 5))
      ..add(self.sublist(0, 6));
    try {
      await _connector.sendFrame(
        buildSendRawDataFrame(path: back, payload: b.toBytes()),
        waitForGenericAck: true,
      );
    } catch (e) {
      _logEvent('PONG could not be sent: $e');
    }
  }

  void _onPong(Uint8List p) {
    if (p.length < 11) return;
    final nonce = _nonceAt(p, 1);
    final sent = _pingsOut.remove(nonce);
    if (sent == null) return;
    final ms = DateTime.now().difference(sent.$1).inMilliseconds;
    _logEvent(
      'PONG from ${voxKey6Hex(p.sublist(5, 11))} via ${sent.$2}: '
      'round trip ${ms}ms ✓',
    );
  }

  @override
  void dispose() {
    mimi.removeListener(notifyListeners);
    mimi.dispose();
    enhancer.removeListener(_onEnhancerChanged);
    _sub.cancel();
    if (_connector.voxControlTextInterceptor == _onControlText) {
      _connector.voxControlTextInterceptor = null;
    }
    if (_connector.voxIncomingTextObserver == _onIncomingText) {
      _connector.voxIncomingTextObserver = null;
    }
    for (final c in _incoming.values) {
      c.watchdog?.cancel();
    }
    _player?.dispose();
    playbackFraction.dispose();
    super.dispose();
  }
}

class _EncodeJob {
  final Int16List pcm;
  final VoxVoiceMode mode;
  _EncodeJob(this.pcm, this.mode);
}

class _DecodeJob {
  final Uint8List bits;
  final VoxVoiceMode mode;
  _DecodeJob(this.bits, this.mode);
}

Uint8List _encodeJob(_EncodeJob j) => voxEncodePcm(j.pcm, j.mode);
Float32List _decimateJob((Int16List, int) a) => voxDecimate(a.$1, a.$2);
Int16List _prepJob(Int16List pcm48k) =>
    voxPrepClip(voxDecimate(pcm48k, voxRecordSampleRate ~/ voxCodecRate));

/// Decoded and made ready to play (levelled, at [voxPlayRate]).
Int16List _decodeJob(_DecodeJob j) =>
    voxPlayClip(voxDecodeBits(j.bits, j.mode));

Int16List _decodeRawJob(_DecodeJob j) => voxDecodeBits(j.bits, j.mode);

class _GapsJob {
  final List<Uint8List?> bits;
  final List<int> silence;
  final VoxVoiceMode mode;
  _GapsJob(this.bits, this.silence, this.mode);
}

/// voxGapPlan's segments decoded and joined: 8 kHz PCM with silences.
Int16List _decodeGapsJob(_GapsJob j) {
  final parts = <Int16List>[
    for (var i = 0; i < j.bits.length; i++)
      j.bits[i] != null
          ? voxDecodeBits(j.bits[i]!, j.mode)
          : Int16List(j.silence[i]),
  ];
  final out = Int16List(parts.fold(0, (n, p) => n + p.length));
  var o = 0;
  for (final p in parts) {
    out.setRange(o, o + p.length, p);
    o += p.length;
  }
  return out;
}

class _ImageEncodeJob {
  final VoxRgbImage ref;
  final VoxImageDetail detail;
  final VoxFocusRegions focus;
  final bool useFocus;
  _ImageEncodeJob(this.ref, this.detail, this.focus, this.useFocus);
}

VoxEncodedImage _encodeImageJob(_ImageEncodeJob j) {
  final av1 = VoxAv1.instanceOrNull;
  if (av1 == null) {
    throw StateError(
      'Image support is not in this build (${VoxAv1.loadError})',
    );
  }
  return voxEncodeImage(
    ref: j.ref,
    detail: j.detail,
    focus: j.focus,
    useFocus: j.useFocus,
    encode: (img, q, speed) => av1.encode(img, q, speed: speed),
    decode: (obus) => av1.decode(obus),
  );
}

VoxRgbImage? _decodeThumbJob(Uint8List prefix) {
  final av1 = VoxAv1.instanceOrNull;
  if (av1 == null) return null;
  return voxDecodeImageThumb(prefix, (obus) => av1.decode(obus, maxSide: 256));
}

VoxRgbImage? _decodeImageJob(Uint8List payload) {
  final av1 = VoxAv1.instanceOrNull;
  if (av1 == null) return null;
  return voxDecodeImagePayload(payload, (obus) => av1.decode(obus));
}

/// A channel burst in progress (VoiceService._queueChannelBurst).
class _ChannelBurst {
  _ChannelBurst(this.sid, this.channel);
  final String sid;
  final int channel;
  final SplayTreeSet<int> pending = SplayTreeSet<int>();
  bool saltOk = true;
  int maxHops = 0;
  bool running = false;

  /// Started by the sender itself (VoiceService._pushToChannel).
  bool pushing = false;

  /// Packets taken off [pending] because another node sent them.
  int suppressed = 0;

  /// [pending] holds data packet indices, and parity packet k as
  /// parityBase + k (vox_fec.dart), sent after all the data.
  static const int parityBase = 1000;

  void addParity(int total, {required bool image}) {
    final n = voxFecTotalParity(total, image: image);
    for (var k = 0; k < n; k++) {
      pending.add(parityBase + k);
    }
  }
}

/// The packets of a clip this phone can send: all of them, or some of an
/// incomplete one (served to listeners missing exactly those).
class _Held {
  _Held(this.packets, this.total, {required this.whole, required this.image});
  final Map<int, Uint8List> packets;
  final int total;
  final bool whole;
  final bool image;
}
