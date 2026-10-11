// MeshCore Open TAK - team wire formats added with the ATAK plugin
// (atak-plugin/). Same rules as team_wire.dart: one GRP_DATA blob of data
// type [teamChannelDataType] on the team channel, big-endian integers,
// key4 = first 4 bytes of the sender's public key.
//
//   point  [0x43][key4][itemId u32][op][flags][lat i32 1e7][lon i32 1e7]
//          [time u32] [hae i16]? [argb u32]? [type][callsign][remarks]
//          [iconset]? [attachMode][sid4][packets][extra u16]?
//          flags: 1 hae, 2 argb, 4 attachment, 8 iconset
//   shape  [0x47][key4][itemId u32][op][kind][flags][stroke argb u32]
//          [fill argb u32]? [time u32][width*2 u8][label][note]
//          [radius uvar m]? [n uvar][lat0 i32 1e6][lon0 i32 1e6]
//          [n-1 x (dlat zigzag-varint, dlon zigzag-varint) 1e6]
//   chunk  [0x58][key4][xferId u16][idx][total][body]
//          idx < total: data (<= 153 bytes); idx == total: XOR parity
//          [lenXor][xor of zero-padded bodies]. Reassembled payload:
//          [kind 1=CoT 2=file][flags bit0=deflated][crc16 u16][name][data]
//
// Strings are [len u8][utf8]. The Java side is
// atak-plugin/app/src/main/java/com/jadeonmesh/meshcore/atak/core/.

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'team_wire.dart';

const int teamMaxCotTypeBytes = 24;
const int teamMaxIconsetBytes = 48;

class _Wr {
  final BytesBuilder b = BytesBuilder();
  int get length => b.length;
  void u8(int v) => b.addByte(v & 0xFF);
  void u16(int v) {
    u8(v >> 8);
    u8(v);
  }

  void u32(int v) {
    u16((v >> 16) & 0xFFFF);
    u16(v & 0xFFFF);
  }

  void i32(int v) => u32(v & 0xFFFFFFFF);
  void i16(int v) => u16(v & 0xFFFF);
  void bytes(List<int> v) => b.add(v);
  void str(String s, int maxBytes) {
    final e = teamTruncateUtf8(s, maxBytes);
    u8(e.length);
    b.add(e);
  }

  void uvar(int v) {
    while (v >= 0x80) {
      u8((v & 0x7F) | 0x80);
      v >>= 7;
    }
    u8(v);
  }

  void svar(int v) => uvar(v >= 0 ? v << 1 : ((-v) << 1) - 1);
  Uint8List done() => b.toBytes();
}

class _Rd {
  final Uint8List d;
  int o = 0;
  _Rd(this.d);
  bool has(int n) => o + n <= d.length;
  int u8() {
    if (o >= d.length) throw const FormatException('short');
    return d[o++];
  }

  int u16() => (u8() << 8) | u8();
  int u32() => (u16() << 16) | u16();
  int i32() {
    final v = u32();
    return v >= 0x80000000 ? v - 0x100000000 : v;
  }

  int i16() {
    final v = u16();
    return v >= 0x8000 ? v - 0x10000 : v;
  }

  Uint8List take(int n) {
    if (!has(n)) throw const FormatException('short');
    final v = Uint8List.sublistView(d, o, o + n);
    o += n;
    return v;
  }

  String? str() {
    if (!has(1)) return null;
    final n = u8();
    if (!has(n)) return null;
    return utf8.decode(take(n), allowMalformed: true);
  }

  int uvar() {
    var v = 0, shift = 0;
    while (true) {
      final b = u8();
      v |= (b & 0x7F) << shift;
      if (b & 0x80 == 0) return v;
      shift += 7;
      if (shift > 56) throw const FormatException('varint');
    }
  }

  int svar() {
    final u = uvar();
    return (u & 1) == 0 ? u >> 1 : -((u + 1) >> 1);
  }
}

Uint8List _key4Bytes(String hex) => Uint8List.fromList([
  for (var i = 0; i < 4; i++)
    int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16),
]);

/// Dart's round() is what the Java side matches (halves away from zero).
int _deg7(double v) => (v * 1e7).round();

void _writeAttachment(_Wr w, TeamAttachment a) {
  w
    ..u8(a.modeWireId)
    ..bytes(_key4Bytes(a.sessionId))
    ..u8(a.packets)
    ..u16(a.extra);
}

