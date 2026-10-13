// MeshCore Open TAK - team coordination wire formats.
//
// Original design for MeshCore Open TAK. Everything goes out as GRP_DATA on
// the team's private channel (data type [teamChannelDataType]), so it is
// encrypted with the channel key. GRP_DATA carries no sender identity, so
// every message starts with the first 4 bytes of the sender's public key.
//
//   position  [0x50][key4][flags][lat i32][lon i32][alt i16][speed u8]
//             [heading u8][accuracy u8][battery u8][role<<4|colour][status]
//             [callsignLen][callsign]
//   alert     [0x53][key4][alertId u16][type<<4|flags][lat i32][lon i32]
//             [accuracy u8][callsignLen][callsign][noteLen][note]
//   marker    [0x4D][key4][markerId u32][op u8][kind u8][lat i32][lon i32]
//             [time u32][labelLen][label][noteLen][note]
//             [attachMode u8][sid4][packets u8][extra u16]   (attachment
//             fields only when attachMode != 0; it is a VOX clip mode id)
//   report    [0x52][key4][reportId u32][kind<<4|urgency][affiliation]
//             [lat i32][lon i32][observed u32][vehicles u8][people u8]
//             [place][size][activity][unit][equipment] (length-prefixed)
//             [attachMode u8][sid4][packets][extra] [withdrawn u8]?
//             (the trailing 1 retracts the author's own report; older
//             readers ignore it)
//   role      [0x4C][key4][roleId u8][op u8][time u32][icon u16]
//             [nameLen][name]   (a team-wide name/icon for a role; op 1 =
//             back to the default, or removed for an added role)
//   shape     [0x44][key4][shapeId u32][op u8][kind u8][colour u8][time u32]
//             [labelLen][label][geofence u8][param varint][nPoints u8]
//             [lat0 i32][lon0 i32][zigzag varint deltas...] (1e-5 degrees)
//   casevac   [0x43][key4][id u32][op u8][lat i32][lon i32][time u32] then
//             the 9 lines (see team_casevac_wire.dart)
//
// A position's role is the high nibble of its role/colour byte; roles 15 and
// up (added roles) write 15 there, set flag 0x20 and append the role id as
// one byte after the callsign. Older readers see an unknown role.
//
// Added with the ATAK plugin (atak-plugin/), which also speaks position,
// alert, marker and report; formats in team_wire_atak.dart:
//   point     [0x4F] any single-point CoT item (spot marker, 2525 unit...)
//   ATAK shape [0x47] routes, lines, polygons, rectangles and circles as
//             ATAK draws them (the app's own drawings are 0x44 above)
//   chunk     [0x58] chunked, compressed CoT or a small file
//
// Coordinates are degrees x 1e7 (about 1 cm). All integers big-endian.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'team_coords.dart';

part 'team_shape_wire.dart';
part 'team_casevac_wire.dart';

/// GRP_DATA data type for team traffic ('VT').
const int teamChannelDataType = 0x5654;

const int teamMsgPosition = 0x50; // 'P'
const int teamMsgAlert = 0x53; // 'S'
const int teamMsgMarker = 0x4D; // 'M'
const int teamMsgReport = 0x52; // 'R'
const int teamMsgRole = 0x4C; // 'L' (role label)
const int teamMsgShape = 0x44; // 'D' (drawings, routes, geofences)
const int teamMsgCasevac = 0x43; // 'C' (CASEVAC / MEDEVAC 9-line)

/// Largest GRP_DATA payload the firmware accepts.
const int teamMaxPayload = 163;

const int teamMaxCallsignBytes = 20;
const int teamMaxLabelBytes = 32;
const int teamMaxNoteBytes = 60;
const int teamMaxAlertNoteBytes = 80;
const int teamMaxRoleNameBytes = 20;

/// Role ids: 0-8 are [TeamRole]'s defaults, 9-24 roles a team added.
const int teamFirstAddedRole = 9;
const int teamMaxRoleId = 24;
const int _roleEscape = 15;

/// Roles, as in ATAK-style team awareness.
enum TeamRole {
  member('Team member'),
  lead('Team lead'),
  medic('Medic'),
  navigator('Navigator'),
  comms('Comms'),
  driver('Driver / vehicle'),
  security('Security'),
  observer('Observer'),
  command('Command / HQ');

