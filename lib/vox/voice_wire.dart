// MeshCore Open TAK - voice message wire formats.
//
// Written from scratch for MeshCore Open TAK. Codec2 clips use the VE3
// format, a published on-air design, so VOX interoperates with other apps
// that speak it:
//
//   Control plane (ordinary text message, DM or channel):
//     VE3:{sid}:{mode}:{total}:{durS}        all fields base36
//
//   Data plane (CMD_SEND_RAW_DATA / PUSH_CODE_RAW_DATA, direct path only):
//     voice packet   [0x56][sid:4B BE][index:1B][codec2 frames...]
//     fetch request  [0x72][sid:4B BE][flags:1B][requesterKey6:6B]
//                    [missingCount:1B][missingIndices...]
//
// Audio is never pushed unasked: the sender announces the clip with VE3 and
// each listener pulls the packets when they press play.

import 'dart:math';
import 'dart:typed_data';

/// Codec2 modes with the mode ids used on the wire by VE3.
///
/// [wireId] is the VE3 envelope id. [codec2Id] is the value passed to
/// codec2_create() (CODEC2_MODE_* in codec2.h). They are different numbering
/// schemes, so never mix them up.
enum VoxVoiceMode {
  mode700c(wireId: 0, codec2Id: 8, label: '700C', bytesPerFrame: 4),
  mode1200(wireId: 1, codec2Id: 5, label: '1200', bytesPerFrame: 6),
  mode2400(
    wireId: 2,
    codec2Id: 1,
    label: '2400',
    bytesPerFrame: 6,
    frameMs: 20,
  ),
  mode1300(wireId: 3, codec2Id: 4, label: '1300', bytesPerFrame: 7),
  mode1400(wireId: 4, codec2Id: 3, label: '1400', bytesPerFrame: 7),
  mode1600(wireId: 5, codec2Id: 2, label: '1600', bytesPerFrame: 8),
  mode3200(
    wireId: 6,
    codec2Id: 0,
    label: '3200',
    bytesPerFrame: 8,
    frameMs: 20,
  ),

  /// Mimi neural codec (Kyutai), 8 codebooks of 11 bits at 12.5 frames/s:
  /// 88 bits = 11 bytes per 80 ms frame, about 1.1 kb/s. VOX-only, announced
  /// with a `VM1:` envelope instead of `VE3:` so Codec2-only apps (MeshCore
  /// apps) never try to play it as Codec2.
  mimi(wireId: 32, codec2Id: -1, label: 'Mimi', bytesPerFrame: 11, frameMs: 80),

  /// AV1 still image (VOX only), announced with `VI1:`. Not audio: the
  /// "frame" is one byte so packets carry [voxMaxCodecBytesPerPacket] bytes,
  /// and the envelope's duration field carries the aspect ratio instead
  /// (width * 100 / height).
  av1Image(
    wireId: 40,
    codec2Id: -1,
    label: 'AV1 image',
    bytesPerFrame: 1,
    frameMs: 1,
  );

  const VoxVoiceMode({
    required this.wireId,
    required this.codec2Id,
    required this.label,
    required this.bytesPerFrame,
    this.frameMs = 40,
  });

  final int wireId;
  final int codec2Id;
  final String label;
  final int bytesPerFrame;
  final int frameMs;

  /// Codec2's sample rate. Mimi works at [VoxMimiSpec.sampleRate].
  static const int sampleRateHz = 8000;

  bool get isMimi => this == mimi;
  bool get isImage => this == av1Image;
  bool get isAudio => !isImage;
  bool get isCodec2 => !isMimi && !isImage;

  int get samplesPerFrame => sampleRateHz * frameMs ~/ 1000;
  int get bytesPerSecond => bytesPerFrame * 1000 ~/ frameMs;

  /// Whole Codec2 frames that fit in one raw packet.
  int get framesPerPacket => voxMaxCodecBytesPerPacket ~/ bytesPerFrame;
  int get bytesPerPacket => framesPerPacket * bytesPerFrame;
  int get packetDurationMs => framesPerPacket * frameMs;

  static VoxVoiceMode? fromWireId(int id) {
    for (final m in values) {
      if (m.wireId == id) return m;
    }
    return null;
  }
}

