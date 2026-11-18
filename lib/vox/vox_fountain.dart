// MeshCore Open TAK - rateless repair packets for MediaMesh transfers
// (prototype).
//
// The block parity in vox_fec.dart mends a packet or two per block of 20.
// When listeners each miss different packets, every one of them has to ask
// for its own, and the answers and asks collide. A repair packet here is a
// random mix of *all* of a clip's packets, so any listener missing m packets
// gets them back from any m (or a few more) repair packets, whichever ones
// it heard and whichever packets it lacks. One answer of "N fresh repair
// packets" serves every listener at once.
//
// Wire: an ordinary voice packet, like parity
//     [0x56][rsid:4][seed][lastLen][repair: P bytes]
// - rsid = the clip's session id XOR 0x0F0DEC0D. Apps and standalones
//   without this see an unknown clip and drop it; radios route it as voice.
// - seed (0-254) picks the mix: repair = sum_i c(seed, i) * d_i over GF(256)
//   (0x11d), c from [voxFountainCoef], never 0. A sender counts seeds up so
//   no two of its repair packets are the same (radios drop repeats).
// - lastLen = the length of the clip's last packet; P = the full length,
//   data packets zero-padded to it.

import 'dart:typed_data';

import 'voice_wire.dart';

/// A repair packet's session id is the clip's XOR this.
const int voxFountainSidXor = 0x0F0DEC0D;

String voxFountainSid(String sid) =>
    voxSessionIdFromInt(int.parse(sid, radix: 16) ^ voxFountainSidXor);
String voxFountainDataSid(String repairSid) => voxFountainSid(repairSid);

/// Seeds go 0..254 and round again.
const int voxFountainSeeds = 255;

/// Repair packets for a listener missing [missing]: those and a margin, so a
/// lost repair packet or two still leaves enough.
int voxFountainNeeded(int missing) =>
    missing <= 0 ? 0 : missing + (missing * 15 + 99) ~/ 100 + 1;

/// Repair packets after a whole clip's first pass: about a tenth, at least 2.
int voxFountainFirstPass(int total) =>
    total < 2 ? 0 : (total + 9) ~/ 10 + 1;

// ---------------------------------------------------------------- GF(256)

final Uint8List _exp = () {
  final e = Uint8List(512);
  var x = 1;
  for (var i = 0; i < 255; i++) {
    e[i] = x;
    x <<= 1;
    if (x & 0x100 != 0) x ^= 0x11d;
  }
  for (var i = 255; i < 512; i++) {
    e[i] = e[i - 255];
  }
  return e;
}();

final Uint8List _log = () {
  final l = Uint8List(256);
  for (var i = 0; i < 255; i++) {
    l[_exp[i]] = i;
  }
  return l;
}();

int _mul(int a, int b) => a == 0 || b == 0 ? 0 : _exp[_log[a] + _log[b]];
int _inv(int a) => _exp[255 - _log[a]];

/// dst += c * src (src may be shorter: zero-padded).
void _addScaled(Uint8List dst, int c, Uint8List src) {
  if (c == 0) return;
  final lc = _log[c];
  final n = src.length < dst.length ? src.length : dst.length;
  for (var i = 0; i < n; i++) {
    final s = src[i];
    if (s != 0) dst[i] ^= _exp[lc + _log[s]];
  }
}

/// The coefficient of data packet [i] in repair packet [seed]: a hash of
/// both, never 0. Multiplies mod 2^16 (not shifts and XORs alone, which
/// would be linear and make many mixes unsolvable), small enough to be the
/// same on every platform the app runs on, web included. Checked in
/// scripts/vox/fountain_ref.py.
int voxFountainCoef(int seed, int i) {
  var x = (seed * 0x1F1 + i * 0x3B + 0x5A17) & 0xFFFF;
  for (var r = 0; r < 4; r++) {
    x = (x * 0x9E37 + 0x7F4B) & 0xFFFF;
    x ^= x >> 7;
  }
  final c = (x >> 3) & 0xFF;
  return c == 0 ? 1 + ((x >> 8) % 255) : c;
}