  const TeamRole(this.label);
  final String label;

  static TeamRole fromIndex(int i) =>
      i >= 0 && i < values.length ? values[i] : member;
}

/// Team colours (ATAK palette).
enum TeamColor {
  cyan(0xFF00BCD4),
  white(0xFFFFFFFF),
  yellow(0xFFFFEB3B),
  orange(0xFFFF9800),
  magenta(0xFFE040FB),
  red(0xFFF44336),
  maroon(0xFF8B1A1A),
  purple(0xFF7E57C2),
  darkBlue(0xFF1A237E),
  blue(0xFF2196F3),
  teal(0xFF009688),
  green(0xFF4CAF50),
  darkGreen(0xFF1B5E20),
  brown(0xFF795548);

  const TeamColor(this.argb);
  final int argb;

  String get label => switch (this) {
    darkBlue => 'Dark blue',
    darkGreen => 'Dark green',
    _ => name[0].toUpperCase() + name.substring(1),
  };

  static TeamColor fromIndex(int i) =>
      i >= 0 && i < values.length ? values[i] : cyan;
}

/// Member status, sent with every position.
enum TeamStatus {
  none(''),
  ok('OK'),
  busy('Busy'),
  needHelp('Need help'),
  returning('Returning'),
  resting('Resting');

  const TeamStatus(this.label);
  final String label;

  static TeamStatus fromIndex(int i) =>
      i >= 0 && i < values.length ? values[i] : none;
}

/// Tactical pin types.
enum MarkerKind {
  point('Point'),
  lastKnown('Last known point'),
  staging('Staging / command post'),
  clue('Clue'),
  hazard('Hazard'),
  landingZone('Landing zone'),
  medical('Medical'),
  subjectFound('Subject found'),
  water('Water / resources'),
  searched('Area searched');

  const MarkerKind(this.label);
  final String label;

  static MarkerKind fromIndex(int i) =>
      i >= 0 && i < values.length ? values[i] : point;
}

// ------------------------------------------------------------------ helpers

class _W {
  final BytesBuilder b = BytesBuilder();
  void u8(int v) => b.addByte(v & 0xFF);
  void u16(int v) {
    u8(v >> 8);
    u8(v);
  }

  void u32(int v) {
    u16(v >> 16);
    u16(v);
  }

  void i32(int v) => u32(v & 0xFFFFFFFF);
  void i16(int v) => u16(v & 0xFFFF);
  void bytes(List<int> v) => b.add(v);

  /// Unsigned LEB128.
  void varint(int v) {
    var x = v;
    while (x >= 0x80) {
      u8((x & 0x7F) | 0x80);
      x >>= 7;
    }
    u8(x);
  }

  /// Zigzag signed varint.
  void svarint(int v) => varint(v >= 0 ? v << 1 : ((-v) << 1) - 1);
  void str(String s, int maxBytes) {
    final enc = teamTruncateUtf8(s, maxBytes);
    u8(enc.length);
    b.add(enc);
  }

  Uint8List done() => b.toBytes();
}

class _R {
  final Uint8List d;
  int o = 0;
  _R(this.d);
  bool has(int n) => o + n <= d.length;
  int u8() => d[o++];
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

  /// Unsigned LEB128, or null if truncated.
  int? varint() {
    var v = 0, shift = 0;
    while (true) {
      if (!has(1) || shift > 35) return null;
      final b = u8();
      v |= (b & 0x7F) << shift;
      if (b < 0x80) return v;
      shift += 7;
    }
  }

  int? svarint() {
    final z = varint();
    if (z == null) return null;
    return z.isEven ? z >> 1 : -((z + 1) >> 1);
  }

