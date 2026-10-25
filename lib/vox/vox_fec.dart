// MeshCore Open TAK - forward error correction for photos and voice.
//
// A few parity packets go out after a clip's packets when it's sent to
// everyone at once (a channel push, or a request for the whole clip). A
// listener that lost a few packets rebuilds them itself, with no request: a
// lost packet on a 2-3 hop clip used to cost minutes of repair requests.
//
// Wire (the same in Wadamesh TAK's VoxFec.h; scripts/vox/fec_ref.py is the
// reference both are tested against, test/vox/data/fec_vectors.txt):
// a parity packet is an ordinary VE3 voice packet
//     [0x56][psid:4][info][lastLen][parity: P bytes]
// - psid = the clip's session id XOR 0xFEC0FEC0. Apps and standalones without
//   FEC see an unknown clip and drop it; radios route it as voice (radio2).
// - info = block * 8 + j: parity j of block `block`. Block b covers packets
//   [20b, 20b + 20), the last one shorter.
// - lastLen = the length of the clip's last packet (the only short one).
// - P = the clip's full packet length; data packets are zero-padded to it.
// Parity j of a block is sum_i c(j, i) * d_i over GF(256) (0x11d), with
// c(j, i) = 1 / ((0x80 | j) ^ i): a Cauchy matrix, so any e lost packets of a
// block come back from any e of its parity packets.

import 'dart:typed_data';

import 'voice_wire.dart';

/// Data packets per FEC block.
const int voxFecBlock = 20;

/// A parity packet's session id is the clip's XOR this.
const int voxFecSidXor = 0xFEC0FEC0;

/// The session id parity packets for clip [sid] carry, and back.
String voxFecParitySid(String sid) => voxSessionIdFromInt(
  int.parse(sid, radix: 16) ^ voxFecSidXor,
);
String voxFecDataSid(String paritySid) => voxFecParitySid(paritySid);

/// Parity packets for a block of [k] data packets: voice gets more (a clip
/// is short, and every packet is a second of speech); photos about 10%.
int voxFecParityCount(int k, {required bool image}) {
  if (k <= 1) return 0;
  if (image) return k >= 6 ? 2 : 1;
  return k >= 8 ? 3 : (k >= 4 ? 2 : 1);
}

/// All parity packets for a clip, after all its data (in all-at-once sends).
int voxFecTotalParity(int total, {required bool image}) {
  var n = 0;
  for (var lo = 0; lo < total; lo += voxFecBlock) {
    n += voxFecParityCount(
      (total - lo) < voxFecBlock ? total - lo : voxFecBlock,
      image: image,
    );
  }
  return n;
}

// ---------------------------------------------------------------- GF(256)

