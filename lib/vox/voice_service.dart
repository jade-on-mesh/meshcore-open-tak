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
import '../services/media_mesh.dart' show MediaAirProfile, loadMediaAirProfile;
import '../services/image_chunk_transport.dart'
    show parseChannelDataFrame, respCodeChannelDataRecv;
import 'voice_clip_store.dart';
import 'av1_ffi.dart';
import 'image_codec.dart';
import 'mimi.dart';
import 'resample.dart';
import 'voice_codec.dart';
import 'voice_codec_choice.dart';
import 'voice_wire.dart';
import 'wav.dart';

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

  /// What to show for something this radio received. Only Wadamesh with a
  /// second radio (MediaMesh) tags frames; any other radio has one radio, so
  /// whatever it received came over the main mesh.
  static VoxReceivedVia forReceived(int? mask) =>
      fromMask(mask) ?? VoxReceivedVia.mainMesh;
}

class VoxClipState {
  final VoxClipStatus status;
  final int received;
  final int total;
  final String? message;

  /// For a finished download: which radio profile it came over, when the
  /// radio said (Wadamesh with MediaMesh on).
  final VoxReceivedVia? via;

  const VoxClipState(
    this.status, {
    this.received = 0,
    this.total = 0,
    this.message,
    this.via,
  });

  double get progress => total == 0 ? 0 : received / total;
}