  Uint8List take(int n) {
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
}

/// UTF-8 bytes of [s], cut to at most [maxBytes] on a character boundary.
Uint8List teamTruncateUtf8(String s, int maxBytes) {
  final out = utf8.encode(s.trim());
  if (out.length <= maxBytes) return Uint8List.fromList(out);
  var cut = maxBytes;
  while (cut > 0 && (out[cut] & 0xC0) == 0x80) {
    cut--;
  }
  return Uint8List.fromList(out.sublist(0, cut));
}

int _deg(double v) => (v * 1e7).round();
double _undeg(int v) => v / 1e7;

String teamKey4Hex(List<int> b, [int offset = 0]) {
  final sb = StringBuffer();
  for (var i = 0; i < 4; i++) {
    sb.write(b[offset + i].toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

Uint8List _key4(String hex) => Uint8List.fromList([
  for (var i = 0; i < 4; i++)
    int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16),
]);

// From the ATAK plugin (team_wire_atak.dart). Its point moved from 0x43,
// which CASEVAC took first.
const int teamMsgPoint = 0x4F; // 'O'
const int teamMsgAtakShape = 0x47; // 'G'
const int teamMsgChunk = 0x58; // 'X'

/// Message type and sender of a team payload, or null if it isn't one.
(int, String)? teamPeek(Uint8List p) {
  if (p.length < 5) return null;
  if (p[0] != teamMsgPosition &&
      p[0] != teamMsgAlert &&
      p[0] != teamMsgMarker &&
      p[0] != teamMsgReport &&
      p[0] != teamMsgRole &&
      p[0] != teamMsgShape &&
      p[0] != teamMsgCasevac &&
      p[0] != teamMsgPoint &&
      p[0] != teamMsgAtakShape &&
      p[0] != teamMsgChunk) {
    return null;
  }
  return (p[0], teamKey4Hex(p, 1));
}

// ----------------------------------------------------------------- position

class TeamPosition {
  final String senderKey4;
  final double lat, lon;
  final int? altitudeM;
  final double? speedMps;
  final double? headingDeg;
  final int accuracyM;
  final int? batteryPct;

  /// 0-8 a default [TeamRole], 9-24 a role the team added.
  final int roleId;
  final TeamColor color;
  final TeamStatus status;
  final String callsign;
  final bool fromRadio;
  final bool sosActive;

  /// A TAK user's position relayed onto the mesh by a gateway phone.
  final bool relayed;

  const TeamPosition({
    required this.senderKey4,
    required this.lat,
    required this.lon,
    this.altitudeM,
    this.speedMps,
    this.headingDeg,
    this.accuracyM = 0,
    this.batteryPct,
    this.roleId = 0,
    this.color = TeamColor.cyan,
    this.status = TeamStatus.none,
    this.callsign = '',
    this.fromRadio = false,
    this.sosActive = false,
    this.relayed = false,
  });

  /// The default role, or [TeamRole.member] for an added one.
  TeamRole get role => TeamRole.fromIndex(roleId);

  Uint8List encode() {
    final rid = roleId.clamp(0, teamMaxRoleId);
    final extended = rid >= _roleEscape;
    final w = _W()
      ..u8(teamMsgPosition)
      ..bytes(_key4(senderKey4))
      ..u8(
        (altitudeM != null ? 0x01 : 0) |
            (speedMps != null && headingDeg != null ? 0x02 : 0) |
            (fromRadio ? 0x04 : 0) |
            (sosActive ? 0x08 : 0) |
            (relayed ? 0x10 : 0) |
            (extended ? 0x20 : 0),
      )
      ..i32(_deg(lat))
      ..i32(_deg(lon))
      ..i16((altitudeM ?? 0).clamp(-32768, 32767))
      ..u8(((speedMps ?? 0) * 2).round().clamp(0, 255))
      ..u8((((headingDeg ?? 0) % 360) * 256 / 360).round() & 0xFF)
      ..u8(accuracyM.clamp(0, 255))
      ..u8(batteryPct == null ? 255 : batteryPct!.clamp(0, 100))
      ..u8(((extended ? _roleEscape : rid) << 4) | (color.index & 0x0F))
      ..u8(status.index)
      ..str(callsign, teamMaxCallsignBytes);
    if (extended) w.u8(rid);
    return w.done();
  }

  static TeamPosition? tryParse(Uint8List p) {
    final r = _R(p);
    if (!r.has(25) || r.u8() != teamMsgPosition) return null;
    final key = teamKey4Hex(r.take(4));
    final flags = r.u8();
    final lat = _undeg(r.i32()), lon = _undeg(r.i32());
    if (lat.abs() > 90 || lon.abs() > 180) return null;
    final alt = r.i16();
    final speed = r.u8() / 2;
    final heading = r.u8() * 360 / 256;
    final acc = r.u8();
    final batt = r.u8();
    final rc = r.u8();
    final status = r.u8();
    final cs = r.str() ?? '';
    var roleId = rc >> 4;
    if (roleId == _roleEscape) {
      roleId = flags & 0x20 != 0 && r.has(1) ? r.u8() : 0;
      if (roleId > teamMaxRoleId) roleId = 0;
    }
    return TeamPosition(
      senderKey4: key,
      lat: lat,
      lon: lon,
      altitudeM: flags & 0x01 != 0 ? alt : null,
      speedMps: flags & 0x02 != 0 ? speed : null,
      headingDeg: flags & 0x02 != 0 ? heading : null,
      accuracyM: acc,
      batteryPct: batt == 255 ? null : batt,
      roleId: roleId,
      color: TeamColor.fromIndex(rc & 0x0F),
      status: TeamStatus.fromIndex(status),
      callsign: cs,
      fromRadio: flags & 0x04 != 0,
      sosActive: flags & 0x08 != 0,
      relayed: flags & 0x10 != 0,
    );
  }
}

// -------------------------------------------------------------------- alert

/// Alert types, after ATAK's emergency menu.
enum TeamAlertType {
  sos('SOS / 911'),
  inContact('In contact'),
  ringTheBell('Ring the bell'),
  geofence('Geofence breached'),
  custom('Alert');

  const TeamAlertType(this.label);
  final String label;

  static TeamAlertType fromIndex(int i) =>
      i >= 0 && i < values.length ? values[i] : sos;
}

class TeamAlert {
  final String senderKey4;
  final int alertId;
  final bool active;
  final TeamAlertType type;
  final double? lat, lon;
  final int accuracyM;
  final String callsign;
  final String note;

  const TeamAlert({
    required this.senderKey4,
    required this.alertId,
    required this.active,
    this.type = TeamAlertType.sos,
    this.lat,
    this.lon,
    this.accuracyM = 0,
    this.callsign = '',
    this.note = '',
  });

  /// Unique per sender and alert.
  String get key => '$senderKey4:$alertId';

  Uint8List encode() {
    final hasPos = lat != null && lon != null;
    final w = _W()
      ..u8(teamMsgAlert)
      ..bytes(_key4(senderKey4))
      ..u16(alertId)
      ..u8((active ? 0x01 : 0) | (hasPos ? 0x02 : 0) | (type.index << 4))
      ..i32(hasPos ? _deg(lat!) : 0)
      ..i32(hasPos ? _deg(lon!) : 0)
      ..u8(accuracyM.clamp(0, 255))
      ..str(callsign, teamMaxCallsignBytes)
      ..str(note, teamMaxAlertNoteBytes);
    return w.done();
  }

  static TeamAlert? tryParse(Uint8List p) {
    final r = _R(p);
    if (!r.has(18) || r.u8() != teamMsgAlert) return null;
    final key = teamKey4Hex(r.take(4));
    final id = r.u16();
    final state = r.u8();
    final lat = _undeg(r.i32()), lon = _undeg(r.i32());
    final acc = r.u8();
    final hasPos = state & 0x02 != 0 && lat.abs() <= 90 && lon.abs() <= 180;
    return TeamAlert(
      senderKey4: key,
      alertId: id,
      active: state & 0x01 != 0,
      type: TeamAlertType.fromIndex(state >> 4),
      lat: hasPos ? lat : null,
      lon: hasPos ? lon : null,
      accuracyM: acc,
      callsign: r.str() ?? '',
      note: r.str() ?? '',
    );
  }
}

// ------------------------------------------------------------------- marker

/// A photo or voice clip attached to a pin: a VOX clip that teammates fetch
/// on demand from the pin's author.
class TeamAttachment {
  final int modeWireId; // VoxVoiceMode.wireId
  final String sessionId; // 8 hex chars
  final int packets;
  final int extra; // duration (voice) or aspect code (image)
  const TeamAttachment(
    this.modeWireId,
    this.sessionId,
    this.packets,
    this.extra,
  );
}

class TeamMarker {
  final String authorKey4;
  final int markerId;
  final bool deleted;
  final MarkerKind kind;
  final double lat, lon;
  final DateTime time;
  final String label;
  final String note;
  final TeamAttachment? attachment;

  const TeamMarker({
    required this.authorKey4,
    required this.markerId,
    required this.kind,
    required this.lat,
    required this.lon,
    required this.time,
    this.label = '',
    this.note = '',
    this.deleted = false,
    this.attachment,
  });

  /// Unique across the team: author + id.
  String get key => '$authorKey4:${markerId.toRadixString(16)}';

  TeamMarker copyWith({
    bool? deleted,
    MarkerKind? kind,
    double? lat,
    double? lon,
    DateTime? time,
    String? label,
    String? note,
    TeamAttachment? attachment,
    bool clearAttachment = false,
  }) => TeamMarker(
    authorKey4: authorKey4,
    markerId: markerId,
    deleted: deleted ?? this.deleted,
    kind: kind ?? this.kind,
    lat: lat ?? this.lat,
    lon: lon ?? this.lon,
    time: time ?? this.time,
    label: label ?? this.label,
    note: note ?? this.note,
    attachment: clearAttachment ? null : (attachment ?? this.attachment),
  );

  Uint8List encode() {
    final w = _W()
      ..u8(teamMsgMarker)
      ..bytes(_key4(authorKey4))
      ..u32(markerId)
      ..u8(deleted ? 1 : 0)
      ..u8(kind.index)
      ..i32(_deg(lat))
      ..i32(_deg(lon))
      ..u32(time.millisecondsSinceEpoch ~/ 1000)
      ..str(label, teamMaxLabelBytes)
      ..str(note, teamMaxNoteBytes);
    final a = attachment;
    if (a == null) {
      w.u8(0);
    } else {
      w
        ..u8(a.modeWireId)
        ..bytes(_key4(a.sessionId))
        ..u8(a.packets)
        ..u16(a.extra);
    }
    return w.done();
  }

  static TeamMarker? tryParse(Uint8List p) {
    final r = _R(p);
    if (!r.has(23) || r.u8() != teamMsgMarker) return null;
    final key = teamKey4Hex(r.take(4));
    final id = r.u32();
    final op = r.u8();
    final kind = MarkerKind.fromIndex(r.u8());
    final lat = _undeg(r.i32()), lon = _undeg(r.i32());
    if (lat.abs() > 90 || lon.abs() > 180) return null;
    final t = DateTime.fromMillisecondsSinceEpoch(r.u32() * 1000);
    final label = r.str();
    final note = r.str();
    if (label == null || note == null) return null;
    TeamAttachment? att;
    if (r.has(1)) {
      final mode = r.u8();
      if (mode != 0 && r.has(7)) {
        att = TeamAttachment(mode, teamKey4Hex(r.take(4)), r.u8(), r.u16());
      }
    }
    return TeamMarker(
      authorKey4: key,
      markerId: id,
      deleted: op == 1,
      kind: kind,
      lat: lat,
      lon: lon,
      time: t,
      label: label,
      note: note,
      attachment: att,
    );
  }
}

// ----------------------------------------------------------- smart beacons

/// When to send the next position, APRS "smart beaconing" style: often while
/// moving, rarely when still, and at once on a sharp turn.
class TeamBeaconPolicy {
  final Duration minInterval;
  final Duration movingInterval;
  final Duration stillInterval;
  final double movingSpeedMps;
  final double turnDegrees;
  final double distanceMeters;

  const TeamBeaconPolicy({
    this.minInterval = const Duration(seconds: 30),
    this.movingInterval = const Duration(seconds: 90),
    this.stillInterval = const Duration(minutes: 10),
    this.movingSpeedMps = 0.8,
    this.turnDegrees = 35,
    this.distanceMeters = 75,
  });

  /// [sinceLast] null means nothing has been sent yet.
  bool shouldSend({
    required Duration? sinceLast,
    required double? metersSinceLast,
    required double? speedMps,
    required double? headingChangeDeg,
  }) {
    if (sinceLast == null) return true;
    if (sinceLast < minInterval) return false;
    final moving = (speedMps ?? 0) >= movingSpeedMps;
    if (moving && (headingChangeDeg ?? 0).abs() >= turnDegrees) return true;
    if ((metersSinceLast ?? 0) >= distanceMeters &&
        sinceLast >= movingInterval ~/ 2) {
      return true;
    }
    if (moving && sinceLast >= movingInterval) return true;
    return sinceLast >= stillInterval;
  }
}

/// Great-circle distance in metres.
double teamDistanceMeters(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371000.0;
  final p1 = lat1 * pi / 180, p2 = lat2 * pi / 180;
  final dp = (lat2 - lat1) * pi / 180, dl = (lon2 - lon1) * pi / 180;
  final a =
      sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2);
  return 2 * r * atan2(sqrt(a), sqrt(1 - a));
}

/// Initial bearing from point 1 to point 2, degrees 0..360 (0 = north).
double teamBearingDeg(double lat1, double lon1, double lat2, double lon2) {
  final p1 = lat1 * pi / 180, p2 = lat2 * pi / 180;
  final dl = (lon2 - lon1) * pi / 180;
  final y = sin(dl) * cos(p2);
  final x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl);
  return (atan2(y, x) * 180 / pi + 360) % 360;
}

/// "1.2 km 045° NE"
String teamRangeBearing(double meters, double bearing) {
  const names = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];
  final d = meters >= 1000
      ? '${(meters / 1000).toStringAsFixed(meters >= 10000 ? 0 : 1)} km'
      : '${meters.round()} m';
  final b = bearing.round() % 360;
  return '$d ${b.toString().padLeft(3, '0')}° ${names[((b + 22.5) ~/ 45) % 8]}';
}

