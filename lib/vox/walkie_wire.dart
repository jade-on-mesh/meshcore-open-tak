// MeshCore Open TAK - push-to-talk ("walkie-talkie") on MediaMesh.
//
// A talk is a voice clip sent while it is being spoken: each second of
// Codec2 goes out as soon as it is encoded, on the channel, and listeners play
// it as it arrives. Afterwards the talk is announced like any voice message
// (VE3, same session id), so it stays in the chat and anyone who missed it can
// fetch it the usual way. Shared with Wadamesh TAK (src/ui-touch/WalkieWire.h).
//
// GRP_DATA, data type 0x5643 (the same as Open TAK's channel photos and voice,
// so every MediaMesh firmware sends it on radio2 only):
//
//   talk start  [0x53 'S'][sid:4 BE][mode:1][name: UTF-8, the rest, <= 32 B]
//   talk audio  [0x54 'T'][sid:4 BE][index:1][flags:1][Codec2 frames]
//               flags bit 7: the talk's last packet (it may hold no audio)
//               flags bits 0-4: the VE3 mode id (1 = Codec2 1200)
//
// Audio packet `i` holds exactly VE3 packet `i` of the clip (156 bytes, less
// in the last), so packets heard live complete the voice message too.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'voice_wire.dart';

const int walkieStartMagic = 0x53; // 'S'
const int walkieAudioMagic = 0x54; // 'T'
const int walkieLastFlag = 0x80;
const int walkieModeMask = 0x1F;
const int walkieAudioHeaderLength = 7;
const int walkieMaxNameBytes = 32;

/// Codec2 1200: one packet is 26 frames, 1.04 s of speech, sent about as
/// fast as it is spoken. Every standalone and app plays it.
const VoxVoiceMode walkieMode = VoxVoiceMode.mode1200;

/// Longest talk, the same as a recorded voice message.
const Duration walkieMaxTalk = Duration(seconds: 20);

/// A talk with nothing heard for this long has ended (its last packet lost).
const Duration walkieTalkTimeout = Duration(milliseconds: 3500);

/// Shorter than this is a slip of the finger: not announced as a message.
const Duration walkieMinTalk = Duration(milliseconds: 600);

bool walkieIsLivePayload(List<int> p) =>
    p.isNotEmpty && (p[0] == walkieStartMagic || p[0] == walkieAudioMagic);

/// `[0x53][sid][mode][name]`: someone pressed talk.
class WalkieStart {
  final String sessionId;
  final VoxVoiceMode mode;
  final String name;

  const WalkieStart({
    required this.sessionId,
    required this.name,
    this.mode = walkieMode,
  });

  Uint8List encode() {
    final nameBytes = _fitUtf8(name, walkieMaxNameBytes);
    final out = Uint8List(6 + nameBytes.length);
    out[0] = walkieStartMagic;
    out.setRange(1, 5, voxSessionIdToBytes(sessionId));
    out[5] = mode.wireId;
    out.setRange(6, out.length, nameBytes);
    return out;
  }

  static WalkieStart? tryParse(List<int> p) {
    if (p.length < 6 || p[0] != walkieStartMagic) return null;
    final mode = VoxVoiceMode.fromWireId(p[5]);
    if (mode == null || !mode.isCodec2) return null;
    final raw = p.sublist(6, min(p.length, 6 + walkieMaxNameBytes));
    return WalkieStart(
      sessionId: voxSessionIdFromBytes(p, 1),
      mode: mode,
      name: utf8.decode(raw, allowMalformed: true).trim(),
    );
  }
}

/// `[0x54][sid][index][flags][frames]`: one second of a talk.
class WalkieAudio {
  final String sessionId;
  final int index;
  final VoxVoiceMode mode;
  final bool last;
  final Uint8List codecData;

  WalkieAudio({
    required this.sessionId,
    required this.index,
    required this.codecData,
    this.mode = walkieMode,
    this.last = false,
  });

