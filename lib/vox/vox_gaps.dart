// MeshCore Open TAK - playing a voice clip that's still missing a packet or
// two. Codec2 has no state worth keeping across a gap, so the clip decodes in
// runs of packets that are here, with silence the length of a packet for each
// one that isn't. When the rest arrive, the whole clip plays as usual.

import 'dart:typed_data';

import 'voice_wire.dart';

/// Share of a voice clip's packets that must be here to play it with gaps.
const double voxPartialPlayShare = 0.8;

/// When a clip that was asked for stalls with at least this share, it plays
/// with gaps on its own (a tap at [voxPartialPlayShare] does too).
const double voxPartialAutoShare = 0.85;

/// Whether a Codec2 clip with [received] of [total] packets can play now.
bool voxCanPlayPartial(VoxVoiceMode mode, int received, int total) =>
    mode.isCodec2 &&
    total >= 2 &&
    received < total &&
    received >= 1 &&
    received >= (total * voxPartialPlayShare).ceil();

/// One stretch of a partly received clip: codec bytes to decode, or
/// [silenceSamples] of silence where packets are missing.
class VoxGapSegment {
  const VoxGapSegment.bits(Uint8List this.bits) : silenceSamples = 0;
  const VoxGapSegment.silence(this.silenceSamples) : bits = null;
  final Uint8List? bits;
  final int silenceSamples;
}

/// The clip as runs of packets here and silences for those missing. A
/// missing packet is a full packet's worth (a missing last one too: its
/// length isn't known, and trailing silence is harmless).
List<VoxGapSegment> voxGapPlan(
  Map<int, Uint8List> present,
  int total,
  VoxVoiceMode mode,
) {
  final out = <VoxGapSegment>[];
  final perPacket = mode.framesPerPacket * mode.samplesPerFrame;
  BytesBuilder? run;
  var silence = 0;
  void flushRun() {
    if (run != null && run!.length > 0) {
      out.add(VoxGapSegment.bits(run!.toBytes()));
    }
    run = null;
  }

  void flushSilence() {
    if (silence > 0) out.add(VoxGapSegment.silence(silence));
    silence = 0;
  }

  for (var i = 0; i < total; i++) {
    final p = present[i];
    if (p == null) {
      flushRun();
      silence += perPacket;
    } else {
      flushSilence();
      (run ??= BytesBuilder(copy: false)).add(p);
    }
  }
  flushRun();
  flushSilence();
  return out;
}