// ------------------------------------------------------------------- report

/// MIL-STD-2525 style affiliation of what was observed.
enum TeamAffiliation {
  unknown('Unknown'),
  hostile('Hostile'),
  neutral('Neutral'),
  friendly('Friendly');

  const TeamAffiliation(this.label);
  final String label;

  static TeamAffiliation fromIndex(int i) =>
      i >= 0 && i < values.length ? values[i] : unknown;
}

enum TeamReportKind {
  salute('SALUTE'),

  /// Free text: whatever someone wants the team to know, at a place. Sent in
  /// the SALUTE layout with the text in Activity, so older apps show it as
  /// a SALUTE report with that activity.
  general('Report');

  const TeamReportKind(this.label);
  final String label;

  static TeamReportKind fromIndex(int i) =>
      i >= 0 && i < values.length ? values[i] : salute;
}

/// How urgent a report is (condensed card dot colour).
enum TeamUrgency {
  other('OTHER', '🔵'),
  observed('OBSERVED', '🟢'),
  active('ACTIVE', '🟡'),
  critical('CRITICAL', '🔴');

  const TeamUrgency(this.label, this.dot);
  final String label;
  final String dot;

  static TeamUrgency fromIndex(int i) =>
      i >= 0 && i < values.length ? values[i] : observed;
}

