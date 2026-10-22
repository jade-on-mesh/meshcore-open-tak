// MeshCore Open TAK - MeshCore TEAM interop: its channel-text formats.
//
// MeshCore TEAM (github.com/tmacinc/MeshCore-TEAM) tracks a group on a private
// channel with plain channel text, where our Team uses binary GRP_DATA
// (team_wire.dart). This file reads and writes TEAM's text, written here from
// its wire formats (TEAM's code is CC BY-NC-SA and isn't used):
//
//   #TEL:<base64, unpadded, 11 bytes>
//        [lat i32 BE, deg x 1e7][lon i32][companion batt][phone batt][fwd]
//        batt: 0/1 unknown, 2..254 = (mV - 2750) / 6 + 2; phone 0xFF: a
//        radio tracking on its own GPS (TEAM's "autonomous" mode).
//        fwd: ((maxPath << 1) | needsForwarding) + 1.
//   #T:<base64, unpadded> [lat][lon][comp batt][phone batt][nodeCount]
//        [neighbour bitmap...]: read for the position and battery only.
//   #CAP:1:<flags hex>
//   #CAP:2:<flags hex>:<radio key, 12 hex | ->:<app id, 16 hex | ->:<alias>
//        the alias (UTF-8, at most 24 bytes) is last and may contain ':'.
//   #CAP:R:<key prefix, 12 hex | ->:<radio name>   asks that node to advert.
//   #WAY:<meshId>|<name>|<lat>|<lon>|<description>|<type>|<route>[|n/N]
//   #WAY:<name>|<lat>|<lon>|<description>|<type>   (older form)
//   #WRC:<meshId>|<route chunk>|n/N               (a long route's parts)
//        route: "lat,lon~lat,lon~..." (6 decimals); a route's colour leads
//        its description as "@C:AARRGGBB". Types: CAMP, MEETUP, DANGER, GAME,
//        STAND, WATER, VEHICLE, ROUTE, CUSTOM. A whole message (with the radio
//        name the firmware puts in front) stays within 140 bytes.
//
// See documentation/meshcore-team.md.

import 'dart:convert';
import 'dart:typed_data';

const String teamTelPrefix = '#TEL:';
const String teamTopoPrefix = '#T:';
const String teamCapPrefix = '#CAP:';
const String teamCapRequestPrefix = '#CAP:R:';
const String teamWayPrefix = '#WAY:';
const String teamWrcPrefix = '#WRC:';

/// The longest message TEAM sends (its own split size).
const int teamCompatMaxBytes = 140;

/// Channel text in one of TEAM's formats: never shown as chat.
bool isTeamCompatText(String text) =>
    text.startsWith(teamTelPrefix) ||
    text.startsWith(teamTopoPrefix) ||
    text.startsWith(teamCapPrefix) ||
    text.startsWith(teamWayPrefix) ||
    text.startsWith(teamWrcPrefix);

// ------------------------------------------------------------------ battery

const int _battMinMv = 2750;
const int _battMaxMv = 4280;
const int _battStepMv = 6;

/// A battery voltage as TEAM's byte (1: unknown).
int teamBatteryByte(int? mv) {
  if (mv == null || mv <= 0) return 1;
  final c = mv.clamp(_battMinMv, _battMaxMv);
  return ((c - _battMinMv) ~/ _battStepMv + 2).clamp(2, 254);
}

/// TEAM's battery byte as millivolts, null when unknown.
int? teamBatteryMv(int b) {
  final v = b & 0xFF;
  if (v <= 1 || v == 0xFF) return null;
  return _battMinMv + (v - 2) * _battStepMv;
}

/// Millivolts as the battery percent our Team shows (the same 3.3-4.2 V line
/// it uses for its own radios).
int? teamBatteryPct(int? mv) =>
    mv == null ? null : ((mv - 3300) / (4200 - 3300) * 100).round().clamp(0, 100);

// --------------------------------------------------------------- base64 body

Uint8List? _b64(String s) {
  try {
    final pad = (4 - s.length % 4) % 4;
    return base64.decode(s + '=' * pad);
  } catch (_) {
    return null;
  }
}

String _b64Unpadded(List<int> b) => base64.encode(b).replaceAll('=', '');

// --------------------------------------------------------------------- #TEL

/// A TEAM position (#TEL, or #T read for its position and battery).
class TeamCompatPosition {
  final double lat, lon;
  final int? companionMv, phoneMv;

  /// A radio sending on its own GPS, with no phone.
  final bool autonomous;
  const TeamCompatPosition({
    required this.lat,
    required this.lon,
    this.companionMv,
    this.phoneMv,
    this.autonomous = false,
  });

