// MeshCore Open TAK - Remote ID (ASTM F3411 / Open Drone ID) for the drone
// detector: the phone hears drones' Bluetooth broadcasts (service data
// 0xFFFA), keeps one track per drone, and writes the channel post both Watch
// feeds read (watch_feed.dart, Wadamesh TAK's WatchFeed.h):
//
//   DRONE 1581F9DEV26590296G6G h120m 7.0m/s hdg90
//   https://maps.google.com/?q=47.60378,-122.34052
//   Op https://maps.google.com/?q=47.60531,-122.34016
//
// Written from the F3411 message layout; Wadamesh TAK's standalones decode
// the same broadcasts with GridDown Secure Messenger's parser, and both write
// these posts byte for byte (test/team/remote_id_test.dart and Wadamesh's
// test/test_drone_core.cpp check the same strings).

import 'dart:math' as math;
import 'dart:typed_data';

/// 16-bit service UUID of Remote ID's Bluetooth broadcasts (ASTM).
const int remoteIdServiceUuid16 = 0xFFFA;

/// The application code before each message in that service data.
const int remoteIdAppCode = 0x0D;

const int remoteIdMessageSize = 25;

/// A track not heard for this long shows as stale; for [remoteIdExpire] it is
/// dropped.
const Duration remoteIdStale = Duration(minutes: 1);
const Duration remoteIdExpire = Duration(minutes: 5);

/// Posts: each drone at most once a minute, and again only after moving this far.
const Duration remoteIdPostInterval = Duration(minutes: 1);
const double remoteIdPostMoveM = 200;

const List<String> remoteIdUaTypes = [
  'Undeclared',
  'Aeroplane',
  'Rotorcraft',
  'Gyroplane',
  'Hybrid VTOL',
  'Ornithopter',
  'Glider',
  'Kite',
  'Free balloon',
  'Captive balloon',
  'Airship',
  'Parachute',
  'Rocket',
  'Tethered',
  'Ground obstacle',
];

String remoteIdUaTypeName(int t) =>
    t >= 0 && t < remoteIdUaTypes.length ? remoteIdUaTypes[t] : 'Other';

/// What one broadcast said. Null fields: not in it.
class RemoteIdObservation {
  String? uasId;
  int? idType;
  int? uaType;
  double? lat, lon;
  int heightAglM = 0; // 0: unknown (as in F3411's encoding)
  int altGeoM = 0;
  int speedCms = 0;
  int headingDeg = 0;
  int vertSpeedCms = 0;
  double? opLat, opLon;
  String? operatorId;
  String? description;

  bool get hasPosition => lat != null && lon != null;
}

int _i32(Uint8List b, int o) => ByteData.sublistView(b).getInt32(o, Endian.little);
int _u16(Uint8List b, int o) => ByteData.sublistView(b).getUint16(o, Endian.little);

/// A fixed-width text field: printable ASCII up to the first NUL, trimmed.
String _text(Uint8List b, int o, int n) {
  final out = StringBuffer();
  for (var i = o; i < o + n && i < b.length; i++) {
    final c = b[i];
    if (c == 0) break;
    if (c >= 0x20 && c <= 0x7E) out.writeCharCode(c);
  }
  return out.toString().trimRight();
}

(double, double)? _latLon(Uint8List m, int o) {
  final la = _i32(m, o), lo = _i32(m, o + 4);
  if (la == 0 && lo == 0) return null; // unknown
  final lat = la * 1e-7, lon = lo * 1e-7;
  if (lat.abs() > 90 || lon.abs() > 180) return null;
  return (lat, lon);
}