/// Repair packet [seed] for a clip's data [packets] (all of them), as a voice
/// packet's bytes ([VoxVoicePacket.headerLength] + 1 + P).
Uint8List voxFountainEncode(String sid, List<Uint8List> packets, int seed) {
  var p = 0;
  for (final d in packets) {
    if (d.length > p) p = d.length;
  }
  final pkt = Uint8List(VoxVoicePacket.headerLength + 1 + p);
  pkt[0] = voxVoicePacketMagic;
  pkt.setRange(1, 5, voxSessionIdToBytes(voxFountainSid(sid)));
  pkt[5] = seed % voxFountainSeeds;
  pkt[6] = packets.isEmpty ? 0 : packets.last.length;
  final out = Uint8List.sublistView(pkt, 7);
  for (var i = 0; i < packets.length; i++) {
    _addScaled(out, voxFountainCoef(seed % voxFountainSeeds, i), packets[i]);
  }
  return pkt;
}

/// The missing packets of a [total]-packet clip, from what's [present] and
/// the [repairs] heard (seed -> `[lastLen][repair...]`, a repair packet's
/// codec data). Empty until there are enough repairs for every packet
/// missing (and the mix of them solves, which it nearly always does).
Map<int, Uint8List> voxFountainRebuild({
  required int total,
  required Map<int, Uint8List> present,
  required Map<int, Uint8List> repairs,
}) {
  final miss = [
    for (var i = 0; i < total; i++)
      if (!present.containsKey(i)) i,
  ];
  final m = miss.length;
  if (m == 0 || repairs.length < m) return const {};
  final rows = repairs.entries.where((e) => e.value.length >= 2).toList();
  if (rows.length < m) return const {};
  final p = rows.first.value.length - 1;
  final lastLen = rows.first.value[0];
  if (rows.any((r) => r.value.length - 1 != p)) return const {};
  // Each repair less what the packets present put in it, as an equation in
  // the missing ones.
  final a = <Uint8List>[];
  final rhs = <Uint8List>[];
  for (final r in rows) {
    final seed = r.key;
    final v = Uint8List.fromList(r.value.sublist(1));
    for (final e in present.entries) {
      if (e.key < total) _addScaled(v, voxFountainCoef(seed, e.key), e.value);
    }
    rhs.add(v);
    a.add(Uint8List.fromList([for (final i in miss) voxFountainCoef(seed, i)]));
  }
  // Gaussian elimination, picking any row with a non-zero pivot.
  final n = rows.length;
  for (var c = 0; c < m; c++) {
    var piv = -1;
    for (var r = c; r < n; r++) {
      if (a[r][c] != 0) {
        piv = r;
        break;
      }
    }
    if (piv < 0) return const {};
    if (piv != c) {
      final ta = a[c];
      a[c] = a[piv];
      a[piv] = ta;
      final tr = rhs[c];
      rhs[c] = rhs[piv];
      rhs[piv] = tr;
    }
    final iv = _inv(a[c][c]);
    for (var k = 0; k < m; k++) {
      a[c][k] = _mul(a[c][k], iv);
    }
    final scaled = Uint8List(p);
    _addScaled(scaled, iv, rhs[c]);
    rhs[c] = scaled;
    for (var r = 0; r < n; r++) {
      if (r == c) continue;
      final f = a[r][c];
      if (f == 0) continue;
      for (var k = 0; k < m; k++) {
        a[r][k] ^= _mul(f, a[c][k]);
      }
      _addScaled(rhs[r], f, rhs[c]);
    }
  }
  final out = <int, Uint8List>{};
  for (var j = 0; j < m; j++) {
    final i = miss[j];
    out[i] = i == total - 1 && lastLen > 0 && lastLen <= p
        ? Uint8List.fromList(rhs[j].sublist(0, lastLen))
        : rhs[j];
  }
  return out;
}