/// The Codec2 mode VOX records in unless the user picks another. 1200 bps
/// keeps a 10 s clip to 10 packets.
const VoxVoiceMode voxDefaultVoiceMode = VoxVoiceMode.mode1200;

/// The Codec2 modes the user can record in (Voice settings), the same three
/// Wadamesh offers on a T-Deck (Settings > Sound). 1600 uses a third more
/// airtime than 1200, 3200 about 2.7 times as much; every VE3 app plays all
/// three.
const List<VoxVoiceMode> voxCodec2RecordModes = [
  VoxVoiceMode.mode1200,
  VoxVoiceMode.mode1600,
  VoxVoiceMode.mode3200,
];

/// Codec2 payload budget per raw packet. A raw push frame is at most 172
/// bytes: 4 bytes of push header + 6 bytes of voice header leaves 162; 156 is
/// the largest multiple of the 1200/2400 frame size under that and keeps
/// packets the standard VE3 size.
const int voxMaxCodecBytesPerPacket = 156;

/// Hard limits enforced by the parser (matching the VE3 field ranges).
const int voxMaxPackets = 255;
const int voxMaxDurationSeconds = 600;

const int voxVoicePacketMagic = 0x56; // 'V'
const int voxVoiceFetchMagic = 0x72; // 'r'
const int voxFetchFlagMissingOnly = 0x01;

/// VOX extension: the requester understands salted voice packets (0x57).
/// Plain VE3 implementations only look at bit 0, so they ignore this.
const int voxFetchFlagSaltOk = 0x02;

/// VOX extension: the request ends with `[len][path bytes]`, the route the
/// requester used to reach the sender (requester -> sender order). The
/// sender replies along the reverse, which is known to work right now,
/// instead of its own stored route (which can be stale or asymmetric).
const int voxFetchFlagHasPath = 0x04;

/// VOX extension: the request ends with one random byte. Radios drop any
/// packet whose payload they have already seen, so without it a retry asking
/// for the same missing packets is byte-identical to the last request and
/// never reaches the sender (its own radio heard the first one). Parsers
/// that don't know this flag ignore the trailing byte.
const int voxFetchFlagSalted = 0x08;

/// VOX extension: a voice packet with one random byte appended.
///
/// MeshCore radios drop any packet whose contents they have already seen
/// (the "seen" table hashes type + payload only). If a voice packet reaches
/// the listener's radio but is lost between radio and phone, every identical
/// resend is then silently dropped. A fresh salt byte on each send makes each
/// resend unique.
const int voxVoicePacketSaltedMagic = 0x57; // 'W'

/// 32-bit session id, held as 8 lowercase hex chars (big-endian bytes).
String voxNewSessionId([Random? rng]) {
  final r = rng ?? Random.secure();
  final v = (r.nextInt(1 << 16) << 16) | r.nextInt(1 << 16);
  return voxSessionIdFromInt(v);
}