  /// The battery to show: the radio's, or the phone's when that's all there
  /// is.
  int? get batteryMv => companionMv ?? phoneMv;

  static TeamCompatPosition? parse(String text) {
    final bool topo;
    if (text.startsWith(teamTelPrefix)) {
      topo = false;
    } else if (text.startsWith(teamTopoPrefix)) {
      topo = true;
    } else {
      return null;
    }
    final raw = _b64(
      text.substring(topo ? teamTopoPrefix.length : teamTelPrefix.length),
    );
    if (raw == null || (topo ? raw.length < 11 : raw.length != 11)) {
      return null;
    }
    final d = ByteData.sublistView(raw);
    final lat = d.getInt32(0) / 1e7, lon = d.getInt32(4) / 1e7;
    if (lat.abs() > 90 || lon.abs() > 180) return null;
    final autonomous = raw[9] == 0xFF;
    return TeamCompatPosition(
      lat: lat,
      lon: lon,
      companionMv: teamBatteryMv(raw[8]),
      phoneMv: autonomous ? null : teamBatteryMv(raw[9]),
      autonomous: autonomous,
    );
  }

  /// `#TEL:` for this position (no forwarding asked for, none seen).
  String encodeTel() {
    final b = Uint8List(11);
    final d = ByteData.sublistView(b);
    d.setInt32(0, (lat * 1e7).toInt());
    d.setInt32(4, (lon * 1e7).toInt());
    b[8] = teamBatteryByte(companionMv);
    b[9] = teamBatteryByte(phoneMv);
    b[10] = 1; // needsForwarding 0, maxPathObserved 0
    return '$teamTelPrefix${_b64Unpadded(b)}';
  }
}

// --------------------------------------------------------------------- #CAP

/// A TEAM capability advert: who a sender is (its alias), and its radio key.
class TeamCompatCap {
  final int version;
  final int flags;

  /// 12 lower-case hex, null when not sent.
  final String? keyPrefix;
  final String? appId;

  /// Null for v1; empty: no alias.
  final String? alias;

  const TeamCompatCap({
    this.version = 2,
    this.flags = 0,
    this.keyPrefix,
    this.appId,
    this.alias,
  });

  static final _hex12 = RegExp(r'^[0-9a-f]{12}$');
  static final _hex16 = RegExp(r'^[0-9a-f]{16}$');

  /// Alias limit on the wire, in bytes.
  static const int maxAliasBytes = 24;

  static TeamCompatCap? parse(String text) {
    if (!text.startsWith(teamCapPrefix) ||
        text.startsWith(teamCapRequestPrefix)) {
      return null;
    }
    final parts = text.substring(teamCapPrefix.length).split(':');
    if (parts.length < 2) return null;
    final version = int.tryParse(parts[0]);
    final flags = int.tryParse(parts[1], radix: 16);
    if (version == null || version < 1 || flags == null) return null;
    if (parts.length == 2) {
      return TeamCompatCap(version: version, flags: flags & 0xFF);
    }
    final key = parts[2].toLowerCase();
    // v2 with an app id: key:app:alias...; early v2: key:alias...
    String? app;
    String alias;
    if (parts.length >= 4 &&
        (parts[3] == '-' || _hex16.hasMatch(parts[3].toLowerCase()))) {
      app = parts[3] == '-' ? null : parts[3].toLowerCase();
      alias = parts.sublist(4).join(':');
    } else {
      alias = parts.sublist(3).join(':');
    }
    return TeamCompatCap(
      version: version,
      flags: flags & 0xFF,
      keyPrefix: _hex12.hasMatch(key) ? key : null,
      appId: app,
      alias: alias.trim(),
    );
  }

  String encode() {
    final a = _clipUtf8((alias ?? '').trim(), maxAliasBytes);
    return '$teamCapPrefix$version:'
        '${flags.toRadixString(16).padLeft(2, '0')}:'
        '${keyPrefix ?? '-'}:${appId ?? '-'}:$a';
  }
}

/// `#CAP:R:`: asks one node (by radio name, and key when known) to advert.
class TeamCompatCapRequest {
  final String? keyPrefix;
  final String radioName;
  const TeamCompatCapRequest({required this.radioName, this.keyPrefix});

  static TeamCompatCapRequest? parse(String text) {
    if (!text.startsWith(teamCapRequestPrefix)) return null;
    final body = text.substring(teamCapRequestPrefix.length);
    final i = body.indexOf(':');
    if (i < 0) return null;
    final key = body.substring(0, i).toLowerCase();
    final name = body.substring(i + 1).trim();
    if (name.isEmpty) return null;
    return TeamCompatCapRequest(
      radioName: name,
      keyPrefix: TeamCompatCap._hex12.hasMatch(key) ? key : null,
    );
  }

