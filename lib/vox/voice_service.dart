// MeshCore Open VOX - on-demand voice messages over MeshCore.
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
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../connector/meshcore_connector.dart';
import '../connector/meshcore_protocol.dart';
import '../models/channel.dart';
import '../models/contact.dart';
import '../services/image_chunk_transport.dart'
    show parseChannelDataFrame, respCodeChannelDataRecv;
import 'voice_clip_store.dart';
import 'voice_codec.dart';
import 'voice_wire.dart';
import 'wav.dart';

enum VoxClipStatus { remote, requesting, receiving, complete, unavailable }

@immutable
class VoxClipState {
  final VoxClipStatus status;
  final int received;
  final int total;
  final String? message;

  const VoxClipState(
    this.status, {
    this.received = 0,
    this.total = 0,
    this.message,
  });

  double get progress => total == 0 ? 0 : received / total;
}

enum _Method { direct, dmRequest, channel }

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
  bool sentDmRequest = false;
  _Method? lastMethod;
  int packetsAtLastAttempt = 0;

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
    unawaited(_loadTestSettings());
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

  static const int _maxAttempts = 5;
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

  Future<VoxVoiceEnvelope> _prepare(Int16List pcm, VoxVoiceMode mode) async {
    if (!voxCodecAvailable) {
      throw StateError(voxCodecUnavailableReason ?? 'Codec2 unavailable');
    }
    final maxSamples = maxClipLength.inMilliseconds * 8;
    final clipped = pcm.length > maxSamples
        ? Int16List.sublistView(pcm, 0, maxSamples)
        : pcm;
    final bits = await compute(_encodeJob, _EncodeJob(clipped, mode));
    final sid = voxNewSessionId();
    final packets = voxPacketize(sid, bits, mode);
    if (packets.isEmpty) throw StateError('Recording is empty');
    _remember(sid, mode, bits, own: true);
    final durationS = (clipped.length / VoxVoiceMode.sampleRateHz).ceil();
    return VoxVoiceEnvelope(
      sessionId: sid,
      mode: mode,
      totalPackets: packets.length,
      durationSeconds: max(durationS, 1),
    );
  }

  Future<VoxVoiceEnvelope> sendToContact(
    Contact contact,
    Int16List pcm, {
    VoxVoiceMode mode = voxDefaultVoiceMode,
  }) async {
    final env = await _prepare(pcm, mode);
    _logEvent(
      'sent ${env.totalPackets}-packet clip to ${contact.name} '
      '(route ${contact.pathLength < 0 ? 'flood' : '${contact.pathLength} hops'})',
      env.sessionId,
    );
    await _connector.sendMessage(contact, env.encode());
    notifyListeners();
    return env;
  }

  Future<VoxVoiceEnvelope> sendToChannel(
    Channel channel,
    Int16List pcm, {
    VoxVoiceMode mode = voxDefaultVoiceMode,
  }) async {
    final env = await _prepare(pcm, mode);
    _logEvent(
      'sent ${env.totalPackets}-packet clip to channel ${channel.name}',
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
    clip.directFailures = 0;
    await _attempt(clip);
  }

  _Method? _chooseMethod(_IncomingClip clip) {
    if (forcedRoute != null) return _Method.direct;
    final sender = clip.sender;
    final route = sender == null ? null : _directRoute(sender);
    final canChannel =
        clip.channelIndex != null && _connector.supportsChannelData;
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
          await _connector.sendFrame(
            buildSendRawDataFrame(path: route, payload: req.encode()),
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

  Duration _waitFor(_IncomingClip clip) {
    final hops =
        (forcedRoute?.length ?? max(clip.sender?.pathLength ?? 3, 0)) + 1;
    // One radio transmission of a full voice packet, plus each repeater's
    // retransmit delay and the firmware/BLE turnaround.
    final hopMs = _packetAir().inMilliseconds * 2 + 700;
    final perPacket = _packetGap(flood: clip.lastMethod == _Method.channel);
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
    if (!progressed && clip.lastMethod != _Method.channel) {
      clip.directFailures++;
    }
    if (clip.attempts < _maxAttempts) {
      await _attempt(clip);
      return;
    }
    _fail(
      clip,
      clip.packets.isEmpty
          ? 'Voice unavailable right now. Tap to retry.'
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
  Future<Uint8List?> wavFor(VoxVoiceEnvelope env) async {
    await _loadFromStore(env.sessionId);
    final bits = _bits[env.sessionId];
    if (bits == null || !voxCodecAvailable) return null;
    final mode = _modes[env.sessionId] ?? env.mode;
    final pcm = await compute(_decodeJob, _DecodeJob(bits, mode));
    return voxPcm16ToWav(pcm);
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
            : p[0] == voxVoicePacketMagic
            ? 'voice packet #${p.length > 5 ? p[5] : '?'}'
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
        _onPayload(push.payload, channelIndex: null);
      }
    } else if (frame[0] == respCodeChannelDataRecv) {
      final parsed = parseChannelDataFrame(frame);
      if (parsed != null && parsed.dataType == voxChannelDataType) {
        _onPayload(parsed.payload, channelIndex: parsed.channelIndex);
      }
    }
  }

  void _onPayload(Uint8List payload, {required int? channelIndex}) {
    if (payload.isEmpty) return;
    switch (payload[0]) {
      case voxVoicePacketMagic:
        final pkt = VoxVoicePacket.tryParse(payload);
        if (pkt == null) return;
        if (channelIndex != null) {
          _lastChannelPacket[pkt.sessionId] = DateTime.now();
        }
        _onPacket(pkt);
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
          _onChannelRequest(req, channelIndex);
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

  void _onPacket(VoxVoicePacket pkt) {
    final sid = pkt.sessionId;
    if (_bits.containsKey(sid)) return;
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
    } else if (clip.status == VoxClipStatus.requesting ||
        clip.status == VoxClipStatus.receiving) {
      clip.status = VoxClipStatus.receiving;
      clip.message = null;
      if (index == clip.expectedLast) {
        // The sender has sent its last packet, so the gaps are final: ask
        // for them again right away instead of waiting out the timeout.
        clip.watchdog?.cancel();
        final wait =
            _packetGap(flood: clip.lastMethod == _Method.channel) +
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

  void _onChannelRequest(VoxVoiceFetchRequest req, int channelIndex) {
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
      _queueServe(req, viaChannel: channelIndex);
    }());
  }

  void _queueServe(
    VoxVoiceFetchRequest req, {
    required int? viaChannel,
    bool waitForRoute = false,
  }) {
    final key =
        '${req.sessionId}/${viaChannel == null ? req.requesterKey6 : 'ch$viaChannel'}';
    final last = _recentServes[key];
    final now = DateTime.now();
    if (last != null && now.difference(last) < const Duration(seconds: 6)) {
      _logEvent('ignoring duplicate request from $key', req.sessionId);
      return; // duplicate while we are already answering it
    }
    _recentServes[key] = now;
    _recentServes.removeWhere(
      (_, t) => now.difference(t) > const Duration(minutes: 10),
    );
    _serveChain = _serveChain
        .then((_) => _serve(req, viaChannel, waitForRoute))
        .catchError((_) {});
  }

  Future<void> _serve(
    VoxVoiceFetchRequest req,
    int? viaChannel,
    bool waitForRoute,
  ) async {
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
        [for (final p in packets) p.encode()],
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
    Uint8List? route = forced == null
        ? null
        : Uint8List.fromList(forced.reversed.toList());
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
    _logEvent(
      'serving ${packets.length} packets to ${req.requesterKey6} via ${_hex(route)}'
      '${forced != null ? ' (FORCED)' : ''}',
      req.sessionId,
    );
    for (var i = 0; i < packets.length; i++) {
      if (!_connector.isConnected) return;
      if (i > 0) await Future<void>.delayed(_packetGap(flood: false));
      try {
        await _connector.sendFrame(
          buildSendRawDataFrame(path: route, payload: packets[i].encode()),
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

  /// Airtime of one full voice packet with the radio's current settings.
  Duration _packetAir() {
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
  Duration _packetGap({required bool flood}) {
    final air = _packetAir();
    // Direct: one packet of airtime plus a relay hop. Flood: leave room for
    // several repeaters to rebroadcast before the next packet.
    final factor = flood ? 4 : 2;
    return Duration(
      milliseconds: max(flood ? 800 : 400, air.inMilliseconds * factor + 150),
    );
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
    final routes = <(String, Uint8List)>[('no repeaters (0 hop)', Uint8List(0))];
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
        ..add([nonce >> 24 & 255, nonce >> 16 & 255, nonce >> 8 & 255, nonce & 255])
        ..add(self.sublist(0, 6))
        ..addByte(path.length)
        ..add(path);
      _pingsOut[nonce] = (DateTime.now(), label);
      try {
        await _connector.sendFrame(
          buildSendRawDataFrame(path: path, payload: b.toBytes()),
          waitForGenericAck: true,
        );
        _logEvent('PING sent via $label ${_hex(path)} (#${nonce.toRadixString(16)})');
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
          if (old) _logEvent('no PONG via ${v.$2} (#${nonce.toRadixString(16)})');
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
    _sub.cancel();
    if (_connector.voxControlTextInterceptor == _onControlText) {
      _connector.voxControlTextInterceptor = null;
    }
    for (final c in _incoming.values) {
      c.watchdog?.cancel();
    }
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
Int16List _decodeJob(_DecodeJob j) => voxDecodeBits(j.bits, j.mode);
