// MeshCore Open TAK - push-to-talk on a channel, over MediaMesh.
//
// Hold to talk: the mic is encoded to Codec2 1200 as you speak and each second
// goes out on the channel as soon as it's ready (walkie_wire.dart). Listeners
// hear it as it arrives. When you let go, the talk is posted as a voice message with the
// same session id, so it stays in the chat and anyone who missed it can fetch
// it. Talks on every channel play live by default (like a scanner); "Play
// talks live" turns that off, and each channel can be muted. Like Open TAK's photos and voice, talks only go out on MediaMesh.

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../connector/meshcore_connector.dart';
import '../models/channel.dart';
import '../models/contact.dart';
import '../services/media_lockdown.dart';
import 'resample.dart';
import 'voice_codec.dart';
import 'voice_dsp.dart';
import 'voice_service.dart';
import 'voice_wire.dart';
import 'walkie_audio.dart';
import 'walkie_wire.dart';

/// A talk heard on a channel, or in a DM ([contactKeyHex] set, and
/// [channelIndex] -1).
class WalkieTalk {
  WalkieTalk(
    this.sessionId,
    this.channelIndex,
    DateTime now, {
    this.contactKeyHex,
  }) : firstHeard = now,
       lastHeard = now;

  final String sessionId;
  final int channelIndex;
  final String? contactKeyHex;
  final DateTime firstHeard;
  DateTime lastHeard;
  String name = '';
  bool endHeard = false;
  bool playing = false;
  bool played = false;
  final WalkieJitter jitter = WalkieJitter();
  VoxCodec2Stream? _decoder;
  VoxPlayOut? _playOut;

  /// Still on the air (its end not heard, and heard recently).
  bool activeAt(DateTime now) =>
      !endHeard && now.difference(lastHeard) <= walkieTalkTimeout;
}

/// What the local talk button is doing.
enum WalkieTx { idle, starting, onAir, finishing }

class _Tx {
  _Tx(this.channel, this.sessionId, this.direct) : contact = null, route = null;
  _Tx.dm(Contact this.contact, Uint8List this.route, this.sessionId)
    : channel = null,
      direct = route.isEmpty;

  /// A channel talk's channel, or null in a DM.
  final Channel? channel;

  /// A DM talk's contact and the route to them (empty: zero-hop).
  final Contact? contact;
  final Uint8List? route;
  final String sessionId;
  final bool direct;
  final AudioRecorder recorder = AudioRecorder();
  StreamSubscription<Uint8List>? sub;
  VoxCodec2Stream? encoder;
  late final WalkiePacketizer packets = WalkiePacketizer(sessionId);
  final WalkieDecimator decimator = WalkieDecimator(
    factor: voxRecordSampleRate ~/ 8000,
  );
  final VoxMicGate gate = VoxMicGate();
  final List<int> frame = [];
  int? carry;
  int samples8k = 0;
  DateTime? startedAt;
  DateTime? lastSent;
  Future<void> chain = Future.value();

  /// The button was let go (maybe before the mic was even running).
  bool releaseAsked = false;

  /// Sending what's left and announcing it.
  bool finishing = false;
  bool failed = false;
  bool recording = false;
  int level = 0;
}

class WalkieService extends ChangeNotifier {
  WalkieService(this._connector, this._voice) {
    _voice.liveTalkHandler = _onLive;
    _voice.dmTalkHandler = _onDmLive;
    _voice.channelVoiceMuted = isVoiceMutedAt;
    unawaited(_load());
  }

  final MeshCoreConnector _connector;
  final VoxVoiceService _voice;
  final WalkieSpeaker _speaker = WalkieSpeaker();
  final Random _rng = Random.secure();

  static const _kLiveAll = 'walkie_live_all';
  static const _kMuted = 'walkie_muted';
  static const _kDirect = 'walkie_direct';

  bool _liveAll = false;
  Set<String> _mutedKeys = {};
  Set<String> _directKeys = {};
  final Map<int, int> _openPanels = {};
  final Map<String, int> _openDmPanels = {};

  final Map<String, WalkieTalk> _talks = {};
  final Set<String> _ownSids = {};
  WalkieTalk? _playing;
  Timer? _ticker;

  _Tx? _tx;
  String? _error;