final Uint8List _exp = () {
  final e = Uint8List(512);
  var x = 1;
  for (var i = 0; i < 255; i++) {
    e[i] = x;
    x <<= 1;
    if ((x & 0x100) != 0) x ^= 0x11D;
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
int _coef(int j, int i) => _inv((0x80 | j) ^ i);

/// `acc ^= c * src` byte by byte (src may be shorter: zero padding).
void _addScaled(Uint8List acc, int c, List<int> src) {
  if (c == 0) return;
  final lc = _log[c];
  final n = src.length < acc.length ? src.length : acc.length;
  for (var t = 0; t < n; t++) {
    final s = src[t];
    if (s != 0) acc[t] ^= _exp[lc + _log[s]];
  }
}

// ----------------------------------------------------------------- encode

/// The parity packets (encoded payloads) for clip [sid] made of [packets]
/// (each one's codec bytes, in order).
List<Uint8List> voxFecEncode(
  String sid,
  List<Uint8List> packets, {
  required bool image,
}) {
  final n = packets.length;
  if (n < 2) return const [];
  var p = 0;
  for (final d in packets) {
    if (d.length > p) p = d.length;
  }
  final lastLen = packets.last.length;
  final psid = voxSessionIdToBytes(voxFecParitySid(sid));
  final out = <Uint8List>[];
  for (var b = 0; b * voxFecBlock < n; b++) {
    final lo = b * voxFecBlock;
    final hi = (lo + voxFecBlock) < n ? lo + voxFecBlock : n;
    final m = voxFecParityCount(hi - lo, image: image);
    for (var j = 0; j < m; j++) {
      final pkt = Uint8List(VoxVoicePacket.headerLength + 1 + p);
      pkt[0] = voxVoicePacketMagic;
      pkt.setRange(1, 5, psid);
      pkt[5] = b * 8 + j;
      pkt[6] = lastLen;
      final par = Uint8List.sublistView(pkt, 7);
      for (var i = lo; i < hi; i++) {
        _addScaled(par, _coef(j, i - lo), packets[i]);
      }
      out.add(pkt);
    }
  }
  return out;
}

// ---------------------------------------------------------------- rebuild

/// Data packets of a [total]-packet clip rebuilt from what's [present] and
/// the [parity] packets heard: info byte -> `[lastLen][parity...]` (a parity
/// packet's codec data). Only blocks with no more packets missing than
/// parity packets heard come back; the rest wait for more.
Map<int, Uint8List> voxFecRebuild({
  required int total,
  required Map<int, Uint8List> present,
  required Map<int, Uint8List> parity,
}) {
  final out = <int, Uint8List>{};
  if (parity.isEmpty) return out;
  for (var b = 0; b * voxFecBlock < total; b++) {
    final lo = b * voxFecBlock;
    final hi = (lo + voxFecBlock) < total ? lo + voxFecBlock : total;
    final miss = [
      for (var i = lo; i < hi; i++)
        if (!present.containsKey(i)) i,
    ];
    if (miss.isEmpty) continue;
    final pars = [
      for (final e in parity.entries)
        if (e.key >> 3 == b && e.value.length >= 2) (e.key & 7, e.value),
    ]..sort((a, c) => a.$1.compareTo(c.$1));
    if (pars.length < miss.length) continue;
    final use = pars.sublist(0, miss.length);
    final p = use.first.$2.length - 1;
    final lastLen = use.first.$2[0];
    if (use.any((u) => u.$2.length - 1 != p)) continue;
    final e = miss.length;
    // rhs_r = parity_r minus what the present packets put in it.
    final rhs = <Uint8List>[];
    for (final (j, v) in use) {
      final r = Uint8List.fromList(v.sublist(1));
      for (var i = lo; i < hi; i++) {
        final d = present[i];
        if (d != null) _addScaled(r, _coef(j, i - lo), d);
      }
      rhs.add(r);
    }
    final a = [
      for (final (j, _) in use) [for (final i in miss) _coef(j, i - lo)],
    ];
    // Gauss-Jordan; a Cauchy matrix's square parts are all invertible.
    var ok = true;
    for (var c = 0; c < e && ok; c++) {
      var piv = -1;
      for (var r = c; r < e; r++) {
        if (a[r][c] != 0) {
          piv = r;
          break;
        }
      }
      if (piv < 0) {
        ok = false;
        break;
      }
      if (piv != c) {
        final ta = a[c];
        a[c] = a[piv];
        a[piv] = ta;
        final tr = rhs[c];
        rhs[c] = rhs[piv];
        rhs[piv] = tr;
      }
      final iv = _inv(a[c][c]);
      a[c] = [for (final v in a[c]) _mul(v, iv)];
      final scaled = Uint8List(p);
      _addScaled(scaled, iv, rhs[c]);
      rhs[c] = scaled;
      for (var r = 0; r < e; r++) {
        if (r == c || a[r][c] == 0) continue;
        final f = a[r][c];
        for (var k = 0; k < e; k++) {
          a[r][k] ^= _mul(f, a[c][k]);
        }
        _addScaled(rhs[r], f, rhs[c]);
      }
    }
    if (!ok) continue;
    for (var k = 0; k < e; k++) {
      final i = miss[k];
      out[i] = i == total - 1 && lastLen <= p
          ? Uint8List.fromList(rhs[k].sublist(0, lastLen))
          : rhs[k];
    }
  }
  return out;
}