  Uint8List encode() {
    final out = Uint8List(walkieAudioHeaderLength + codecData.length);
    out[0] = walkieAudioMagic;
    out.setRange(1, 5, voxSessionIdToBytes(sessionId));
    out[5] = index;
    out[6] = (mode.wireId & walkieModeMask) | (last ? walkieLastFlag : 0);
    out.setRange(walkieAudioHeaderLength, out.length, codecData);
    return out;
  }

  static WalkieAudio? tryParse(List<int> p) {
    if (p.length < walkieAudioHeaderLength || p[0] != walkieAudioMagic) {
      return null;
    }
    final mode = VoxVoiceMode.fromWireId(p[6] & walkieModeMask);
    if (mode == null || !mode.isCodec2) return null;
    if (p[5] >= voxMaxPackets) return null;
    final data = Uint8List.fromList(p.sublist(walkieAudioHeaderLength));
    // Whole frames only; a packet that isn't is not ours.
    if (data.length % mode.bytesPerFrame != 0) return null;
    if (data.length > mode.bytesPerPacket) return null;
    return WalkieAudio(
      sessionId: voxSessionIdFromBytes(p, 1),
      index: p[5],
      mode: mode,
      last: (p[6] & walkieLastFlag) != 0,
      codecData: data,
    );
  }

  /// Packets in the talk once this, its last, has arrived.
  int get totalIfLast => codecData.isEmpty ? index : index + 1;

  Duration get duration => Duration(
    milliseconds: codecData.length ~/ mode.bytesPerFrame * mode.frameMs,
  );
}

Uint8List _fitUtf8(String s, int maxBytes) {
  final out = <int>[];
  for (final r in s.trim().runes) {
    final b = utf8.encode(String.fromCharCode(r));
    if (out.length + b.length > maxBytes) break;
    out.addAll(b);
  }
  return Uint8List.fromList(out);
}

/// Splits a talk's Codec2 into packets as it is spoken: full packets as soon
/// as there are enough frames, the rest when the talk ends.
class WalkiePacketizer {
  WalkiePacketizer(this.sessionId, {this.mode = walkieMode});

  final String sessionId;
  final VoxVoiceMode mode;
  final BytesBuilder _all = BytesBuilder(copy: true);
  final List<int> _pending = [];
  int _next = 0;
  bool _ended = false;

  /// All the Codec2 so far (the voice message, once ended).
  Uint8List get bits => _all.toBytes();

  int get packetsSent => _next;

  /// Adds encoded frames; returns the packets now full.
  List<WalkieAudio> add(Uint8List frames) {
    if (_ended) return const [];
    _all.add(frames);
    _pending.addAll(frames);
    final out = <WalkieAudio>[];
    final per = mode.bytesPerPacket;
    while (_pending.length >= per) {
      out.add(
        WalkieAudio(
          sessionId: sessionId,
          index: _next++,
          mode: mode,
          codecData: Uint8List.fromList(_pending.sublist(0, per)),
        ),
      );
      _pending.removeRange(0, per);
    }
    return out;
  }

  /// The last packet: what is left, possibly nothing (it still says "end").
  WalkieAudio finish() {
    _ended = true;
    final p = WalkieAudio(
      sessionId: sessionId,
      index: min(_next, voxMaxPackets - 1),
      mode: mode,
      last: true,
      codecData: Uint8List.fromList(_pending),
    );
    if (_pending.isNotEmpty) _next++;
    _pending.clear();
    return p;
  }
}

/// Decides when each packet of a talk being heard is played: waits a little
/// after the first so a late packet doesn't leave a gap, plays packets in
/// order, and skips one that hasn't come by the time it's needed.
class WalkieJitter {
  WalkieJitter({
    this.startDelay = const Duration(milliseconds: 500),
    this.skipGrace = const Duration(milliseconds: 400),
  });

  /// Wait after the first packet before playing (none once two are in).
  final Duration startDelay;

