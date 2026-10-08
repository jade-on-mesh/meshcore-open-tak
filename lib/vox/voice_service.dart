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
    final sender = clip.sender;
    final route = sender == null ? null : _directRoute(sender);
    final canChannel =
        clip.channelIndex != null && _connector.supportsChannelData;
    if (sender != null && clip.directFailures < 2) {
      if (route != null) return _Method.direct;
      if (!clip.sentDmRequest) return _Method.dmRequest;
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
    clip.packetsAtLastAttempt = clip.packets.length;
    final req = VoxVoiceFetchRequest(
      sessionId: clip.envelope.sessionId,
      requesterKey6: voxKey6Hex(self),
      missingIndices: clip.packets.isEmpty ? null : clip.missing,
    );
    clip.status = VoxClipStatus.requesting;
    clip.message = switch (method) {
      _Method.direct => 'Requesting from ${clip.sender?.name ?? 'sender'}…',
      _Method.dmRequest => 'Finding a route to ${clip.sender?.name}…',
      _Method.channel => 'Requesting on the channel…',
    };
    notifyListeners();
    try {
      switch (method) {
        case _Method.direct:
          final route = _directRoute(clip.sender!)!;
          await _connector.sendFrame(
            buildSendRawDataFrame(path: route, payload: req.encode()),
            waitForGenericAck: true,
          );
        case _Method.dmRequest:
          clip.sentDmRequest = true;
          await _connector.sendFrame(
            buildSendTextMsgFrame(
              clip.sender!.publicKey,
              VoxVoiceTextRequest.encode(req),
            ),
            waitForGenericAck: true,
          );
        case _Method.channel:
          final ok = await _connector.sendChannelDataBlobs(
            [req.encode()],
            channelIndex: clip.channelIndex!,
            dataType: voxChannelDataType,
            interChunkDelay: Duration.zero,
          );
          if (!ok) throw StateError('channel send failed');
      }
    } catch (e) {
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
    final hops = max(clip.sender?.pathLength ?? 3, 0);
    final perPacket = _packetGap(flood: clip.lastMethod == _Method.channel);
    // First packet: request out + reply back. DM requests also need the
    // route exchange (path return + reciprocal path) before the reply.
    final base = switch (clip.lastMethod) {
      _Method.dmRequest => 20,
      _Method.channel => 12,
      _ => 8,
    };
    final wait = Duration(seconds: base + 2 * hops);
    return clip.status == VoxClipStatus.receiving ? perPacket * 3 + wait : wait;
  }

  void _armWatchdog(_IncomingClip clip) {
    clip.watchdog?.cancel();
    clip.watchdog = Timer(_waitFor(clip), () => _onWatchdog(clip));
  }

  Future<void> _onWatchdog(_IncomingClip clip) async {
    if (clip.isComplete) return;
    final progressed = clip.packets.length > clip.packetsAtLastAttempt;
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
      if (push != null) _onPayload(push.payload, channelIndex: null);
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
      case voxVoiceFetchMagic:
        final req = VoxVoiceFetchRequest.tryParse(payload);
        if (req == null) return;
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
      _armWatchdog(clip);
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
    if (!await _loadFromStore(req.sessionId)) return;
    final bits = _bits[req.sessionId]!;
    final mode = _modes[req.sessionId]!;
    final wanted = req.missingIndices?.toSet();
    final packets = [
      for (final p in voxPacketize(req.sessionId, bits, mode))
        if (wanted == null || wanted.contains(p.index)) p,
    ];
    if (packets.isEmpty) return;

    if (viaChannel != null) {
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
    Uint8List? route;
    while (true) {
      final requester = _contactByKey6(req.requesterKey6);
      route = requester == null ? null : _directRoute(requester);
      if (route != null || DateTime.now().isAfter(deadline)) break;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    if (route == null) return;
    for (var i = 0; i < packets.length; i++) {
      if (!_connector.isConnected) return;
      if (i > 0) await Future<void>.delayed(_packetGap(flood: false));
      try {
        await _connector.sendFrame(
          buildSendRawDataFrame(path: route, payload: packets[i].encode()),
          waitForGenericAck: true,
        );
      } catch (_) {
        return;
      }
    }
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

  /// Pause between voice packets so we do not talk over our own relays.
  Duration _packetGap({required bool flood}) {
    final sf = _connector.currentSf;
    final bwHz = _connector.currentBwHz;
    final cr = _connector.currentCr;
    if (sf == null || bwHz == null || bwHz <= 0) {
      return Duration(milliseconds: flood ? 2500 : 1500);
    }
    final air = voxEstimateAirtime(
      totalPackets: 1,
      codecBytesPerPacket: voxMaxCodecBytesPerPacket,
      spreadingFactor: sf,
      bandwidthKhz: bwHz / 1000,
      codingRate: cr ?? 5,
    );
    // Direct: one packet of airtime plus a relay hop. Flood: leave room for
    // several repeaters to rebroadcast before the next packet.
    final factor = flood ? 4 : 2;
    return Duration(
      milliseconds: max(flood ? 800 : 400, air.inMilliseconds * factor + 150),
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