TeamAttachment? _readAttachment(_Rd r) {
  if (!r.has(1)) return null;
  final mode = r.u8();
  if (mode == 0 || !r.has(7)) return null;
  return TeamAttachment(mode, teamKey4Hex(r.take(4)), r.u8(), r.u16());
}

// -------------------------------------------------------------------- point

/// Any single-point CoT item shared from ATAK: spot markers, waypoints,
/// MIL-STD-2525 units, SPIs. Keeps the CoT type so TAK clients see it as it
/// was sent.
class TeamPoint {
  final String authorKey4;
  final int itemId;
  final bool deleted;
  final double lat, lon;
  final int? haeM;
  final int? argb;
  final DateTime time;
  final String cotType;
  final String callsign;
  final String remarks;
  final String iconset;
  final TeamAttachment? attachment;

  const TeamPoint({
    required this.authorKey4,
    required this.itemId,
    required this.lat,
    required this.lon,
    required this.time,
    this.deleted = false,
    this.haeM,
    this.argb,
    this.cotType = '',
    this.callsign = '',
    this.remarks = '',
    this.iconset = '',
    this.attachment,
  });

  String get key => '$authorKey4:${itemId.toRadixString(16)}';

  /// Friendly / hostile / neutral / unknown from the CoT type ("a-h-G...").
  String get affiliationLetter =>
      cotType.length >= 3 && cotType.startsWith('a-') ? cotType[2] : '';

  Uint8List encode() {
    final hasIcon = iconset.isNotEmpty;
    final flags =
        (haeM != null ? 0x01 : 0) |
        (argb != null ? 0x02 : 0) |
        (attachment != null ? 0x04 : 0) |
        (hasIcon ? 0x08 : 0);
    final w = _Wr()
      ..u8(teamMsgPoint)
      ..bytes(_key4Bytes(authorKey4))
      ..u32(itemId)
      ..u8(deleted ? 1 : 0)
      ..u8(flags)
      ..i32(_deg7(lat))
      ..i32(_deg7(lon))
      ..u32(time.millisecondsSinceEpoch ~/ 1000);
    if (haeM != null) w.i16(haeM!.clamp(-32768, 32767));
    if (argb != null) w.i32(argb!);
    w
      ..str(cotType, teamMaxCotTypeBytes)
      ..str(callsign, teamMaxLabelBytes);
    final iconLen = hasIcon
        ? 1 +
              (utf8.encode(iconset).length < teamMaxIconsetBytes
                  ? utf8.encode(iconset).length
                  : teamMaxIconsetBytes)
        : 0;
    final tail = iconLen + (attachment != null ? 8 : 0);
    final room = (teamMaxPayload - w.length - 1 - tail).clamp(0, 120);
    w.str(remarks, room);
    if (hasIcon) w.str(iconset, teamMaxIconsetBytes);
    if (attachment != null) _writeAttachment(w, attachment!);
    return w.done();
  }

  static TeamPoint? tryParse(Uint8List p) {
    try {
      final r = _Rd(p);
      if (!r.has(23) || r.u8() != teamMsgPoint) return null;
      final key = teamKey4Hex(r.take(4));
      final id = r.u32();
      final op = r.u8();
      final flags = r.u8();
      final lat = r.i32() / 1e7, lon = r.i32() / 1e7;
      if (lat.abs() > 90 || lon.abs() > 180) return null;
      final t = DateTime.fromMillisecondsSinceEpoch(r.u32() * 1000);
      final hae = flags & 0x01 != 0 ? r.i16() : null;
      final argb = flags & 0x02 != 0 ? r.i32() : null;
      final type = r.str(), cs = r.str(), rem = r.str();
      if (type == null || cs == null || rem == null) return null;
      var icon = '';
      if (flags & 0x08 != 0) {
        final s = r.str();
        if (s == null) return null;
        icon = s;
      }
      final att = flags & 0x04 != 0 ? _readAttachment(r) : null;
      return TeamPoint(
        authorKey4: key,
        itemId: id,
        deleted: op == 1,
        lat: lat,
        lon: lon,
        time: t,
        haeM: hae,
        argb: argb,
        cotType: type,
        callsign: cs,
        remarks: rem,
        iconset: icon,
        attachment: att,
      );
    } on FormatException {
      return null;
    }
  }
}