const int teamMaxSaluteSizeBytes = 12;
const int teamMaxSaluteActivityBytes = 32;
const int teamMaxSaluteUnitBytes = 24;
const int teamMaxSaluteEquipmentBytes = 28;
const int teamMaxSalutePlaceBytes = 24;

/// A general report's text. With a full place name, an attachment and a
/// withdrawal byte the report is exactly [teamMaxPayload].
const int teamMaxGeneralTextBytes = 100;

/// SALUTE report: Size, Activity, Location, Unit/uniform, Time, Equipment.
/// Size is structured as vehicle and personnel counts (plus a short note),
/// location as coordinates plus an optional place name, time as a timestamp.
class TeamReport {
  final String authorKey4;
  final int reportId;
  final TeamReportKind kind;
  final TeamAffiliation affiliation;
  final TeamUrgency urgency;
  final double lat, lon;
  final DateTime observed;
  final int vehicles, people;
  final String place;
  final String size, activity, unit, equipment;
  final TeamAttachment? attachment;

  /// The author took this report back; receivers remove it.
  final bool withdrawn;

  const TeamReport({
    required this.authorKey4,
    required this.reportId,
    required this.lat,
    required this.lon,
    required this.observed,
    this.kind = TeamReportKind.salute,
    this.affiliation = TeamAffiliation.unknown,
    this.urgency = TeamUrgency.observed,
    this.vehicles = 0,
    this.people = 0,
    this.place = '',
    this.size = '',
    this.activity = '',
    this.unit = '',
    this.equipment = '',
    this.attachment,
    this.withdrawn = false,
  });