  /// How long past the end of what is playing a missing packet may still come.
  final Duration skipGrace;

  final Map<int, Uint8List> _packets = {};
  DateTime? _firstAt;
  DateTime? _lastHeard;
  DateTime? _playEnd;
  int _next = 0;
  int? _total;
  bool _started = false;
  final VoxVoiceMode mode = walkieMode;

  int? get total => _total;
  bool get started => _started;
  int get nextIndex => _next;

  /// Packets played or given up on.
  int get done => _next;

  void add(WalkieAudio a, DateTime now) {
    _firstAt ??= now;
    _lastHeard = now;
    if (a.last) _total = a.totalIfLast;
    if (a.codecData.isNotEmpty && a.index >= _next) {
      _packets[a.index] = a.codecData;
    }
  }

  /// The talk has been played to its end, or went quiet for good.
  bool finished(DateTime now) {
    final t = _total;
    if (t != null && _next >= t) return true;
    final heard = _lastHeard;
    if (heard == null) return false;
    final playEnd = _playEnd ?? heard;
    final quiet = now.difference(heard) > walkieTalkTimeout;
    return quiet && _packets.isEmpty && !now.isBefore(playEnd);
  }

  /// The packets to play now, in order.
  List<Uint8List> due(DateTime now) {
    final first = _firstAt;
    if (first == null) return const [];
    if (!_started) {
      final ready =
          _packets.length >= 2 ||
          _total != null ||
          now.difference(first) >= startDelay;
      if (!ready) return const [];
      _started = true;
      // Packet 0 lost: start at the first one heard.
      if (!_packets.containsKey(0) && _packets.isNotEmpty) {
        _next = _packets.keys.reduce(min);
      }
    }
    final out = <Uint8List>[];
    while (true) {
      final t = _total;
      if (t != null && _next >= t) break;
      final p = _packets.remove(_next);
      if (p != null) {
        final from = _playEnd != null && _playEnd!.isAfter(now)
            ? _playEnd!
            : now;
        _playEnd = from.add(
          Duration(milliseconds: p.length ~/ mode.bytesPerFrame * mode.frameMs),
        );
        out.add(p);
        _next++;
        continue;
      }
      // Missing: skip it once it can no longer arrive in time, if something
      // after it has come or the talk's length is known. With neither there is
      // nothing to skip to: a talk that went quiet without its last packet
      // used to skip here forever and froze the app; finished() ends it.
      final playEnd = _playEnd ?? now;
      final late = !now.isBefore(playEnd.add(skipGrace));
      final later = _packets.keys.any((k) => k > _next) || _total != null;
      if (late && later) {
        _next++;
        continue;
      }
      break;
    }
    return out;
  }
}

/// A 48 kHz to 8 kHz decimator that keeps its filter history between calls,
/// for the microphone stream of a live talk (voxDecimate does a whole clip).
class WalkieDecimator {
  WalkieDecimator({this.factor = 6, int taps = 63})
    : _h = _design(factor, taps),
      _hist = Float64List(taps);

  final int factor;
  final Float64List _h;
  final Float64List _hist;
  int _pos = 0;
  int _phase = 0;

  static Float64List _design(int factor, int taps) {
    final cutoff = 0.45 / factor;
    final h = Float64List(taps);
    final mid = (taps - 1) / 2;
    var sum = 0.0;
    for (var i = 0; i < taps; i++) {
      final n = i - mid;
      final sinc = n == 0 ? 2 * cutoff : sin(2 * pi * cutoff * n) / (pi * n);
      final w =
          0.42 -
          0.5 * cos(2 * pi * i / (taps - 1)) +
          0.08 * cos(4 * pi * i / (taps - 1));
      h[i] = sinc * w;
      sum += h[i];
    }
    for (var i = 0; i < taps; i++) {
      h[i] /= sum;
    }
    return h;
  }

