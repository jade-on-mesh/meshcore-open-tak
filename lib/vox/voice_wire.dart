// MeshCore Open VOX - voice message wire formats.
//
// Written from scratch for MeshCore Open VOX. The on-air formats follow the
// publicly documented MeshCore SAR voice design (docs/voice-mode-technical.md
// in dz0ny/meshcore-sar) so VOX can exchange voice messages with SAR users:
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

  static const int sampleRateHz = 8000;

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

/// The mode VOX records in. 1200 bps keeps a 10 s clip to 10 packets.
const VoxVoiceMode voxDefaultVoiceMode = VoxVoiceMode.mode1200;

/// Codec2 payload budget per raw packet. A raw push frame is at most 172
/// bytes: 4 bytes of push header + 6 bytes of voice header leaves 162; 156 is
/// the largest multiple of the 1200/2400 frame size under that and keeps
/// packets the same size SAR sends.
const int voxMaxCodecBytesPerPacket = 156;

/// Hard limits enforced by the parser (matching the VE3 field ranges).
const int voxMaxPackets = 255;
const int voxMaxDurationSeconds = 600;

const int voxVoicePacketMagic = 0x56; // 'V'
const int voxVoiceFetchMagic = 0x72; // 'r'
const int voxFetchFlagMissingOnly = 0x01;

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
  static const String prefix = 'VE3:';

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

  static bool looksLikeEnvelope(String text) => text.startsWith(prefix);

  static VoxVoiceEnvelope? tryParse(String text) {
    final t = text.trim();
    if (!t.startsWith(prefix)) return null;
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
    if (mode == null) return null;
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
    return '$prefix$sid:${mode.wireId.toRadixString(36)}:'
        '${totalPackets.toRadixString(36)}:'
        '${durationSeconds.toRadixString(36)}';
  }

  /// Estimated payload bytes for the whole clip (for airtime display).
  int get estimatedCodecBytes => min(
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

  static VoxVoicePacket? tryParse(List<int> payload) {
    if (payload.length <= headerLength) return null;
    if (payload[0] != voxVoicePacketMagic) return null;
    return VoxVoicePacket(
      sessionId: voxSessionIdFromBytes(payload, 1),
      index: payload[5],
      codecData: Uint8List.fromList(payload.sublist(headerLength)),
    );
  }

  Uint8List encode() {
    final out = Uint8List(headerLength + codecData.length);
    out[0] = voxVoicePacketMagic;
    out.setRange(1, 5, voxSessionIdToBytes(sessionId));
    out[5] = index;
    out.setRange(headerLength, out.length, codecData);
    return out;
  }
}

/// Binary fetch request: `[0x72][sid:4][flags][key6:6][count][indices...]`.
class VoxVoiceFetchRequest {
  static const int minLength = 13;

  final String sessionId;
  final String requesterKey6; // 12 lowercase hex chars

  /// Null means "send every packet".
  final List<int>? missingIndices;

  const VoxVoiceFetchRequest({
    required this.sessionId,
    required this.requesterKey6,
    this.missingIndices,
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
    return VoxVoiceFetchRequest(
      sessionId: voxSessionIdFromBytes(payload, 1),
      requesterKey6: keySb.toString(),
      missingIndices: missing,
    );
  }

  Uint8List encode() {
    final missing = missingIndices == null
        ? const <int>[]
        : (missingIndices!
              .where((v) => v >= 0 && v < voxMaxPackets)
              .toSet()
              .toList()
            ..sort());
    // Keep the request inside one raw packet.
    final capped = missing.length > 150 ? missing.sublist(0, 150) : missing;
    final out = Uint8List(minLength + capped.length);
    out[0] = voxVoiceFetchMagic;
    out.setRange(1, 5, voxSessionIdToBytes(sessionId));
    out[5] = missingIndices == null ? 0x00 : voxFetchFlagMissingOnly;
    for (var i = 0; i < 6; i++) {
      out[6 + i] = int.parse(
        requesterKey6.substring(i * 2, i * 2 + 2),
        radix: 16,
      );
    }
    out[12] = capped.length;
    out.setRange(minLength, out.length, capped);
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
  final perPacket = (8 + 4.25 + nPayload) * tSym;
  return Duration(microseconds: (perPacket * totalPackets * 1e6).round());
}