enum _Method { direct, dmRequest, channel }

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
  VoxClipStatus status = VoxClipStatus.remote;
  String? message;
  Contact? sender;
  int? channelIndex;
  int attempts = 0;
  int directFailures = 0;

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
  }

  // ------------------------------- which radio profile clips came over

  static const _kReceivedVia = 'vox_received_via';
  static const _maxReceivedVia = 400;

  /// sid -> bit mask of the profiles its packets arrived on (bit 0 main mesh,
  /// bit 1 radio2). Kept for finished clips so the label survives a restart.
  final Map<String, int> _viaMask = {};

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
      notifyListeners();
    } catch (_) {}
  }

  void _noteVia(String sid, int? via) {
    if (via == null) return;
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

  /// Send photos as an AI sketch (AEIC, ~150 B) instead of a VOX photo
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

  /// Hard cap on fetch attempts for one clip.
  static const int _maxAttempts = 15;

  /// Give up after this many consecutive attempts that brought no packets.
  static const int _maxStalls = 3;
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
    return 'self=${self == null ? '?' : voxKey6Hex(self)} '
        'SF=${sf ?? '?'} BW=${bw == null ? '?' : bw / 1000}kHz CR=4/${cr ?? '?'} '
        'packetAir≈${_packetAir().inMilliseconds}ms';
  }

  bool get isAvailable => voxCodecAvailable;
  String? get unavailableReason => voxCodecUnavailableReason;

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
    final audio8 = await compute(_decimateJob, (clipped, 6));
    final bits = await compute(
      _encodeJob,
      _EncodeJob(voxFloatToPcm16(audio8), mode),
    );
    return VoxEncodedClip(mode, bits, seconds);
  }

  /// What the listener will hear, as a WAV file.
  Future<Uint8List> previewWav(VoxEncodedClip clip) =>
      _decodeToWav(clip.mode, clip.bits);

  Future<Uint8List> _decodeToWav(VoxVoiceMode mode, Uint8List bits) async {
    if (mode.isMimi) {
      final audio = await mimi.decode(bits);
      return voxPcm16ToWav(
        voxFloatToPcm16(audio),
        sampleRate: VoxMimiSpec.sampleRate,
      );
    }
    final pcm = await compute(_decodeJob, _DecodeJob(bits, mode));
    return voxPcm16ToWav(pcm);
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

  Future<VoxVoiceEnvelope> sendClipToContact(
    Contact contact,
    VoxEncodedClip clip,
  ) async {
    final env = _register(clip);
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

  Future<VoxVoiceEnvelope> sendClipToChannel(
    Channel channel,
    VoxEncodedClip clip,
  ) async {
    final env = _register(clip);
    unawaited(_refreshMediaAir()); // ready before the first request
    _logEvent(
      'sent ${env.totalPackets}-packet ${clip.mode.label} clip to channel ${channel.name}',
      env.sessionId,
    );
    await _connector.sendChannelMessage(channel, env.encode());
    notifyListeners();
    return env;
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
      return VoxClipState(
        VoxClipStatus.complete,
        received: env.totalPackets,
        total: env.totalPackets,
        via: _ownClips.contains(sid)
            ? null
            : VoxReceivedVia.forReceived(_viaMask[sid]),
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
    final orphan = _orphans.remove(sid);
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
    await _attempt(clip);
  }

  _Method? _chooseMethod(_IncomingClip clip) {
    if (forcedRoute != null) return _Method.direct;
    final sender = clip.sender;
    final route = sender == null ? null : _directRoute(sender);
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
    if (method == _Method.channel) clip.triedChannel = true;
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
    final req = VoxVoiceFetchRequest(
      sessionId: clip.envelope.sessionId,
      requesterKey6: voxKey6Hex(self),
      missingIndices: clip.packets.isEmpty ? null : clip.missing,
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
            buildSendRawDataFrame(path: route, payload: withPath.encode()),
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
        case _Method.channel:
          _logEvent(
            'attempt ${clip.attempts}: request on channel ${clip.channelIndex}',
            clip.envelope.sessionId,
          );
          final ok = await _connector.sendChannelDataBlobs(
            [req.encode()],
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
      if (method != _Method.channel) clip.directFailures++;
      if (clip.attempts < _maxAttempts) {
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
    final perPacket = _packetGap(
      flood: clip.lastMethod == _Method.channel,
      hops: _clipHops(clip),
    );
    // Trips before the first voice packet lands: request out + packet back.
    // A DM request also needs path return + reciprocal path first.
    final trips = switch (clip.lastMethod) {
      _Method.dmRequest => 5,
      _Method.channel => 3,
      _ => 2,
    };
    final wait = Duration(milliseconds: trips * hops * hopMs + 8000);
    return clip.status == VoxClipStatus.receiving ? perPacket * 3 + wait : wait;
  }

  void _armWatchdog(_IncomingClip clip) {
    clip.watchdog?.cancel();
    final wait = _waitFor(clip);
    clip.watchdog = Timer(wait, () => _onWatchdog(clip));
  }

  Future<void> _onWatchdog(_IncomingClip clip) async {
    if (clip.isComplete) return;
    final progressed = clip.packets.length > clip.packetsAtLastAttempt;
    _logEvent(
      'timeout after ${clip.lastMethod?.name}: '
      '${clip.packets.length}/${clip.envelope.totalPackets} packets',
      clip.envelope.sessionId,
    );
    if (progressed) {
      clip.stalls = 0;
    } else {
      clip.stalls++;
      if (clip.lastMethod != _Method.channel) clip.directFailures++;
      if (clip.lastMethod == _Method.direct) {
        // Nothing came back: try the other return route next time.
        clip.askReplyAlongPath = !clip.askReplyAlongPath;
      }
    }
    final channelLeft =
        clip.channelIndex != null &&
        _connector.supportsChannelData &&
        !clip.triedChannel;
    if ((clip.stalls < _maxStalls || channelLeft) &&
        clip.attempts < _maxAttempts) {
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
        final img = await compute(_decodeImageJob, bits);
        if (img == null) {
          _logEvent('image did not decode', sid);
          return null;
        }
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

  /// Encodes a picture for sending, off the UI thread.
  Future<VoxEncodedImage> encodeImage(
    VoxRgbImage ref,
    VoxImageDetail detail, {
    VoxFocusRegions focus = VoxFocusRegions.none,
    bool useFocus = true,
  }) => compute(_encodeImageJob, _ImageEncodeJob(ref, detail, focus, useFocus));

  Future<VoxVoiceEnvelope> sendImageToContact(
    Contact contact,
    VoxEncodedImage image,
  ) => sendClipToContact(contact, _imageClip(image));

  Future<VoxVoiceEnvelope> sendImageToChannel(
    Channel channel,
    VoxEncodedImage image,
  ) => sendClipToChannel(channel, _imageClip(image));

  VoxEncodedClip _imageClip(VoxEncodedImage image) => VoxEncodedClip(
    VoxVoiceMode.av1Image,
    image.payload,
    voxAspectCode(image.aspect),
  );

  // --------------------------------------------------------------- playback

  static const _kAutoPlay = 'vox_autoplay';
  static const _kAutoChannels = 'vox_autoplay_channels';
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
  Future<void> play(VoxVoiceEnvelope env) async {
    final sid = env.sessionId;
    final gen = ++_playGen;
    await _player?.stop();
    _playSid = sid;
    _phase = VoxPlayback.preparing;
    playbackFraction.value = 0;
    notifyListeners();
    final sw = Stopwatch()..start();
    final wav = await wavFor(env);
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
    if (!_autoPlay) return;
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
      return;
    }
    _logEvent('auto-play: downloading new clip', sid);
    unawaited(requestClip(env, sender: sender, channelIndex: channelIndex));
  }

  void _onClipComplete(VoxVoiceEnvelope env) {
    final sid = env.sessionId;
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
        );
      }
    }
  }

  void _onPayload(
    Uint8List payload, {
    required int? channelIndex,
    int? via,
    int? hops,
  }) {
    if (payload.isEmpty) return;
    switch (payload[0]) {
      case voxVoicePacketMagic:
      case voxVoicePacketSaltedMagic:
        final pkt = VoxVoicePacket.tryParse(payload);
        if (pkt == null) return;
        if (channelIndex != null) {
          _lastChannelPacket[pkt.sessionId] = DateTime.now();
        }
        _onPacket(pkt, via: via);
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

  void _onPacket(VoxVoicePacket pkt, {int? via}) {
    final sid = pkt.sessionId;
    if (_bits.containsKey(sid)) return;
    _noteVia(sid, via);
    final clip = _incoming[sid];
    if (clip == null) {
      final o = _orphans.putIfAbsent(sid, () => {});
      o[pkt.index] = pkt.codecData;
      if (_orphans.length > 32) _orphans.remove(_orphans.keys.first);
      return;
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
    clip.packets[index] = data;
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
        final wait =
            _packetGap(
              flood: clip.lastMethod == _Method.channel,
              hops: _clipHops(clip),
            ) +
            const Duration(milliseconds: 1500);
        _logEvent(
          'last packet in, ${clip.missing.length} missing; re-requesting in '
          '${wait.inMilliseconds}ms',
          sid,
        );
        clip.watchdog = Timer(wait, () => _onWatchdog(clip));
      } else {
        _armWatchdog(clip);
      }
    }
    if (notify) notifyListeners();
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
      if (!await _loadFromStore(req.sessionId)) return;
      final own = _ownClips.contains(req.sessionId);
      // The original sender answers right away. Anyone else holding the clip
      // only steps in if nobody has started sending it a few seconds later.
      final delay = own
          ? const Duration(milliseconds: 300)
          : Duration(milliseconds: 5000 + Random().nextInt(3000));
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
    final key = '${req.sessionId}/ch$channel';
    final sig = '$key/${req.requesterKey6}|${req.missingIndices?.join(',') ?? 'all'}';
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
    final total = voxPacketize(
      req.sessionId,
      _bits[req.sessionId]!,
      _modes[req.sessionId]!,
    ).length;
    final burst = _channelBursts.putIfAbsent(
      key,
      () => _ChannelBurst(req.sessionId, channel),
    );
    final wanted = req.missingIndices ?? List<int>.generate(total, (i) => i);
    final before = burst.pending.length;
    burst.pending.addAll(wanted.where((i) => i >= 0 && i < total));
    burst.saltOk = burst.saltOk && req.saltOk;
    burst.maxHops = max(burst.maxHops, hops ?? 3);
    _logEvent(
      '${req.requesterKey6} asks for ${req.missingIndices == null ? 'all' : wanted.length} '
      'packets (${hops == null ? '?' : hops} hops): '
      '${burst.pending.length - before} added, ${burst.pending.length} pending',
      req.sessionId,
    );
    if (burst.running) return;
    burst.running = true;
    _serveChain = _serveChain
        .then((_) => _runChannelBurst(key, burst))
        .catchError((_) {});
  }

  Future<void> _runChannelBurst(String key, _ChannelBurst burst) async {
    try {
      await _refreshMediaAir();
      if (!await _loadFromStore(burst.sid)) return;
      final packets = voxPacketize(burst.sid, _bits[burst.sid]!, _modes[burst.sid]!);
      // Listen before the burst, briefly: the request that started it may
      // still be relayed. Within the burst the gaps do this.
      await _waitBriefQuiet();
      var sent = 0;
      var zeroHopSent = 0;
      while (burst.pending.isNotEmpty && _connector.isConnected) {
        final index = burst.pending.first;
        burst.pending.remove(index);
        if (index >= packets.length) continue;
        final zeroHop = burst.maxHops == 0;
        try {
          await _connector.sendChannelDataPacket(
            channelIndex: burst.channel,
            dataType: voxChannelDataType,
            payload: packets[index].encode(
              salt: burst.saltOk ? _rng.nextInt(256) : null,
            ),
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
        '${zeroHopSent > 0 ? ' ($zeroHopSent zero-hop)' : ''}',
        burst.sid,
      );
    } finally {
      burst.running = false;
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
  Duration _zeroHopGap() =>
      Duration(milliseconds: max(150, _packetAir().inMilliseconds + 60));

  void _queueServe(
    VoxVoiceFetchRequest req, {
    required int? viaChannel,
    bool waitForRoute = false,
  }) {
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
    if (!await _loadFromStore(req.sessionId)) {
      _logEvent('asked for a clip we do not have', req.sessionId);
      return;
    }
    final bits = _bits[req.sessionId]!;
    final mode = _modes[req.sessionId]!;
    final wanted = req.missingIndices?.toSet();
    final packets = [
      for (final p in voxPacketize(req.sessionId, bits, mode))
        if (wanted == null || wanted.contains(p.index)) p,
    ];
    if (packets.isEmpty) return;

    if (viaChannel != null) {
      _logEvent(
        'serving ${packets.length} packets on channel $viaChannel',
        req.sessionId,
      );
      await _connector.sendChannelDataBlobs(
        [
          for (final p in packets)
            p.encode(salt: req.saltOk ? _rng.nextInt(256) : null),
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
    _logEvent('served all ${packets.length} packets', req.sessionId);
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
      if (radio == null) _mediaAir = null;
      return Future.value();
    }
    return _mediaAirLoading ??= () async {
      MediaAirProfile? air;
      try {
        air = await loadMediaAirProfile((c) async {
          try {
            return await _connector
                .runLocalCliCommand(c)
                .timeout(const Duration(seconds: 4));
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
Int16List _decodeJob(_DecodeJob j) => voxDecodeBits(j.bits, j.mode);

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
}