  /// PCM16 in at the input rate; PCM16 out at a [factor]th of it.
  Int16List process(Int16List input) {
    final out = <int>[];
    final n = _h.length;
    for (final s in input) {
      _hist[_pos] = s.toDouble();
      _pos = (_pos + 1) % n;
      if (++_phase < factor) continue;
      _phase = 0;
      var acc = 0.0;
      // _pos is now the oldest sample.
      for (var k = 0; k < n; k++) {
        acc += _h[k] * _hist[(_pos + k) % n];
      }
      out.add(acc.round().clamp(-32768, 32767));
    }
    return Int16List.fromList(out);
  }
}

/// Little-endian PCM16 bytes (as the recorder streams them) to samples.
Int16List walkiePcmFromBytes(Uint8List bytes) {
  final bd = ByteData.sublistView(bytes);
  final out = Int16List(bytes.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = bd.getInt16(i * 2, Endian.little);
  }
  return out;
}

/// Bars in a voice waveform.
const int voxWaveBars = 40;

/// [pcm] as [n] RMS levels (PCM16 scale), one per equal slice.
List<double> voxSliceLevels(Int16List pcm, int n) {
  final out = List<double>.filled(n, 0);
  if (pcm.isEmpty) return out;
  for (var k = 0; k < n; k++) {
    final from = pcm.length * k ~/ n;
    final to = max(from + 1, pcm.length * (k + 1) ~/ n);
    var sum = 0.0;
    for (var i = from; i < to && i < pcm.length; i++) {
      sum += pcm[i] * pcm[i].toDouble();
    }
    out[k] = sqrt(sum / (to - from));
  }
  return out;
}

/// A waveform of [bars] from per-packet slice levels ([voxSliceLevels]), some
/// packets not here yet (null): their bars are -1. Scaled as [voxWaveform].
/// Null while no packet is here.
List<double>? voxPartialWaveform(
  List<List<double>?> packets,
  int slicesPerPacket, {
  int bars = voxWaveBars,
}) {
  final total = packets.length * slicesPerPacket;
  if (total == 0 || packets.every((p) => p == null)) return null;
  final out = List<double>.filled(bars, -1);
  var top = 0.0;
  for (var b = 0; b < bars; b++) {
    final from = total * b ~/ bars;
    final to = max(from + 1, total * (b + 1) ~/ bars);
    var sum = 0.0;
    var n = 0;
    for (var s = from; s < to && s < total; s++) {
      final p = packets[s ~/ slicesPerPacket];
      if (p == null) continue;
      final v = p[s % slicesPerPacket];
      sum += v * v;
      n++;
    }
    if (n == 0) continue;
    out[b] = sqrt(sum / n);
    if (out[b] > top) top = out[b];
  }
  for (var b = 0; b < bars; b++) {
    if (out[b] < 0) continue;
    out[b] = top < 200 ? 0 : sqrt(out[b] / top).clamp(0.0, 1.0);
  }
  return out;
}

/// [pcm] as [voxWaveBars] loudness bars, 0..1: each bar the RMS of its slice,
/// scaled to the loudest (square-rooted, so quiet speech still shows).
List<double> voxWaveform(Int16List pcm, {int bars = voxWaveBars}) {
  final out = List<double>.filled(bars, 0);
  if (pcm.isEmpty) return out;
  var top = 0.0;
  for (var b = 0; b < bars; b++) {
    final from = pcm.length * b ~/ bars;
    final to = max(from + 1, pcm.length * (b + 1) ~/ bars);
    var sum = 0.0;
    for (var i = from; i < to && i < pcm.length; i++) {
      sum += pcm[i] * pcm[i].toDouble();
    }
    out[b] = sqrt(sum / (to - from));
    if (out[b] > top) top = out[b];
  }
  if (top < 200) return out..fillRange(0, bars, 0); // silence
  for (var b = 0; b < bars; b++) {
    out[b] = sqrt(out[b] / top).clamp(0.0, 1.0);
  }
  return out;
}