  String get key => '$authorKey4:${reportId.toRadixString(16)}';

  /// The same report, marked as taken back by its author.
  TeamReport asWithdrawn() => TeamReport(
    authorKey4: authorKey4,
    reportId: reportId,
    lat: lat,
    lon: lon,
    observed: observed,
    kind: kind,
    affiliation: affiliation,
    urgency: urgency,
    vehicles: vehicles,
    people: people,
    place: place,
    size: size,
    activity: activity,
    unit: unit,
    equipment: equipment,
    attachment: attachment,
    withdrawn: true,
  );

  static String _two(int v) => v.toString().padLeft(2, '0');

  /// "10-03 11:30" in local time.
  String get timeLabel =>
      '${_two(observed.month)}-${_two(observed.day)} '
      '${_two(observed.hour)}:${_two(observed.minute)}';

  /// "3-🚗 5-🥾"
  String get countsLabel => [
    if (vehicles > 0) '$vehicles-🚗',
    if (people > 0) '$people-🥾',
    if (size.isNotEmpty) size,
  ].join(' ');

  String get placeLabel => place.isNotEmpty
      ? place
      : '${lat.toStringAsFixed(4)}, ${lon.toStringAsFixed(4)}';

  bool get isGeneral => kind == TeamReportKind.general;

