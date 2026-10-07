// MeshCore Open VOX - on-demand voice messages over MeshCore.
//
// Send: record -> Codec2 -> packets cached locally -> VE3 text envelope only.
// Receive: VE3 shows up as a voice bubble; pressing play sends a binary fetch
// request to the sender over its direct path, the sender streams the packets
// back as raw data, and the bubble plays when the clip is complete.

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../connector/meshcore_connector.dart';
import '../connector/meshcore_protocol.dart';
import '../models/channel.dart';
import '../models/contact.dart';
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

  const VoxClipState(this.status, {this.received = 0, this.total = 0, this.message});

  double get progress => total == 0 ? 0 : received / total;
}

class _OutgoingClip {
  final List<VoxVoicePacket> packets;
  final DateTime createdAt;
  _OutgoingClip(this.packets) : createdAt = DateTime.now();
}

class _IncomingClip {
  final VoxVoiceEnvelope envelope;
  final Map<int, Uint8List> packets = {};
  VoxClipStatus status = VoxClipStatus.remote;
  String? message;
  int retriesLeft = 2;
  Timer? watchdog;
  Contact? sender;

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
  }

  /// Longest clip VOX will record. 20 s at 1200 bps is 20 packets.
  static const Duration maxClipLength = Duration(seconds: 20);

  /// Outgoing clips stay servable for this long after sending.
  static const Duration outgoingTtl = Duration(minutes: 15);

  final MeshCoreConnector _connector;
  final VoxClipStore _store;
  late final StreamSubscription<Uint8List> _sub;

  final Map<String, _OutgoingClip> _outgoing = {};
  final Map<String, _IncomingClip> _incoming = {};
  final Map<String, Uint8List> _completeBits = {}; // sid -> codec2 bytes
  final Map<String, DateTime> _recentServes = {}; // "$sid/$key6" -> time

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
    _outgoing[sid] = _OutgoingClip(packets);
    _completeBits[sid] = bits;
    unawaited(_store.save(sid, bits));
    _pruneOutgoing();
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

  void _pruneOutgoing() {
    final now = DateTime.now();
    _outgoing.removeWhere((_, c) => now.difference(c.createdAt) > outgoingTtl);
    _recentServes.removeWhere(
      (_, t) => now.difference(t) > const Duration(minutes: 10),
    );
  }

  // -------------------------------------------------------------- receiving

  VoxClipState stateFor(VoxVoiceEnvelope env) {
    final sid = env.sessionId;
    if (_completeBits.containsKey(sid)) {
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

  /// Checks the disk cache, so clips received earlier play after a restart.
  Future<bool> warmUp(VoxVoiceEnvelope env) async {
    if (_completeBits.containsKey(env.sessionId)) return true;
    final bits = await _store.load(env.sessionId);
    if (bits == null) return false;
    _completeBits[env.sessionId] = bits;
    notifyListeners();
    return true;
  }

  /// Finds a chat contact by display name (channel messages carry only that).
  Contact? contactByName(String name) {
    final n = name.trim();
    if (n.isEmpty) return null;
    for (final c in _connector.contacts) {
      if (c.type == advTypeChat && c.name.trim() == n) return c;
    }
    return null;
  }

  Contact? contactByKeyHex(String keyHex) {
    for (final c in _connector.contacts) {
      if (c.publicKeyHex == keyHex) return c;
    }
    return null;
  }

  /// Asks [sender] for the packets of [env] that we do not have yet.
  Future<void> requestClip(VoxVoiceEnvelope env, Contact? sender) async {
    if (await warmUp(env)) return;
    final clip = _incoming.putIfAbsent(env.sessionId, () => _IncomingClip(env));
    if (clip.status == VoxClipStatus.requesting ||
        clip.status == VoxClipStatus.receiving) {
      return;
    }
    if (sender != null) clip.sender = sender;
    final target = clip.sender;
    if (target == null) {
      _fail(clip, 'Sender is not in your contacts');
      return;
    }
    final route = _directRoute(target);
    if (route == null) {
      _fail(clip, 'No direct route to ${target.name} yet. Message them first.');
      return;
    }
    final self = _connector.selfPublicKey;
    if (self == null || !_connector.isConnected) {
      _fail(clip, 'Not connected to a radio');
      return;
    }
    clip.retriesLeft = 2;
    await _sendFetch(clip, route, self);
  }

  Future<void> _sendFetch(
    _IncomingClip clip,
    Uint8List route,
    Uint8List self,
  ) async {
    final missing = clip.packets.isEmpty ? null : clip.missing;
    final req = VoxVoiceFetchRequest(
      sessionId: clip.envelope.sessionId,
      requesterKey6: voxKey6Hex(self),
      missingIndices: missing,
    );
    clip.status = VoxClipStatus.requesting;
    clip.message = null;
    notifyListeners();
    try {
      await _connector.sendFrame(
        buildSendRawDataFrame(path: route, payload: req.encode()),
        waitForGenericAck: true,
      );
    } catch (e) {
      _fail(clip, 'Could not send request: $e');
      return;
    }
    _armWatchdog(clip);
  }

  void _armWatchdog(_IncomingClip clip) {
    clip.watchdog?.cancel();
    // First packet needs the request to arrive and the reply to come back.
    final wait = Duration(seconds: 6 + 2 * _hopCount(clip.sender));
    clip.watchdog = Timer(
      clip.status == VoxClipStatus.receiving
          ? wait + _packetGap()
          : wait + const Duration(seconds: 6),
      () => _onWatchdog(clip),
    );
  }

  Future<void> _onWatchdog(_IncomingClip clip) async {
    if (clip.isComplete) return;
    final sender = clip.sender;
    final route = sender == null ? null : _directRoute(sender);
    final self = _connector.selfPublicKey;
    if (clip.retriesLeft > 0 && route != null && self != null) {
      clip.retriesLeft--;
      await _sendFetch(clip, route, self);
      return;
    }
    _fail(
      clip,
      clip.packets.isEmpty
          ? 'Voice unavailable right now'
          : 'Got ${clip.packets.length}/${clip.envelope.totalPackets}. Tap to retry.',
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
    await warmUp(env);
    final bits = _completeBits[env.sessionId];
    if (bits == null || !voxCodecAvailable) return null;
    final pcm = await compute(_decodeJob, _DecodeJob(bits, env.mode));
    return voxPcm16ToWav(pcm);
  }

  // ------------------------------------------------------------- raw frames

  void _onFrame(Uint8List frame) {
    if (frame.isEmpty || frame[0] != pushCodeRawData) return;
    final push = RawDataPush.tryParse(frame);
    if (push == null || push.payload.isEmpty) return;
    switch (push.payload[0]) {
      case voxVoicePacketMagic:
        final pkt = VoxVoicePacket.tryParse(push.payload);
        if (pkt != null) _onPacket(pkt);
      case voxVoiceFetchMagic:
        final req = VoxVoiceFetchRequest.tryParse(push.payload);
        if (req != null) _onFetchRequest(req);
    }
  }

  void _onPacket(VoxVoicePacket pkt) {
    final clip = _incoming[pkt.sessionId];
    // Only accept packets for clips we asked for; ignore stray sessions.
    if (clip == null || clip.isComplete) return;
    if (pkt.index >= clip.envelope.totalPackets) return;
    clip.packets[pkt.index] = pkt.codecData;
    if (clip.isComplete) {
      clip.watchdog?.cancel();
      final bits = clip.joined();
      _completeBits[pkt.sessionId] = bits;
      clip.status = VoxClipStatus.complete;
      unawaited(_store.save(pkt.sessionId, bits));
    } else {
      clip.status = VoxClipStatus.receiving;
      _armWatchdog(clip);
    }
    notifyListeners();
  }

  void _onFetchRequest(VoxVoiceFetchRequest req) {
    _pruneOutgoing();
    final key = '${req.sessionId}/${req.requesterKey6}';
    final last = _recentServes[key];
    if (last != null &&
        DateTime.now().difference(last) < const Duration(seconds: 5)) {
      return; // duplicate request while we are already answering it
    }
    _recentServes[key] = DateTime.now();
    _serveChain = _serveChain.then((_) => _serve(req)).catchError((_) {});
  }

  Future<void> _serve(VoxVoiceFetchRequest req) async {
    List<VoxVoicePacket>? packets = _outgoing[req.sessionId]?.packets;
    if (packets == null) {
      // Clips we received in full can be relayed too.
      final env = _incoming[req.sessionId]?.envelope;
      final bits = _completeBits[req.sessionId];
      if (env != null && bits != null) {
        packets = voxPacketize(req.sessionId, bits, env.mode);
      }
    }
    if (packets == null) return;

    Contact? requester;
    for (final c in _connector.contacts) {
      if (c.publicKeyHex.toLowerCase().startsWith(req.requesterKey6)) {
        requester = c;
        break;
      }
    }
    if (requester == null) return;
    final route = _directRoute(requester);
    if (route == null) return; // raw data cannot be flooded

    final wanted = req.missingIndices?.toSet();
    final toSend = [
      for (final p in packets)
        if (wanted == null || wanted.contains(p.index)) p,
    ];
    for (var i = 0; i < toSend.length; i++) {
      if (!_connector.isConnected) return;
      if (i > 0) await Future<void>.delayed(_packetGap());
      try {
        await _connector.sendFrame(
          buildSendRawDataFrame(path: route, payload: toSend[i].encode()),
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

  int _hopCount(Contact? c) => c == null ? 0 : max(c.pathLength, 0);

  /// Pause between voice packets so we do not talk over our own relays.
  Duration _packetGap() {
    final sf = _connector.currentSf;
    final bwHz = _connector.currentBwHz;
    final cr = _connector.currentCr;
    if (sf == null || bwHz == null || bwHz <= 0) {
      return const Duration(milliseconds: 1500);
    }
    final air = voxEstimateAirtime(
      totalPackets: 1,
      codecBytesPerPacket: voxMaxCodecBytesPerPacket,
      spreadingFactor: sf,
      bandwidthKhz: bwHz / 1000,
      codingRate: cr ?? 5,
    );
    // One packet of airtime plus room for one relay hop, minimum 400 ms.
    return Duration(
      milliseconds: max(400, air.inMilliseconds * 2 + 150),
    );
  }

  @override
  void dispose() {
    _sub.cancel();
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