/// Applies one 25-byte message to [o]. False for a type it doesn't know.
bool _applyMessage(Uint8List m, RemoteIdObservation o) {
  switch (m[0] >> 4) {
    case 0x0: // Basic ID
      o.idType = m[1] >> 4;
      o.uaType = m[1] & 0x0F;
      final id = _text(m, 2, 20);
      if (id.isNotEmpty) o.uasId = id;
      return true;
    case 0x1: // Location / vector
      final flags = m[1];
      final dir = m[2] + ((flags & 0x02) != 0 ? 180 : 0);
      o.headingDeg = dir % 360;
      final raw = m[3];
      o.speedCms = (flags & 0x01) == 0 ? raw * 25 : raw * 75 + 255 * 25;
      o.vertSpeedCms = (m[4] >= 128 ? m[4] - 256 : m[4]) * 50;
      final p = _latLon(m, 5);
      if (p != null) {
        o.lat = p.$1;
        o.lon = p.$2;
      }
      final geo = _u16(m, 15), hgt = _u16(m, 17);
      if (geo != 0) o.altGeoM = geo ~/ 2 - 1000;
      if (hgt != 0) o.heightAglM = hgt ~/ 2 - 1000;
      return true;
    case 0x2: // Authentication
      return true;
    case 0x3: // Self ID
      final d = _text(m, 2, 23);
      if (d.isNotEmpty) o.description = d;
      return true;
    case 0x4: // System: where the operator is
      final p = _latLon(m, 2);
      if (p != null) {
        o.opLat = p.$1;
        o.opLon = p.$2;
      }
      return true;
    case 0x5: // Operator ID
      final id = _text(m, 2, 20);
      if (id.isNotEmpty) o.operatorId = id;
      return true;
  }
  return false;
}

/// A single message or a Message Pack (type 0xF: size 25, up to 10 of them),
/// or null when nothing in it is understood.
RemoteIdObservation? parseRemoteIdPayload(Uint8List p) {
  final o = RemoteIdObservation();
  var applied = 0;
  if (p.isNotEmpty && (p[0] >> 4) == 0xF) {
    if (p.length < 3 || p[1] != remoteIdMessageSize) return null;
    final n = p[2];
    if (n == 0 || n > 10 || 3 + n * remoteIdMessageSize > p.length) return null;
    for (var i = 0; i < n; i++) {
      final s = 3 + i * remoteIdMessageSize;
      if (_applyMessage(p.sublist(s, s + remoteIdMessageSize), o)) applied++;
    }
  } else if (p.length >= remoteIdMessageSize) {
    if (_applyMessage(p.sublist(0, remoteIdMessageSize), o)) applied++;
  }
  return applied > 0 ? o : null;
}

/// Bluetooth service data for 0xFFFA: `[0x0D][counter][message or pack]`.
RemoteIdObservation? parseRemoteIdServiceData(List<int> data) {
  if (data.length < 2 + remoteIdMessageSize || data[0] != remoteIdAppCode) {
    return null;
  }
  return parseRemoteIdPayload(Uint8List.fromList(data.sublist(2)));
}

/// One drone.
class RemoteIdTrack {
  RemoteIdTrack(this.uasId, this.firstSeen) : lastSeen = firstSeen;

  final String uasId;
  int idType = 0;
  int uaType = 0;
  double? lat, lon;
  int heightAglM = 0, altGeoM = 0, speedCms = 0, headingDeg = 0, vertSpeedCms = 0;
  double? opLat, opLon;
  String? operatorId;
  String? description;
  int rssi = 0;
  final DateTime firstSeen;
  DateTime lastSeen;
  int messages = 0;

  /// When it was last posted, and where it was then.
  DateTime? postedAt;
  double? postedLat, postedLon;

  bool get hasPosition => lat != null && lon != null;
  bool get hasOperator => opLat != null && opLon != null;
  bool isStale(DateTime now) => now.difference(lastSeen) > remoteIdStale;

  void _merge(RemoteIdObservation o, int rssi, DateTime now) {
    if (o.idType != null) idType = o.idType!;
    if (o.uaType != null) uaType = o.uaType!;
    if (o.hasPosition) {
      lat = o.lat;
      lon = o.lon;
      heightAglM = o.heightAglM;
      altGeoM = o.altGeoM;
      speedCms = o.speedCms;
      headingDeg = o.headingDeg;
      vertSpeedCms = o.vertSpeedCms;
    }
    if (o.opLat != null) {
      opLat = o.opLat;
      opLon = o.opLon;
    }
    if (o.operatorId != null) operatorId = o.operatorId;
    if (o.description != null) description = o.description;
    this.rssi = rssi;
    lastSeen = now;
    messages++;
  }

  /// Whether a post is due: never posted, or a minute since and 200 m on.
  bool postDue(DateTime now) {
    if (!hasPosition) return false;
    if (postedAt == null) return true;
    if (now.difference(postedAt!) < remoteIdPostInterval) return false;
    return remoteIdDistanceM(postedLat!, postedLon!, lat!, lon!) >= remoteIdPostMoveM;
  }