  /// A general report's text.
  String get text => activity;

  /// "Report" or "SALUTE report", for headings.
  String get title => isGeneral ? 'Report' : 'SALUTE report';

  /// The condensed card, line by line:
  ///   🔴 CRITICAL / 10-03 11:30 / @Auburn E Main St / 3-🚗 5-🥾 / details
  List<String> condensedLines() => isGeneral
      ? [
          '${urgency.dot} ${urgency.label}',
          timeLabel,
          '@$placeLabel',
          if (text.isNotEmpty) text,
        ]
      : [
    '${urgency.dot} ${urgency.label}',
    timeLabel,
    '@$placeLabel',
    if (countsLabel.isNotEmpty) countsLabel,
    if (activity.isNotEmpty) 'A: $activity',
    if (unit.isNotEmpty) 'U: $unit',
    if (equipment.isNotEmpty) 'E: $equipment',
  ];

  /// As a plain text message for MeshCore apps without VOX (kept short).
  String condensedText({int maxChars = 150}) {
    final t = condensedLines().join('\n');
    return t.length <= maxChars ? t : '${t.substring(0, maxChars - 1)}…';
  }

  /// One-line SALUTE summary for lists and TAK remarks.
  String summary() => isGeneral
      ? [
          '${urgency.label}: $text',
          'L: ${place.isNotEmpty ? '$place ' : ''}(${lat.toStringAsFixed(5)}, ${lon.toStringAsFixed(5)})',
          'T: ${observed.toUtc().toIso8601String().substring(0, 16)}Z',
        ].join(' / ')
      : [
    '${urgency.label}${affiliation == TeamAffiliation.unknown ? '' : ' ${affiliation.label.toLowerCase()}'}',
    if (countsLabel.isNotEmpty) 'S: $countsLabel',
    if (activity.isNotEmpty) 'A: $activity',
    'L: ${place.isNotEmpty ? '$place ' : ''}(${lat.toStringAsFixed(5)}, ${lon.toStringAsFixed(5)})',
    if (unit.isNotEmpty) 'U: $unit',
    'T: ${observed.toUtc().toIso8601String().substring(0, 16)}Z',
    if (equipment.isNotEmpty) 'E: $equipment',
  ].join(' / ');

  Uint8List encode() {
    final w = _W()
      ..u8(teamMsgReport)
      ..bytes(_key4(authorKey4))
      ..u32(reportId)
      ..u8((kind.index << 4) | (urgency.index & 0x0F))
      ..u8(affiliation.index)
      ..i32(_deg(lat))
      ..i32(_deg(lon))
      ..u32(observed.millisecondsSinceEpoch ~/ 1000)
      ..u8(vehicles.clamp(0, 255))
      ..u8(people.clamp(0, 255))
      ..str(place, teamMaxSalutePlaceBytes)
      ..str(size, teamMaxSaluteSizeBytes)
      ..str(activity, isGeneral ? teamMaxGeneralTextBytes : teamMaxSaluteActivityBytes)
      ..str(unit, teamMaxSaluteUnitBytes)
      ..str(equipment, teamMaxSaluteEquipmentBytes);
    final a = attachment;
    if (a == null) {
      w.u8(0);
    } else {
      w
        ..u8(a.modeWireId)
        ..bytes(_key4(a.sessionId))
        ..u8(a.packets)
        ..u16(a.extra);
    }
    if (withdrawn) w.u8(1);
    return w.done();
  }