// -------------------------------------------------------------------- shape

enum TeamShapeKind {
  polyline('Line'),
  polygon('Polygon'),
  rectangle('Rectangle'),
  circle('Circle'),
  route('Route');

  const TeamShapeKind(this.label);
  final String label;

  static TeamShapeKind fromIndex(int i) =>
      i >= 0 && i < values.length ? values[i] : polyline;
}

/// A drawn shape or route shared from ATAK.
class TeamShape {
  final String authorKey4;
  final int itemId;
  final bool deleted;
  final TeamShapeKind kind;
  final int strokeArgb;
  final int? fillArgb;
  final DateTime time;
  final double strokeWidth;
  final String label;
  final String note;

  /// Circles only.
  final int radiusM;

  /// (lat, lon); a circle has one point, its centre.
  final List<(double, double)> points;

  const TeamShape({
    required this.authorKey4,
    required this.itemId,
    required this.kind,
    required this.time,
    required this.points,
    this.deleted = false,
    this.strokeArgb = 0xFFFFFFFF,
    this.fillArgb,
    this.strokeWidth = 3,
    this.label = '',
    this.note = '',
    this.radiusM = 0,
  });

  String get key => '$authorKey4:${itemId.toRadixString(16)}';

  Uint8List encode() {
    final w = _Wr()
      ..u8(teamMsgShape)
      ..bytes(_key4Bytes(authorKey4))
      ..u32(itemId)
      ..u8(deleted ? 1 : 0)
      ..u8(kind.index)
      ..u8(fillArgb != null ? 0x01 : 0)
      ..i32(strokeArgb);
    if (fillArgb != null) w.i32(fillArgb!);
    w
      ..u32(time.millisecondsSinceEpoch ~/ 1000)
      ..u8((strokeWidth * 2).round().clamp(0, 255))
      ..str(label, teamMaxLabelBytes)
      ..str(note, teamMaxNoteBytes);
    if (kind == TeamShapeKind.circle) w.uvar(radiusM);
    w.uvar(points.length);
    var plat = 0, plon = 0;
    for (var i = 0; i < points.length; i++) {
      final la = (points[i].$1 * 1e6).round(), lo = (points[i].$2 * 1e6).round();
      if (i == 0) {
        w
          ..i32(la)
          ..i32(lo);
      } else {
        w
          ..svar(la - plat)
          ..svar(lo - plon);
      }
      plat = la;
      plon = lo;
    }
    return w.done();
  }

  static TeamShape? tryParse(Uint8List p) {
    try {
      final r = _Rd(p);
      if (!r.has(20) || r.u8() != teamMsgShape) return null;
      final key = teamKey4Hex(r.take(4));
      final id = r.u32();
      final op = r.u8();
      final kind = TeamShapeKind.fromIndex(r.u8());
      final flags = r.u8();
      final stroke = r.i32();
      final fill = flags & 0x01 != 0 ? r.i32() : null;
      final t = DateTime.fromMillisecondsSinceEpoch(r.u32() * 1000);
      final width = r.u8() / 2;
      final label = r.str(), note = r.str();
      if (label == null || note == null) return null;
      final radius = kind == TeamShapeKind.circle ? r.uvar() : 0;
      final n = r.uvar();
      if (n > 200) return null;
      final pts = <(double, double)>[];
      var la = 0, lo = 0;
      for (var i = 0; i < n; i++) {
        if (i == 0) {
          la = r.i32();
          lo = r.i32();
        } else {
          la += r.svar();
          lo += r.svar();
        }
        final lat = la / 1e6, lon = lo / 1e6;
        if (lat.abs() > 90 || lon.abs() > 180) return null;
        pts.add((lat, lon));
      }
      if (op != 1 && pts.isEmpty) return null;
      return TeamShape(
        authorKey4: key,
        itemId: id,
        deleted: op == 1,
        kind: kind,
        strokeArgb: stroke,
        fillArgb: fill,
        time: t,
        strokeWidth: width,
        label: label,
        note: note,
        radiusM: radius,
        points: pts,
      );
    } on FormatException {
      return null;
    }
  }
}

// ------------------------------------------------------------------- chunks

const int teamChunkHeader = 9;
const int teamChunkDataBody = teamMaxPayload - teamChunkHeader - 1; // 153
const int teamChunkMaxChunks = 32;