  void markPosted(DateTime now) {
    postedAt = now;
    postedLat = lat;
    postedLon = lon;
  }
}

double remoteIdDistanceM(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371000.0;
  double rad(double d) => d * math.pi / 180;
  final dLat = rad(lat2 - lat1), dLon = rad(lon2 - lon1);
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(rad(lat1)) * math.cos(rad(lat2)) * math.sin(dLon / 2) * math.sin(dLon / 2);
  return r * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}

/// The drones heard. Bluetooth legacy adverts carry one message each, so an
/// address's UAS ID (from its Basic ID advert) is lent to its other messages.
class RemoteIdTracker {
  static const int maxTracks = 32;
  static const Duration forgetAddress = Duration(minutes: 2);

  final Map<String, RemoteIdTrack> _tracks = {};
  final Map<String, (String, DateTime)> _idByAddress = {};

  Iterable<RemoteIdTrack> get tracks => _tracks.values;
  int get length => _tracks.length;
  RemoteIdTrack? operator [](String uasId) => _tracks[uasId];

  /// Merges [o], heard from [address]; returns its track, or null when no UAS
  /// ID is known for it yet. [isNew] says whether the track was just created.
  RemoteIdTrack? ingest(
    RemoteIdObservation o,
    String address,
    int rssi,
    DateTime now, {
    void Function(RemoteIdTrack)? isNew,
  }) {
    var id = o.uasId;
    if (id != null) {
      _idByAddress[address] = (id, now);
    } else {
      final known = _idByAddress[address];
      if (known == null || now.difference(known.$2) > forgetAddress) return null;
      id = known.$1;
    }
    var t = _tracks[id];
    if (t == null) {
      if (_tracks.length >= maxTracks) {
        final oldest = _tracks.values.reduce((a, b) => a.lastSeen.isBefore(b.lastSeen) ? a : b);
        _tracks.remove(oldest.uasId);
      }
      t = _tracks[id] = RemoteIdTrack(id, now);
      isNew?.call(t);
    }
    t._merge(o, rssi, now);
    return t;
  }

  /// Drops tracks not heard for [remoteIdExpire] and forgotten addresses.
  bool age(DateTime now) {
    final before = _tracks.length;
    _tracks.removeWhere((_, t) => now.difference(t.lastSeen) > remoteIdExpire);
    _idByAddress.removeWhere((_, v) => now.difference(v.$2) > forgetAddress);
    return _tracks.length != before;
  }

  void clear() {
    _tracks.clear();
    _idByAddress.clear();
  }
}

// ---- the channel post --------------------------------------------------------------------

/// The UAS ID as a Watch serial (letters, digits, '-'), or null when what is
/// left can't be one (under 6 characters, or no digit).
String? remoteIdSerial(String id) {
  final s = id.replaceAll(RegExp(r'[^A-Za-z0-9-]'), '');
  return s.length >= 6 && s.contains(RegExp(r'[0-9]')) ? s : null;
}

/// "7.0m/s" under 9.5 m/s, else whole m/s ("12m/s").
String remoteIdSpeed(int cms) {
  if (cms >= 950) return '${(cms + 50) ~/ 100}m/s';
  final dm = (cms + 5) ~/ 10;
  return '${dm ~/ 10}.${dm % 10}m/s';
}

/// The post for [t], or null when it has no position (Watch needs one) or its
/// ID can't be a Watch serial.
String? remoteIdPost(RemoteIdTrack t) {
  if (!t.hasPosition) return null;
  final serial = remoteIdSerial(t.uasId);
  if (serial == null) return null;
  final facts = StringBuffer();
  if (t.heightAglM != 0) {
    facts.write(' h${t.heightAglM}m');
  } else if (t.altGeoM != 0) {
    facts.write(' alt${t.altGeoM}m');
  }
  facts.write(' ${remoteIdSpeed(t.speedCms)}');
  if (t.speedCms >= 50) facts.write(' hdg${t.headingDeg % 360}');
  final out = StringBuffer(
    'DRONE $serial$facts\n'
    'https://maps.google.com/?q=${t.lat!.toStringAsFixed(5)},${t.lon!.toStringAsFixed(5)}',
  );
  if (t.hasOperator) {
    out.write(
      '\nOp https://maps.google.com/?q=${t.opLat!.toStringAsFixed(5)},${t.opLon!.toStringAsFixed(5)}',
    );
  }
  return out.toString();
}