  static TeamReport? tryParse(Uint8List p) {
    final r = _R(p);
    if (!r.has(25) || r.u8() != teamMsgReport) return null;
    final key = teamKey4Hex(r.take(4));
    final id = r.u32();
    final ku = r.u8();
    final aff = TeamAffiliation.fromIndex(r.u8());
    final lat = _undeg(r.i32()), lon = _undeg(r.i32());
    if (lat.abs() > 90 || lon.abs() > 180) return null;
    final t = DateTime.fromMillisecondsSinceEpoch(r.u32() * 1000);
    final vehicles = r.u8(), people = r.u8();
    final place = r.str();
    final size = r.str(), act = r.str(), unit = r.str(), eq = r.str();
    if (place == null ||
        size == null ||
        act == null ||
        unit == null ||
        eq == null) {
      return null;
    }
    TeamAttachment? att;
    var withdrawn = false;
    if (r.has(1)) {
      final mode = r.u8();
      if (mode != 0 && r.has(7)) {
        att = TeamAttachment(mode, teamKey4Hex(r.take(4)), r.u8(), r.u16());
      }
      if (r.has(1)) withdrawn = r.u8() & 1 != 0;
    }
    return TeamReport(
      authorKey4: key,
      reportId: id,
      kind: TeamReportKind.fromIndex(ku >> 4),
      urgency: TeamUrgency.fromIndex(ku & 0x0F),
      affiliation: aff,
      lat: lat,
      lon: lon,
      observed: t,
      vehicles: vehicles,
      people: people,
      place: place,
      size: size,
      activity: act,
      unit: unit,
      equipment: eq,
      attachment: att,
      withdrawn: withdrawn,
    );
  }
}

// --------------------------------------------------------------------- role

/// A team-wide name and icon for a role. The newest edit of each role wins.
class TeamRoleDef {
  final String authorKey4;
  final int roleId;

  /// Back to the default name and icon; for an added role, removed.
  final bool reset;
  final DateTime time;

  /// An id from the app's role icon library; 0 = the role's default icon.
  final int iconId;
  final String name;

  const TeamRoleDef({
    required this.authorKey4,
    required this.roleId,
    required this.time,
    this.reset = false,
    this.iconId = 0,
    this.name = '',
  });

  /// Whether this edit should replace [other] for the same role.
  bool beats(TeamRoleDef other) {
    final a = time.millisecondsSinceEpoch ~/ 1000;
    final b = other.time.millisecondsSinceEpoch ~/ 1000;
    if (a != b) return a > b;
    return authorKey4.compareTo(other.authorKey4) > 0;
  }

  Uint8List encode() {
    final w = _W()
      ..u8(teamMsgRole)
      ..bytes(_key4(authorKey4))
      ..u8(roleId.clamp(0, teamMaxRoleId))
      ..u8(reset ? 1 : 0)
      ..u32(time.millisecondsSinceEpoch ~/ 1000)
      ..u16(iconId)
      ..str(reset ? '' : name, teamMaxRoleNameBytes);
    return w.done();
  }

  static TeamRoleDef? tryParse(Uint8List p) {
    final r = _R(p);
    if (!r.has(14) || r.u8() != teamMsgRole) return null;
    final key = teamKey4Hex(r.take(4));
    final id = r.u8();
    if (id > teamMaxRoleId) return null;
    final op = r.u8();
    final t = r.u32();
    final icon = r.u16();
    final name = r.str();
    if (name == null) return null;
    return TeamRoleDef(
      authorKey4: key,
      roleId: id,
      reset: op & 1 != 0,
      time: DateTime.fromMillisecondsSinceEpoch(t * 1000),
      iconId: icon,
      name: name,
    );
  }
}