const int teamBlobKindCot = 1;
const int teamBlobKindFile = 2;

/// A reassembled transfer.
class TeamBlob {
  final String senderKey4;
  final int kind;
  final String name;
  final Uint8List data;
  const TeamBlob(this.senderKey4, this.kind, this.name, this.data);

  bool get isCot => kind == teamBlobKindCot;

  String get text => utf8.decode(data, allowMalformed: true);
}

/// CRC-16/CCITT-FALSE.
int teamCrc16(List<int> data) {
  var crc = 0xFFFF;
  for (final b in data) {
    crc ^= (b & 0xFF) << 8;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 0x8000) != 0
          ? ((crc << 1) ^ 0x1021) & 0xFFFF
          : (crc << 1) & 0xFFFF;
    }
  }
  return crc;
}

/// Unpacks a reassembled payload; null if damaged.
TeamBlob? teamUnpackBlob(String senderKey4, Uint8List payload) {
  try {
    final r = _Rd(payload);
    final kind = r.u8();
    final flags = r.u8();
    final crc = r.u16();
    final name = r.str();
    if (name == null) return null;
    final body = Uint8List.fromList(r.take(payload.length - r.o));
    if (teamCrc16(body) != crc) return null;
    final data = flags & 1 != 0
        ? Uint8List.fromList(Inflate(body).getBytes())
        : body;
    if (data.length > 64 * 1024) return null;
    return TeamBlob(senderKey4, kind, name, data);
  } catch (_) {
    return null;
  }
}

class _Partial {
  final int total;
  final List<Uint8List?> bodies;
  Uint8List? parity;
  int lenXor = 0;
  DateTime touched = DateTime.now();
  _Partial(this.total) : bodies = List.filled(total, null);
  int get have => bodies.where((b) => b != null).length;
}

/// Collects chunks from many senders; one lost chunk per transfer is
/// recovered from the parity chunk.
class TeamChunkReassembler {
  static const ttl = Duration(minutes: 10);
  final Map<String, _Partial> _parts = {};
  final Map<String, DateTime> _done = {};

  /// The finished transfer [chunk] completes, or null.
  TeamBlob? accept(Uint8List chunk) {
    if (chunk.length < teamChunkHeader || chunk[0] != teamMsgChunk) {
      return null;
    }
    final now = DateTime.now();
    _parts.removeWhere((_, p) => now.difference(p.touched) > ttl);
    _done.removeWhere((_, t) => now.difference(t) > ttl);
    final sender = teamKey4Hex(chunk, 1);
    final xfer = (chunk[5] << 8) | chunk[6];
    final idx = chunk[7], total = chunk[8];
    if (total < 1 || total > teamChunkMaxChunks || idx > total) return null;
    final key = '$sender/$xfer';
    if (_done.containsKey(key)) return null;
    var p = _parts[key];
    if (p == null || p.total != total) p = _parts[key] = _Partial(total);
    p.touched = now;
    final body = Uint8List.fromList(chunk.sublist(teamChunkHeader));
    if (idx == total) {
      if (body.isEmpty) return null;
      p.lenXor = body[0];
      p.parity = Uint8List.fromList(body.sublist(1));
    } else {
      if (body.length > teamChunkDataBody) return null;
      p.bodies[idx] = body;
    }
    if (p.have == total - 1 && p.parity != null) _recover(p);
    if (p.have < total) return null;
    _parts.remove(key);
    _done[key] = now;
    final out = BytesBuilder();
    for (final b in p.bodies) {
      out.add(b!);
    }
    return teamUnpackBlob(sender, out.toBytes());
  }

  static void _recover(_Partial p) {
    var missing = -1, lenXor = p.lenXor;
    final x = Uint8List(teamChunkDataBody)
      ..setRange(
        0,
        p.parity!.length.clamp(0, teamChunkDataBody),
        p.parity!,
      );
    for (var i = 0; i < p.total; i++) {
      final b = p.bodies[i];
      if (b == null) {
        missing = i;
        continue;
      }
      lenXor ^= b.length;
      for (var k = 0; k < b.length; k++) {
        x[k] ^= b[k];
      }
    }
    if (missing < 0 || lenXor > teamChunkDataBody) return;
    p.bodies[missing] = Uint8List.fromList(x.sublist(0, lenXor));
  }
}