  String encode() => '$teamCapRequestPrefix${keyPrefix ?? '-'}:$radioName';
}

// ------------------------------------------------------------- #WAY / #WRC

/// TEAM's waypoint types.
enum TeamCompatWaypointType {
  camp,
  meetup,
  danger,
  game,
  stand,
  water,
  vehicle,
  route,
  custom;

  String get wire => name.toUpperCase();

  static TeamCompatWaypointType fromWire(String s) {
    final u = s.trim().toUpperCase();
    for (final t in values) {
      if (t.wire == u) return t;
    }
    return custom;
  }
}

/// A TEAM waypoint or route.
class TeamCompatWaypoint {
  final String? meshId;
  final String name;
  final double lat, lon;
  final String description;
  final TeamCompatWaypointType type;
  final List<(double, double)> route;

  /// ARGB, from the "@C:AARRGGBB" description prefix.
  final int? color;

  const TeamCompatWaypoint({
    required this.name,
    required this.lat,
    required this.lon,
    required this.type,
    this.meshId,
    this.description = '',
    this.route = const [],
    this.color,
  });

  bool get isRoute => type == TeamCompatWaypointType.route;

  static final _part = RegExp(r'^(\d+)/(\d+)$');
  static final _color = RegExp(r'^@C:([0-9A-Fa-f]{8})');

  /// One #WAY message. [part]/[parts] are filled when it's the first of a
  /// route in several messages (the rest come as #WRC).
  static (TeamCompatWaypoint, int part, int parts, String chunk)? parse(
    String text,
  ) {
    if (!text.startsWith(teamWayPrefix)) return null;
    final f = text.substring(teamWayPrefix.length).split('|');
    String? meshId;
    List<String> rest;
    if (f.length >= 6) {
      meshId = f[0].trim().isEmpty ? null : f[0].trim();
      rest = f.sublist(1);
    } else if (f.length == 5) {
      rest = f;
    } else {
      return null;
    }
    final lat = double.tryParse(rest[1]), lon = double.tryParse(rest[2]);
    if (lat == null || lon == null || lat.abs() > 90 || lon.abs() > 180) {
      return null;
    }
    var desc = rest[3];
    int? color;
    final m = _color.firstMatch(desc);
    if (m != null) {
      color = int.parse(m.group(1)!, radix: 16);
      desc = desc.substring(m.end);
    }
    final chunk = rest.length >= 6 ? rest[5] : '';
    var part = 1, parts = 1;
    if (rest.length >= 7) {
      final pm = _part.firstMatch(rest[6]);
      if (pm != null) {
        part = int.parse(pm.group(1)!);
        parts = int.parse(pm.group(2)!);
      }
    }
    return (
      TeamCompatWaypoint(
        meshId: meshId,
        name: rest[0],
        lat: lat,
        lon: lon,
        description: desc,
        type: TeamCompatWaypointType.fromWire(rest[4]),
        route: parts > 1 ? const [] : decodeRoute(chunk),
        color: color,
      ),
      part,
      parts,
      chunk,
    );
  }

  /// "lat,lon~lat,lon" as points (bad pairs skipped).
  static List<(double, double)> decodeRoute(String s) {
    final out = <(double, double)>[];
    for (final c in s.split('~')) {
      final p = c.split(',');
      if (p.length != 2) continue;
      final la = double.tryParse(p[0]), lo = double.tryParse(p[1]);
      if (la == null || lo == null || la.abs() > 90 || lo.abs() > 180) {
        continue;
      }
      out.add((la, lo));
    }
    return out;
  }

  static String encodeRoute(List<(double, double)> pts) => pts
      .map((p) => '${p.$1.toStringAsFixed(6)},${p.$2.toStringAsFixed(6)}')
      .join('~');

  String get _desc {
    final d = _clean(description);
    if (color == null) return d;
    return '@C:${color!.toRadixString(16).padLeft(8, '0').toUpperCase()}$d';
  }