  /// Whether push-to-talk can run in this build (Codec2 is needed).
  bool get available => voxCodecAvailable;

  WalkieTx get tx => _tx == null
      ? WalkieTx.idle
      : _tx!.startedAt == null
      ? WalkieTx.starting
      : _tx!.finishing
      ? WalkieTx.finishing
      : WalkieTx.onAir;

  /// The channel being talked on, if any.
  int? get talkingOn => _tx?.channel?.index;

  /// The contact being talked to in a DM (public key hex), if any.
  String? get talkingWith => _tx?.contact?.publicKeyHex;

  /// How long the current talk has run.
  Duration get talkElapsed =>
      Duration(milliseconds: (_tx?.samples8k ?? 0) * 1000 ~/ 8000);

  /// Mic level of the current talk, 0..100.
  int get talkLevel => _tx?.level ?? 0;

  /// Why the last talk didn't go out, until the next one starts.
  String? get error => _error;

  void clearError() {
    if (_error == null) return;
    _error = null;
    notifyListeners();
  }

  // ------------------------------------------------------------ settings

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _liveAll = prefs.getBool(_kLiveAll) ?? false;
      _mutedKeys = (prefs.getStringList(_kMuted) ?? const []).toSet();
      _directKeys = (prefs.getStringList(_kDirect) ?? const []).toSet();
      notifyListeners();
    } catch (_) {}
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kLiveAll, _liveAll);
      await prefs.setStringList(_kMuted, _mutedKeys.toList());
      await prefs.setStringList(_kDirect, _directKeys.toList());
    } catch (_) {}
  }

  /// Talks on every channel not muted play as they arrive, like a scanner
  /// (off by default: talks play in the channel whose chat or walkie is open).
  bool get liveAll => _liveAll;

  Future<void> setLiveAll(bool v) async {
    if (v == _liveAll) return;
    _liveAll = v;
    notifyListeners();
    await _save();
  }

  /// Talks on [ch] play live even with the walkie closed: [liveAll], unless
  /// the channel is muted.
  bool listensLive(Channel ch) =>
      _liveAll && !_mutedKeys.contains(VoxVoiceService.channelTarget(ch));

  /// [ch] isn't muted (it plays live while [liveAll] is on).
  bool channelLive(Channel ch) =>
      !_mutedKeys.contains(VoxVoiceService.channelTarget(ch));

  Future<void> setListenLive(Channel ch, bool v) async {
    final k = VoxVoiceService.channelTarget(ch);
    if (v ? !_mutedKeys.remove(k) : !_mutedKeys.add(k)) return;
    notifyListeners();
    await _save();
  }

  /// Talks on [ch] go radio to radio (no repeaters).
  bool isDirect(Channel ch) =>
      _directKeys.contains(VoxVoiceService.channelTarget(ch));

  Future<void> setDirect(Channel ch, bool v) async {
    final k = VoxVoiceService.channelTarget(ch);
    if (v ? !_directKeys.add(k) : !_directKeys.remove(k)) return;
    notifyListeners();
    await _save();
  }

  /// The walkie for [channelIndex] is on screen: its talks play.
  void panelOpened(int channelIndex) {
    _openPanels[channelIndex] = (_openPanels[channelIndex] ?? 0) + 1;
  }

  void panelClosed(int channelIndex) {
    final n = (_openPanels[channelIndex] ?? 1) - 1;
    if (n <= 0) {
      _openPanels.remove(channelIndex);
    } else {
      _openPanels[channelIndex] = n;
    }
  }

  /// A DM talk to [c] has a route to follow (else it goes zero-hop: heard
  /// live only if they're in range; the voice message gets there anyway).
  bool dmRouteKnown(Contact c) => _voice.directRouteTo(c) != null;

  /// The walkie for the DM with [contactKeyHex] is on screen.
  void dmPanelOpened(String contactKeyHex) {
    _openDmPanels[contactKeyHex] = (_openDmPanels[contactKeyHex] ?? 0) + 1;
  }

  void dmPanelClosed(String contactKeyHex) {
    final n = (_openDmPanels[contactKeyHex] ?? 1) - 1;
    if (n <= 0) {
      _openDmPanels.remove(contactKeyHex);
    } else {
      _openDmPanels[contactKeyHex] = n;
    }
  }

  /// A DM talk plays live: it's addressed to you, so as voice DMs do (with
  /// auto-play on), or while that DM's chat or walkie is open.
  bool _listensToDm(String contactKeyHex) =>
      _openDmPanels.containsKey(contactKeyHex) ||
      _voice.autoPlay ||
      _connector.activeContactKeyHex == contactKeyHex;

  /// A talk on [channelIndex] plays live: its walkie is open; or voice
  /// isn't muted there and its chat is open, or [liveAll] is on.
  bool _listensTo(int channelIndex) {
    if (_openPanels.containsKey(channelIndex)) return true;
    for (final ch in _connector.channels) {
      if (ch.index != channelIndex) continue;
      if (isVoiceMuted(ch)) return false;
      return _connector.activeChannelIndex == channelIndex || _liveAll;
    }
    return false;
  }

  /// Voice is muted in [ch]: its talks don't play live (only with its walkie
  /// open) and its voice messages don't play by themselves.
  bool isVoiceMuted(Channel ch) =>
      _mutedKeys.contains(VoxVoiceService.channelTarget(ch));

  bool isVoiceMutedAt(int channelIndex) {
    for (final ch in _connector.channels) {
      if (ch.index == channelIndex) return isVoiceMuted(ch);
    }
    return false;
  }

  Future<void> setVoiceMuted(Channel ch, bool muted) =>
      setListenLive(ch, !muted);

  // ------------------------------------------------------------- hearing

  /// The talk on the air on [channelIndex], if someone is talking.
  WalkieTalk? activeTalkOn(int channelIndex) {
    final now = DateTime.now();
    WalkieTalk? best;
    for (final t in _talks.values) {
      if (t.channelIndex != channelIndex || !t.activeAt(now)) continue;
      if (best == null || t.lastHeard.isAfter(best.lastHeard)) best = t;
    }
    return best;
  }

  /// The DM talk on the air from [contactKeyHex], if they're talking.
  WalkieTalk? activeTalkWith(String contactKeyHex) {
    final now = DateTime.now();
    WalkieTalk? best;
    for (final t in _talks.values) {
      if (t.contactKeyHex != contactKeyHex || !t.activeAt(now)) continue;
      if (best == null || t.lastHeard.isAfter(best.lastHeard)) best = t;
    }
    return best;
  }

  /// The most recent DM talk heard from [contactKeyHex].
  WalkieTalk? lastTalkWith(String contactKeyHex) {
    WalkieTalk? best;
    for (final t in _talks.values) {
      if (t.contactKeyHex != contactKeyHex) continue;
      if (best == null || t.lastHeard.isAfter(best.lastHeard)) best = t;
    }
    return best;
  }

  /// The most recent talk heard on [channelIndex] (on the air or not).
  WalkieTalk? lastTalkOn(int channelIndex) {
    WalkieTalk? best;
    for (final t in _talks.values) {
      if (t.channelIndex != channelIndex) continue;
      if (best == null || t.lastHeard.isAfter(best.lastHeard)) best = t;
    }
    return best;
  }

  /// The talk playing right now, if any.
  WalkieTalk? get playing => _playing;

  void _onLive(Uint8List p, int channelIndex, int? via, int? hops) {
    final now = DateTime.now();
    final sid = p.length >= 5 ? voxSessionIdFromBytes(p, 1) : '';
    if (_ownSids.contains(sid)) return; // our own, relayed back
    if (p[0] == walkieStartMagic) {
      final s = WalkieStart.tryParse(p);
      if (s == null) return;
      final t = _talk(sid, channelIndex, now);
      t.name = s.name;
      t.lastHeard = now;
      _tick();
      notifyListeners();
      return;
    }
    final a = WalkieAudio.tryParse(p);
    if (a == null) return;
    final t = _talk(sid, channelIndex, now);
    t.lastHeard = now;
    if (a.last) t.endHeard = true;
    _voice.acceptLivePacket(sid, a.index, a.codecData, via: via, hops: hops);
    t.jitter.add(a, now);
    if (_playing == null &&
        _tx == null &&
        !t.played &&
        _listensTo(channelIndex)) {
      unawaited(_startPlaying(t));
    }
    _tick();
    notifyListeners();
  }

  WalkieTalk _talk(String sid, int channelIndex, DateTime now) {
    final t = _talks.putIfAbsent(sid, () => WalkieTalk(sid, channelIndex, now));
    return t;
  }

  /// A DM talk packet addressed to us (VoxVoiceService checked `to`).
  void _onDmLive(WalkieDmAudio a, int? via) {
    final now = DateTime.now();
    final sid = a.sessionId;
    if (_ownSids.contains(sid)) return;
    final c = _voice.contactByKeyPrefix(_hex(a.from));
    if (c == null) return; // not one of our contacts
    final key = c.publicKeyHex;
    final t = _talks.putIfAbsent(
      sid,
      () => WalkieTalk(sid, -1, now, contactKeyHex: key),
    );
    if (t.contactKeyHex != key) return;
    t.name = c.name;
    t.lastHeard = now;
    final audio = a.audio;
    if (audio.last) t.endHeard = true;
    _voice.acceptLivePacket(sid, audio.index, audio.codecData, via: via);
    t.jitter.add(audio, now);
    if (_playing == null && _tx == null && !t.played && _listensToDm(key)) {
      unawaited(_startPlaying(t));
    }
    _tick();
    notifyListeners();
  }

  static String _hex(List<int> b) =>
      b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();

  Future<void> _startPlaying(WalkieTalk t) async {
    if (!voxCodecAvailable) return;
    _playing = t;
    t.playing = true;
    t.played = true;
    try {
      t._decoder = VoxCodec2Stream(walkieMode);
      t._playOut = VoxPlayOut(outRate: WalkieSpeaker.sampleRate);
      _voice.micBusy = true; // nothing else auto-plays meanwhile
      await _speaker.start();
    } catch (_) {
      _stopPlaying(t);
    }
  }

  void _stopPlaying(WalkieTalk t, {bool now = false}) {
    t.playing = false;
    t._decoder?.dispose();
    t._decoder = null;
    if (identical(_playing, t)) {
      _playing = null;
      unawaited(now ? _speaker.stop() : _speaker.finish());
      if (_tx == null) _voice.micBusy = false;
    }
  }

  void _tick() {
    _ticker ??= Timer.periodic(const Duration(milliseconds: 100), (_) {
      _onTick();
    });
  }

  void _onTick() {
    final now = DateTime.now();
    final t = _playing;
    if (t != null) {
      final dec = t._decoder;
      if (dec != null) {
        for (final chunk in t.jitter.due(now)) {
          try {
            final pcm = dec.decode(chunk);
            final out = t._playOut;
            unawaited(_speaker.write(out == null ? pcm : out.push(pcm)));
            _voice.markHeardLive(t.sessionId);
          } catch (_) {}
        }
      }
      if (t.jitter.finished(now) || (!t.activeAt(now) && !t.jitter.started)) {
        _stopPlaying(t);
        notifyListeners();
      }
    }
    // Forget talks a while after they end; stop ticking when nothing's left.
    final before = _talks.length;
    _talks.removeWhere(
      (_, v) =>
          !v.playing &&
          now.difference(v.lastHeard) > const Duration(minutes: 10),
    );
    final active = _talks.values.any((v) => v.activeAt(now) || v.playing);
    if (_talks.length != before) notifyListeners();
    if (!active && _playing == null && _tx == null) {
      _ticker?.cancel();
      _ticker = null;
      notifyListeners(); // "talking" turns to "clear"
    } else if (_tx != null) {
      notifyListeners(); // the talk timer and level
    }
  }

  // ------------------------------------------------------------- talking

  /// Starts talking on [ch]. Returns why it can't, or null once started (or
  /// starting). Call [stopTalk] when the button is let go.
  Future<String?> startTalk(Channel ch) async {
    if (_tx != null) return null;
    _error = null;
    if (!voxCodecAvailable) {
      return voxCodecUnavailableReason ?? 'Voice is not available here';
    }
    if (!_connector.isConnected) return 'Not connected to a radio';
    if (!_connector.supportsChannelData) {
      return "This radio's firmware can't send channel data";
    }
    final busy = activeTalkOn(ch.index);
    if (busy != null) {
      return busy.name.isEmpty
          ? 'Someone is talking'
          : '${busy.name} is talking';
    }
    return _begin(_Tx(ch, voxNewSessionId(_rng), isDirect(ch)));
  }

  /// Starts talking to [contact] in a DM: each second goes to them alone, as
  /// raw data along the route to them (zero-hop with none), and the talk is
  /// sent to them as a voice message at the end. Returns why it can't, or
  /// null once started (or starting).
  Future<String?> startTalkTo(Contact contact) async {
    if (_tx != null) return null;
    _error = null;
    if (!voxCodecAvailable) {
      return voxCodecUnavailableReason ?? 'Voice is not available here';
    }
    if (!_connector.isConnected) return 'Not connected to a radio';
    if ((_connector.selfPublicKey?.length ?? 0) < walkieDmKeyBytes) {
      return 'Not connected to a radio';
    }
    final busy = activeTalkWith(contact.publicKeyHex);
    if (busy != null) return '${contact.name} is talking';
    final route = _voice.directRouteTo(contact) ?? Uint8List(0);
    return _begin(_Tx.dm(contact, route, voxNewSessionId(_rng)));
  }

  Future<String?> _begin(_Tx tx) async {
    final sid = tx.sessionId;
    _tx = tx;
    _ownSids.add(sid);
    if (_ownSids.length > 64) _ownSids.remove(_ownSids.first);
    notifyListeners();

    String? fail;
    try {
      if (!await _voice.canSendMedia()) {
        fail = MediaLockdown.blockedMessage;
      } else if (!await tx.recorder.hasPermission()) {
        fail = 'Microphone permission denied';
      }
    } catch (e) {
      fail = '$e';
    }
    if (fail == null && tx.releaseAsked) fail = ''; // let go before it started
    if (fail != null) {
      await _endTx(tx);
      if (fail.isNotEmpty) _error = fail;
      notifyListeners();
      return fail.isEmpty ? null : fail;
    }

    // Half duplex: stop anything playing.
    final p = _playing;
    if (p != null) _stopPlaying(p, now: true);
    _voice.micBusy = true;
    try {
      tx.encoder = VoxCodec2Stream(walkieMode);
      if (tx.channel != null) {
        // A DM talk has no start packet: its first second says who it's from.
        _send(
          tx,
          WalkieStart(sessionId: sid, name: _connector.selfName ?? '').encode(),
        );
      }
      final stream = await tx.recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: voxRecordSampleRate,
          numChannels: 1,
          autoGain: true,
          noiseSuppress: true,
        ),
      );
      tx.recording = true;
      tx.startedAt = DateTime.now();
      tx.sub = stream.listen((b) => _onMic(tx, b));
      unawaited(HapticFeedback.mediumImpact());
    } catch (e) {
      _error = 'Microphone: $e';
      await _endTx(tx);
      notifyListeners();
      return _error;
    }
    _tick();
    notifyListeners();
    if (tx.releaseAsked) unawaited(_finish(tx));
    return null;
  }

  void _onMic(_Tx tx, Uint8List bytes) {
    if (!tx.recording || tx.finishing) return;
    // Whole samples only: a byte left over waits for the next chunk.
    var data = bytes;
    if (tx.carry != null) {
      data = Uint8List(bytes.length + 1)
        ..[0] = tx.carry!
        ..setRange(1, bytes.length + 1, bytes);
      tx.carry = null;
    }
    if (data.length.isOdd) {
      tx.carry = data.last;
      data = Uint8List.sublistView(data, 0, data.length - 1);
    }
    final pcm48 = walkiePcmFromBytes(data);
    var peak = 0;
    for (final s in pcm48) {
      final a = s.abs();
      if (a > peak) peak = a;
    }
    tx.level = min(100, peak * 100 ~/ 32000);
    final pcm8 = tx.gate.processPcm(tx.decimator.process(pcm48));
    tx.frame.addAll(pcm8);
    tx.samples8k += pcm8.length;
    _encodeFrames(tx, flush: false);
    if (talkElapsed >= walkieMaxTalk) unawaited(stopTalk());
  }

  void _encodeFrames(_Tx tx, {required bool flush}) {
    final enc = tx.encoder;
    if (enc == null) return;
    final spf = enc.samplesPerFrame;
    if (flush && tx.frame.isNotEmpty && tx.frame.length >= spf ~/ 2) {
      tx.frame.addAll(List.filled(spf - tx.frame.length % spf, 0));
    }
    final whole = tx.frame.length ~/ spf * spf;
    if (whole == 0) return;
    final bits = enc.encode(Int16List.fromList(tx.frame.sublist(0, whole)));
    tx.frame.removeRange(0, whole);
    for (final pkt in tx.packets.add(bits)) {
      _send(tx, _encode(tx, pkt));
    }
  }

  /// A second of [tx] as it goes on the air: a channel talk's packet, or a
  /// DM talk's (addressed to the contact).
  Uint8List _encode(_Tx tx, WalkieAudio a) {
    final c = tx.contact;
    if (c == null) return a.encode();
    return WalkieDmAudio(
      sessionId: a.sessionId,
      index: a.index,
      mode: a.mode,
      last: a.last,
      to: c.publicKey,
      from: _connector.selfPublicKey!,
      codecData: a.codecData,
    ).encode();
  }

  void _send(_Tx tx, Uint8List payload) {
    tx.chain = tx.chain.then((_) async {
      if (tx.failed) return;
      final route = tx.route;
      final gap = route != null
          ? _voice.walkieDmGap(route.length)
          : _voice.walkieGap(direct: tx.direct);
      final last = tx.lastSent;
      if (last != null) {
        final wait = gap - DateTime.now().difference(last);
        if (wait > Duration.zero) await Future<void>.delayed(wait);
      }
      try {
        if (route != null) {
          await _voice.sendWalkieDmPacket(route, payload);
        } else {
          await _connector.sendChannelDataPacket(
            channelIndex: tx.channel!.index,
            dataType: voxChannelDataType,
            payload: payload,
            zeroHop: tx.direct,
          );
        }
        tx.lastSent = DateTime.now();
      } catch (e) {
        tx.failed = true;
        _error = 'Could not send: $e';
        notifyListeners();
      }
    });
  }

  /// The button was let go (or the talk ran out): sends what's left, then
  /// posts the talk as a voice message.
  Future<void> stopTalk({bool cancel = false}) async {
    final tx = _tx;
    if (tx == null) return;
    tx.releaseAsked = true;
    if (tx.startedAt == null) return; // startTalk finishes it
    await _finish(tx, cancel: cancel);
  }

  Future<void> _finish(_Tx tx, {bool cancel = false}) async {
    if (tx.finishing) return;
    tx.finishing = true;
    notifyListeners();
    try {
      await tx.recorder.stop();
    } catch (_) {}
    await tx.sub?.cancel();
    tx.recording = false;
    _encodeFrames(tx, flush: true);
    _send(tx, _encode(tx, tx.packets.finish()));
    await tx.chain;
    final bits = tx.packets.bits;
    final ms = bits.length ~/ walkieMode.bytesPerFrame * walkieMode.frameMs;
    if (!cancel && !tx.failed && ms >= walkieMinTalk.inMilliseconds) {
      try {
        final secs = max(1, (ms / 1000).ceil());
        final c = tx.contact;
        if (c != null) {
          await _voice.announceTalkToContact(
            c,
            tx.sessionId,
            bits,
            durationSeconds: secs,
          );
        } else {
          await _voice.announceTalk(
            tx.channel!,
            tx.sessionId,
            bits,
            durationSeconds: secs,
          );
        }
      } catch (e) {
        _error = 'Sent live, but the voice message failed: $e';
      }
    }
    await _endTx(tx);
    notifyListeners();
  }

  Future<void> _endTx(_Tx tx) async {
    if (!identical(_tx, tx)) return;
    _tx = null;
    tx.recording = false;
    await tx.sub?.cancel();
    try {
      await tx.recorder.dispose();
    } catch (_) {}
    tx.encoder?.dispose();
    tx.encoder = null;
    if (_playing == null) _voice.micBusy = false;
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _voice.liveTalkHandler = null;
    _voice.dmTalkHandler = null;
    final tx = _tx;
    if (tx != null) unawaited(_endTx(tx));
    unawaited(_speaker.dispose());
    super.dispose();
  }
}