String voxSessionIdFromInt(int value) =>
    (value & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0');

Uint8List voxSessionIdToBytes(String sid) {
  final out = Uint8List(4);
  for (var i = 0; i < 4; i++) {
    out[i] = int.parse(sid.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String voxSessionIdFromBytes(List<int> b, int offset) {
  final sb = StringBuffer();
  for (var i = 0; i < 4; i++) {
    sb.write(b[offset + i].toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

bool _isSessionId(String s) => RegExp(r'^[0-9a-f]{8}$').hasMatch(s);

String voxKey6Hex(List<int> publicKey) {
  final sb = StringBuffer();
  for (var i = 0; i < 6 && i < publicKey.length; i++) {
    sb.write(publicKey[i].toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

int? _parseBase36(String s) {
  if (s.isEmpty || s.length > 7 || !RegExp(r'^[0-9a-z]+$').hasMatch(s)) {
    return null;
  }
  return int.tryParse(s, radix: 36);
}

/// `VE3:` voice envelope carried as a normal text message.
class VoxVoiceEnvelope {
  /// Codec2 clips (standard VE3).
  static const String prefix = 'VE3:';

  /// Mimi clips (VOX only). Same fields as VE3.
  static const String mimiPrefix = 'VM1:';

  /// AV1 still images (VOX only). Same fields as VE3, but the last field is
  /// the aspect ratio (width * 100 / height) rather than a duration.
  static const String imagePrefix = 'VI1:';

  static String prefixFor(VoxVoiceMode mode) => mode.isImage
      ? imagePrefix
      : mode.isMimi
      ? mimiPrefix
      : prefix;

  final String sessionId;
  final VoxVoiceMode mode;
  final int totalPackets;
  final int durationSeconds;

  const VoxVoiceEnvelope({
    required this.sessionId,
    required this.mode,
    required this.totalPackets,
    required this.durationSeconds,
  });

  static bool looksLikeEnvelope(String text) =>
      text.startsWith(prefix) ||
      text.startsWith(mimiPrefix) ||
      text.startsWith(imagePrefix);

  static VoxVoiceEnvelope? tryParse(String text) {
    final t = text.trim();
    if (t.length < prefix.length) return null;
    final head = t.substring(0, prefix.length);
    if (head != prefix && head != mimiPrefix && head != imagePrefix) {
      return null;
    }
    final parts = t.substring(prefix.length).split(':');
    if (parts.length != 4) return null;
    final sidVal = _parseBase36(parts[0]);
    final modeId = _parseBase36(parts[1]);
    final total = _parseBase36(parts[2]);
    final dur = _parseBase36(parts[3]);
    if (sidVal == null || modeId == null || total == null || dur == null) {
      return null;
    }
    if (sidVal > 0xFFFFFFFF) return null;
    final mode = VoxVoiceMode.fromWireId(modeId);
    if (mode == null || prefixFor(mode) != head) return null;
    if (total < 1 || total > voxMaxPackets) return null;
    if (dur < 0 || dur > voxMaxDurationSeconds) return null;
    return VoxVoiceEnvelope(
      sessionId: voxSessionIdFromInt(sidVal),
      mode: mode,
      totalPackets: total,
      durationSeconds: dur,
    );
  }

  String encode() {
    final sid = int.parse(sessionId, radix: 16).toRadixString(36);
    return '${prefixFor(mode)}$sid:'
        '${mode.wireId.toRadixString(36)}:'
        '${totalPackets.toRadixString(36)}:'
        '${durationSeconds.toRadixString(36)}';
  }

  bool get isImage => mode.isImage;

  /// Image aspect ratio (width / height); 1 for audio or unknown.
  double get imageAspect =>
      isImage && durationSeconds > 0 ? durationSeconds / 100 : 1;

  /// Estimated payload bytes for the whole clip (for airtime display).
  int get estimatedCodecBytes => isImage
      ? totalPackets * mode.bytesPerPacket
      : min(
          totalPackets * mode.bytesPerPacket,
          max(durationSeconds, 1) * mode.bytesPerSecond,
        );
}

/// One raw voice packet: `[0x56][sid:4][index:1][codec2...]`.
class VoxVoicePacket {
  static const int headerLength = 6;

  final String sessionId;
  final int index;
  final Uint8List codecData;

  VoxVoicePacket({
    required this.sessionId,
    required this.index,
    required this.codecData,
  }) : assert(_isSessionId(sessionId)),
       assert(index >= 0 && index < voxMaxPackets);

  static bool isVoicePacket(List<int> payload) =>
      payload.isNotEmpty &&
      (payload[0] == voxVoicePacketMagic ||
          payload[0] == voxVoicePacketSaltedMagic);

  static VoxVoicePacket? tryParse(List<int> payload) {
    if (!isVoicePacket(payload)) return null;
    final salted = payload[0] == voxVoicePacketSaltedMagic;
    final end = salted ? payload.length - 1 : payload.length;
    if (end <= headerLength) return null;
    return VoxVoicePacket(
      sessionId: voxSessionIdFromBytes(payload, 1),
      index: payload[5],
      codecData: Uint8List.fromList(payload.sublist(headerLength, end)),
    );
  }

  /// Standard VE3 packet, or, with [salt], a VOX salted packet
  /// (`0x57`, one extra trailing byte) so resends are never deduplicated.
  Uint8List encode({int? salt}) {
    final extra = salt == null ? 0 : 1;
    final out = Uint8List(headerLength + codecData.length + extra);
    out[0] = salt == null ? voxVoicePacketMagic : voxVoicePacketSaltedMagic;
    out.setRange(1, 5, voxSessionIdToBytes(sessionId));
    out[5] = index;
    out.setRange(headerLength, headerLength + codecData.length, codecData);
    if (salt != null) out[out.length - 1] = salt & 0xFF;
    return out;
  }
}

/// Binary fetch request: `[0x72][sid:4][flags][key6:6][count][indices...]`,
/// then `[len][path]` with [voxFetchFlagHasPath] and `[salt]` with
/// [voxFetchFlagSalted].
class VoxVoiceFetchRequest {
  static const int minLength = 13;

  final String sessionId;
  final String requesterKey6; // 12 lowercase hex chars

  /// Null means "send every packet".
  final List<int>? missingIndices;

  /// Requester accepts salted (0x57) packets. Only VOX sets this.
  final bool saltOk;

  /// The route the requester used to reach the sender (requester -> sender),
  /// or null if not given. Empty means the requester reached us directly.
  final List<int>? requesterPath;

  const VoxVoiceFetchRequest({
    required this.sessionId,
    required this.requesterKey6,
    this.missingIndices,
    this.saltOk = false,
    this.requesterPath,
  });

  static VoxVoiceFetchRequest? tryParse(List<int> payload) {
    if (payload.length < minLength) return null;
    if (payload[0] != voxVoiceFetchMagic) return null;
    final flags = payload[5];
    final keySb = StringBuffer();
    for (var i = 6; i < 12; i++) {
      keySb.write(payload[i].toRadixString(16).padLeft(2, '0'));
    }
    final count = payload[12];
    List<int>? missing;
    if ((flags & voxFetchFlagMissingOnly) != 0) {
      if (payload.length < minLength + count) return null;
      missing = [
        for (var i = 0; i < count; i++)
          if (payload[minLength + i] < voxMaxPackets) payload[minLength + i],
      ];
    }
    List<int>? path;
    final pathAt = minLength + count;
    if ((flags & voxFetchFlagHasPath) != 0 && payload.length > pathAt) {
      final n = payload[pathAt];
      if (n <= 63 && payload.length >= pathAt + 1 + n) {
        path = payload.sublist(pathAt + 1, pathAt + 1 + n);
      }
    }
    return VoxVoiceFetchRequest(
      sessionId: voxSessionIdFromBytes(payload, 1),
      requesterKey6: keySb.toString(),
      missingIndices: missing,
      saltOk: (flags & voxFetchFlagSaltOk) != 0,
      requesterPath: path,
    );
  }

  /// With [salt], appends it so this request differs from any earlier one.
  Uint8List encode({int? salt}) {
    final missing = missingIndices == null
        ? const <int>[]
        : (missingIndices!
              .where((v) => v >= 0 && v < voxMaxPackets)
              .toSet()
              .toList()
            ..sort());
    // Keep the request inside one raw packet.
    final capped = missing.length > 140 ? missing.sublist(0, 140) : missing;
    final path = requesterPath;
    final pathBytes = path == null ? 0 : 1 + path.length;
    final saltBytes = salt == null ? 0 : 1;
    final out = Uint8List(minLength + capped.length + pathBytes + saltBytes);
    out[0] = voxVoiceFetchMagic;
    out.setRange(1, 5, voxSessionIdToBytes(sessionId));
    out[5] =
        (missingIndices == null ? 0x00 : voxFetchFlagMissingOnly) |
        (saltOk ? voxFetchFlagSaltOk : 0x00) |
        (path != null ? voxFetchFlagHasPath : 0x00) |
        (salt != null ? voxFetchFlagSalted : 0x00);
    for (var i = 0; i < 6; i++) {
      out[6 + i] = int.parse(
        requesterKey6.substring(i * 2, i * 2 + 2),
        radix: 16,
      );
    }
    out[12] = capped.length;
    out.setRange(minLength, minLength + capped.length, capped);
    if (path != null) {
      out[minLength + capped.length] = path.length;
      out.setRange(
        minLength + capped.length + 1,
        minLength + capped.length + 1 + path.length,
        path,
      );
    }
    if (salt != null) out[out.length - 1] = salt & 0xFF;
    return out;
  }
}

/// Splits a Codec2 bitstream into packets of whole frames.
List<VoxVoicePacket> voxPacketize(
  String sessionId,
  Uint8List codecBytes,
  VoxVoiceMode mode,
) {
  final per = mode.bytesPerPacket;
  final packets = <VoxVoicePacket>[];
  for (var off = 0, i = 0; off < codecBytes.length; off += per, i++) {
    if (i >= voxMaxPackets) break;
    final end = min(off + per, codecBytes.length);
    packets.add(
      VoxVoicePacket(
        sessionId: sessionId,
        index: i,
        codecData: Uint8List.fromList(codecBytes.sublist(off, end)),
      ),
    );
  }
  return packets;
}

/// Rough LoRa airtime for the whole clip, used for the "~N s on air" hint.
Duration voxEstimateAirtime({
  required int totalPackets,
  required int codecBytesPerPacket,
  required int spreadingFactor,
  required double bandwidthKhz,
  required int codingRate, // 5..8 for 4/5..4/8
  int pathLength = 0,
  int preambleSymbols = 8,
}) {
  if (totalPackets <= 0 || spreadingFactor <= 0 || bandwidthKhz <= 0) {
    return Duration.zero;
  }
  final payload =
      2 + pathLength + VoxVoicePacket.headerLength + codecBytesPerPacket;
  final tSym = pow(2, spreadingFactor) / (bandwidthKhz * 1000); // seconds
  final de = (spreadingFactor >= 11 && bandwidthKhz <= 125) ? 1 : 0;
  final cr = (codingRate.clamp(5, 8)) - 4;
  final num1 = 8 * payload - 4 * spreadingFactor + 28 + 16;
  final den = 4 * (spreadingFactor - 2 * de);
  final nPayload = 8 + max(((num1 / den).ceil()) * (cr + 4), 0);
  final perPacket = (preambleSymbols + 4.25 + nPayload) * tSym;
  return Duration(microseconds: (perPacket * totalPackets * 1e6).round());
}

/// `VR3:` text fetch request, sent as a DM when there is no direct route.
///
///   VR3:{sid}:{want}:{requesterKey6}
///
/// `sid` is base36, `want` is `a` (all) or `m` + compact base36 index ranges
/// (`m1-3.7` = 1, 2, 3, 7), `requesterKey6` is 12 hex chars. This is the
/// standard VE3 text fetch request. A flooded DM also makes both radios
/// learn a direct route to each other (path return + reciprocal path), which
/// the raw-data reply then uses.
class VoxVoiceTextRequest {
  static const String prefix = 'VR3:';

  static bool looksLikeRequest(String text) => text.startsWith(prefix);

  static VoxVoiceFetchRequest? tryParse(String text) {
    final t = text.trim();
    if (!t.startsWith(prefix)) return null;
    final parts = t.substring(prefix.length).split(':');
    if (parts.length != 3) return null;
    final sidVal = _parseBase36(parts[0]);
    if (sidVal == null || sidVal > 0xFFFFFFFF) return null;
    final key = parts[2].toLowerCase();
    if (!RegExp(r'^[0-9a-f]{12}$').hasMatch(key)) return null;
    final want = parts[1];
    List<int>? missing;
    if (want == 'a') {
      missing = null;
    } else if (want.startsWith('m') && want.length > 1) {
      missing = _decodeRanges(want.substring(1));
      if (missing == null || missing.isEmpty) return null;
    } else {
      return null;
    }
    return VoxVoiceFetchRequest(
      sessionId: voxSessionIdFromInt(sidVal),
      requesterKey6: key,
      missingIndices: missing,
    );
  }

  static String encode(VoxVoiceFetchRequest req) {
    final sid = int.parse(req.sessionId, radix: 16).toRadixString(36);
    final missing = req.missingIndices;
    final want = missing == null || missing.isEmpty
        ? 'a'
        : 'm${_encodeRanges(missing)}';
    return '$prefix$sid:$want:${req.requesterKey6.toLowerCase()}';
  }

  static String _encodeRanges(List<int> indices) {
    final sorted =
        indices.where((v) => v >= 0 && v < voxMaxPackets).toSet().toList()
          ..sort();
    final out = <String>[];
    var i = 0;
    while (i < sorted.length) {
      var j = i;
      while (j + 1 < sorted.length && sorted[j + 1] == sorted[j] + 1) {
        j++;
      }
      out.add(
        i == j
            ? sorted[i].toRadixString(36)
            : '${sorted[i].toRadixString(36)}-${sorted[j].toRadixString(36)}',
      );
      i = j + 1;
    }
    return out.join('.');
  }

  static List<int>? _decodeRanges(String s) {
    final out = <int>[];
    for (final tok in s.split('.')) {
      if (tok.isEmpty) continue;
      final ends = tok.split('-');
      if (ends.length > 2) return null;
      final a = _parseBase36(ends[0]);
      final b = ends.length == 2 ? _parseBase36(ends[1]) : a;
      if (a == null || b == null || a > b || b >= voxMaxPackets) return null;
      for (var v = a; v <= b; v++) {
        out.add(v);
      }
    }
    return out;
  }
}

/// GRP_DATA data type for VOX channel transfers. The payloads are the same
/// binary voice packets (0x56) and fetch requests (0x72) used on raw data,
/// flooded on the channel the envelope was posted in.
const int voxChannelDataType = 0x5643; // 'VC'

/// Largest GRP_DATA payload the companion protocol carries (172 - 9).
const int voxMaxChannelDataBytes = 163;

/// Fixed properties of the Mimi model VOX ships (see tool/vox/mimi_export.py).
class VoxMimiSpec {
  VoxMimiSpec._();

  static const int sampleRate = 24000;
  static const int frameSamples = 1920; // 80 ms
  static const int codebooks = 8;
  static const int bitsPerCode = 11;
  static const int bytesPerFrame = codebooks * bitsPerCode ~/ 8; // 11

  /// The ONNX graphs are exported for a fixed 20 s; shorter clips are padded
  /// with silence (Mimi is causal, so padding does not change earlier frames).
  static const int maxFrames = 250;
  static const int maxSamples = maxFrames * frameSamples; // 480000

  static int framesFor(int samples24k) =>
      min(maxFrames, (samples24k + frameSamples - 1) ~/ frameSamples);
}

/// Packs Mimi codes into 11 bytes per frame.
///
/// [codes] is the encoder output laid out `[codebook][frame]` with
/// [stride] frames per codebook row (the ONNX output is `[1, 8, 250]`).
/// Bits are written MSB first, frame by frame, codebook 0..7.
Uint8List voxPackMimiCodes(List<int> codes, int frames, {int? stride}) {
  final s = stride ?? frames;
  final out = Uint8List(frames * VoxMimiSpec.bytesPerFrame);
  var bitPos = 0;
  for (var f = 0; f < frames; f++) {
    for (var q = 0; q < VoxMimiSpec.codebooks; q++) {
      final v = codes[q * s + f] & 0x7FF;
      for (var b = VoxMimiSpec.bitsPerCode - 1; b >= 0; b--) {
        if ((v >> b) & 1 == 1) out[bitPos >> 3] |= 0x80 >> (bitPos & 7);
        bitPos++;
      }
    }
  }
  return out;
}

/// Inverse of [voxPackMimiCodes]. Returns `[codebook][frame]` codes with
/// [stride] frames per row (zero-filled past the clip), ready for the
/// decoder's `[1, 8, 250]` input.
Int64List voxUnpackMimiCodes(
  Uint8List bytes, {
  int stride = VoxMimiSpec.maxFrames,
}) {
  final frames = min(stride, bytes.length ~/ VoxMimiSpec.bytesPerFrame);
  final out = Int64List(VoxMimiSpec.codebooks * stride);
  var bitPos = 0;
  for (var f = 0; f < frames; f++) {
    for (var q = 0; q < VoxMimiSpec.codebooks; q++) {
      var v = 0;
      for (var b = 0; b < VoxMimiSpec.bitsPerCode; b++) {
        final bit = (bytes[bitPos >> 3] >> (7 - (bitPos & 7))) & 1;
        v = (v << 1) | bit;
        bitPos++;
      }
      out[q * stride + f] = v;
    }
  }
  return out;
}