  /// The messages for this waypoint, each within [maxBytes] once [overhead]
  /// bytes (the "RadioName: " the firmware adds) are counted: one #WAY, or
  /// a #WAY and #WRC parts for a long route.
  List<String> encode({int maxBytes = teamCompatMaxBytes, int overhead = 0}) {
    final id = meshId ?? '';
    final head =
        '$teamWayPrefix$id|${_clean(name)}|${lat.toStringAsFixed(6)}|'
        '${lon.toStringAsFixed(6)}|$_desc|${type.wire}|';
    final coords = route.isEmpty ? '' : encodeRoute(route);
    final limit = maxBytes - overhead;
    if (_len(head + coords) <= limit) return ['$head$coords'];
    // Split the coordinates at '~', leaving room for "|NN/NN".
    const partRoom = 6;
    final firstRoom = limit - _len(head) - partRoom;
    final contHead = '$teamWrcPrefix$id|';
    final contRoom = limit - _len(contHead) - partRoom;
    if (firstRoom <= 24 || contRoom <= 24) return ['$head$coords'];
    final pieces = coords.split('~');
    final chunks = <String>[];
    var cur = '';
    for (var i = 0; i < pieces.length; i++) {
      final room = chunks.isEmpty ? firstRoom : contRoom;
      final add = '${pieces[i]}${i < pieces.length - 1 ? '~' : ''}';
      if (cur.isNotEmpty && _len(cur + add) > room) {
        chunks.add(cur);
        cur = '';
      }
      cur += add;
    }
    if (cur.isNotEmpty) chunks.add(cur);
    final n = chunks.length;
    return [
      '$head${chunks[0]}|1/$n',
      for (var i = 1; i < n; i++) '$contHead${chunks[i]}|${i + 1}/$n',
    ];
  }

  /// Field text without TEAM's separator.
  static String _clean(String s) => s.replaceAll('|', '/').replaceAll('\n', ' ');
}

/// A #WRC route part.
class TeamCompatRoutePart {
  final String meshId;
  final String chunk;
  final int part, parts;
  const TeamCompatRoutePart(this.meshId, this.chunk, this.part, this.parts);

  static TeamCompatRoutePart? parse(String text) {
    if (!text.startsWith(teamWrcPrefix)) return null;
    final f = text.substring(teamWrcPrefix.length).split('|');
    if (f.length < 3) return null;
    final m = TeamCompatWaypoint._part.firstMatch(f[2]);
    if (m == null) return null;
    return TeamCompatRoutePart(
      f[0],
      f[1],
      int.parse(m.group(1)!),
      int.parse(m.group(2)!),
    );
  }
}

/// Puts long routes back together from their #WAY and #WRC parts, per sender.
class TeamCompatRouteAssembler {
  final Map<String, (TeamCompatWaypoint, int, Map<int, String>, DateTime)>
  _open = {};

  /// #WRC parts heard before their #WAY.
  final Map<String, (Map<int, String>, DateTime)> _early = {};

  /// A whole waypoint when [text] completes one (or is one), else null.
  TeamCompatWaypoint? accept(String sender, String text, {DateTime? now}) {
    final t = now ?? DateTime.now();
    _open.removeWhere((_, v) => t.difference(v.$4).inSeconds > 120);
    _early.removeWhere((_, v) => t.difference(v.$2).inSeconds > 120);
    final way = TeamCompatWaypoint.parse(text);
    if (way != null) {
      final (w, part, parts, chunk) = way;
      if (parts <= 1) return w;
      final key = '$sender\u0000${w.meshId ?? ''}';
      final chunks = {...?_early.remove(key)?.$1, part: chunk};
      _open[key] = (w, parts, chunks, t);
      return _finish(key);
    }
    final p = TeamCompatRoutePart.parse(text);
    if (p == null) return null;
    final key = '$sender\u0000${p.meshId}';
    final o = _open[key];
    if (o == null) {
      if (_early.length < 16 || _early.containsKey(key)) {
        (_early[key] ??= (<int, String>{}, t)).$1[p.part] = p.chunk;
      }
      return null;
    }
    o.$3[p.part] = p.chunk;
    return _finish(key);
  }

  TeamCompatWaypoint? _finish(String key) {
    final o = _open[key]!;
    if (o.$3.length < o.$2) return null;
    _open.remove(key);
    final keys = o.$3.keys.toList()..sort();
    var all = keys.map((k) => o.$3[k]!).join();
    if (all.endsWith('~')) all = all.substring(0, all.length - 1);
    final w = o.$1;
    return TeamCompatWaypoint(
      meshId: w.meshId,
      name: w.name,
      lat: w.lat,
      lon: w.lon,
      description: w.description,
      type: w.type,
      color: w.color,
      route: TeamCompatWaypoint.decodeRoute(all),
    );
  }
}

int _len(String s) => utf8.encode(s).length;

String _clipUtf8(String s, int maxBytes) {
  if (_len(s) <= maxBytes) return s;
  final r = s.runes.toList();
  while (r.isNotEmpty && _len(String.fromCharCodes(r)) > maxBytes) {
    r.removeLast();
  }
  return String.fromCharCodes(r);
}
