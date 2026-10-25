import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/vox/vox_fec.dart';
import 'package:meshcore_open/vox/voice_wire.dart';

/// Data packet i of a vector case: scripts/vox/fec_ref.py's lcg_bytes.
Uint8List _lcg(int seed, int n) {
  final out = Uint8List(n);
  var s = seed;
  for (var i = 0; i < n; i++) {
    s = (s * 1103515245 + 12345) & 0x7FFFFFFF;
    out[i] = (s >> 16) & 0xFF;
  }
  return out;
}

String _hex(List<int> b) =>
    b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();

class _Case {
  _Case(this.sid, this.n, this.size, this.last, this.image);
  final int sid, n, size, last;
  final bool image;
  final List<String> parity = [];
  List<Uint8List> packets() => [
    for (var i = 0; i < n; i++) _lcg(sid + i, i < n - 1 ? size : last),
  ];
  String get sidHex => voxSessionIdFromInt(sid);
}

List<_Case> _vectors() {
  final cases = <_Case>[];
  for (final line in File('test/vox/data/fec_vectors.txt').readAsLinesSync()) {
    if (line.startsWith('#') || line.trim().isEmpty) continue;
    final f = line.split(' ');
    if (f[0] == 'case') {
      cases.add(
        _Case(
          int.parse(f[3], radix: 16),
          int.parse(f[5]),
          int.parse(f[7]),
          int.parse(f[9]),
          f[11] == '1',
        ),
      );
    } else {
      cases[int.parse(f[0])].parity.add(f[1]);
    }
  }
  return cases;
}

void main() {
  final cases = _vectors();

  test('vectors load', () => expect(cases.length, 3));

  for (final c in cases) {
    test('parity of ${c.sidHex} matches the reference byte for byte', () {
      final par = voxFecEncode(c.sidHex, c.packets(), image: c.image);
      expect(par.map(_hex).toList(), c.parity);
      expect(par.length, voxFecTotalParity(c.n, image: c.image));
    });

    test('${c.sidHex}: any loss within the parity count comes back', () {
      final pk = c.packets();
      final par = voxFecEncode(c.sidHex, pk, image: c.image);
      final pmap = <int, Uint8List>{
        for (final p in par)
          VoxVoicePacket.tryParse(p)!.index: VoxVoicePacket.tryParse(
            p,
          )!.codecData,
      };
      final rng = Random(7);
      for (var trial = 0; trial < 200; trial++) {
        final lost = <int>{};
        for (var lo = 0; lo < c.n; lo += voxFecBlock) {
          final hi = min(c.n, lo + voxFecBlock);
          final m = voxFecParityCount(hi - lo, image: c.image);
          final k = rng.nextInt(m + 1);
          final pool = [for (var i = lo; i < hi; i++) i]..shuffle(rng);
          lost.addAll(pool.take(k));
        }
        final present = {
          for (var i = 0; i < c.n; i++)
            if (!lost.contains(i)) i: pk[i],
        };
        final got = voxFecRebuild(total: c.n, present: present, parity: pmap);
        expect(got.keys.toSet(), lost);
        for (final i in lost) {
          expect(got[i], pk[i], reason: 'packet $i');
        }
      }
    });
  }

  test('too many lost in a block: nothing made up', () {
    final c = cases.first; // 11 packets, 3 parity
    final pk = c.packets();
    final par = voxFecEncode(c.sidHex, pk, image: false);
    final pmap = {
      for (final p in par)
        VoxVoicePacket.tryParse(p)!.index: VoxVoicePacket.tryParse(
          p,
        )!.codecData,
    };
    final present = {
      for (var i = 4; i < c.n; i++) i: pk[i],
    }; // 4 lost, 3 parity
    expect(voxFecRebuild(total: c.n, present: present, parity: pmap), isEmpty);
  });

  test('parity packets look like voice packets of another clip', () {
    final c = cases.first;
    final par = voxFecEncode(c.sidHex, c.packets(), image: false);
    final p = VoxVoicePacket.tryParse(par.first)!;
    expect(p.sessionId, voxFecParitySid(c.sidHex));
    expect(voxFecDataSid(p.sessionId), c.sidHex);
    expect(par.first.length, lessThanOrEqualTo(voxMaxChannelDataBytes));
    expect(par.first[0], voxVoicePacketMagic);
  });

  test('parity counts', () {
    expect(voxFecParityCount(1, image: false), 0);
    expect(voxFecParityCount(3, image: false), 1);
    expect(voxFecParityCount(7, image: false), 2);
    expect(voxFecParityCount(11, image: false), 3);
    expect(voxFecParityCount(20, image: true), 2);
    expect(voxFecTotalParity(230, image: true), 24);
  });
}
