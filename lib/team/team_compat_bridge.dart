// MeshCore Open TAK - MeshCore TEAM interop on the team channel.
//
// Hears MeshCore TEAM's channel text (team_compat.dart) on our team channel
// and shows it the way our own Team traffic shows: TEAM users as team members
// (their alias as the callsign), their waypoints as our markers, their routes
// as our route drawings. Their text never shows as chat.
//
// Once a TEAM user has been heard on the team channel (and for 12 hours
// after), this also speaks TEAM's formats so they see us: a #TEL with each of
// our position beacons (at most every 15 s), a #CAP with our callsign, our
// new markers and routes as #WAY, and an advert when one of them asks for it
// (#CAP:R). Before that, nothing extra goes on the air.
//
// See documentation/meshcore-team.md.

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../connector/meshcore_connector.dart';
import '../connector/meshcore_protocol.dart';
import 'team_compat.dart';
import 'team_wire.dart';

/// What TeamService gives the bridge.
abstract class TeamCompatHost {
  int? get teamChannelIndex;
  String get selfKey4;
  String get callsign;
  bool get sharesPosition;
  ({double lat, double lon})? get compatFix;
  void acceptCompatPosition(TeamPosition p);
  void forgetCompatMember(String key4);
  void putExternalMarker(TeamMarker m);
  void putExternalShape(TeamShape s);
  void compatChanged();
}

class TeamCompatBridge {
  TeamCompatBridge(this._host, this._connector) {
    unawaited(_load());
  }

  final TeamCompatHost _host;
  final MeshCoreConnector _connector;
  final Random _rng = Random();

  static const _kHeard = 'team_compat_heard_ms';
  static const Duration activeFor = Duration(hours: 12);

  DateTime? _heardAt;

  /// Radio name -> key4 and alias, from #CAP (or a contact by that name).
  final Map<String, String> _keyByName = {};
  final Map<String, String> _aliasByName = {};

  /// key4 each TEAM sender's member is shown under now.
  final Map<String, String> _shownKey = {};
  final Map<String, TeamCompatPosition> _lastPos = {};
  final TeamCompatRouteAssembler _routes = TeamCompatRouteAssembler();

  DateTime? _telSent, _capSent, _advertSent;
  String? _capAlias;

  /// A TEAM user was heard on the team channel in the last 12 hours: we speak
  /// TEAM's formats too.
  bool get active =>
      _heardAt != null && DateTime.now().difference(_heardAt!) < activeFor;

  DateTime? get heardAt => _heardAt;

  /// TEAM users heard (radio names), for the Team screen.
  Iterable<String> get heardNames => _shownKey.keys;

  Future<void> _load() async {
    try {
      final p = await SharedPreferences.getInstance();
      final ms = p.getInt(_kHeard);
      if (ms != null) _heardAt = DateTime.fromMillisecondsSinceEpoch(ms);
    } catch (_) {}
  }

  void _markHeard() {
    final was = active;
    _heardAt = DateTime.now();
    unawaited(() async {
      try {
        final p = await SharedPreferences.getInstance();
        await p.setInt(_kHeard, _heardAt!.millisecondsSinceEpoch);
      } catch (_) {}
    }());
    if (!was) {
      // Just found them: introduce ourselves after a moment (spread out, so
      // several of us don't answer at once).
      unawaited(
        Future<void>.delayed(
          Duration(milliseconds: 2000 + _rng.nextInt(6000)),
          () => sendCap(),
        ),
      );
      _host.compatChanged();
    }
  }

  // ------------------------------------------------------------- receiving

  /// From the connector, for every channel text before it's stored: true
  /// swallows it (it's TEAM's, and isn't shown as chat).
  bool onChannelText(int channelIndex, String senderName, String text) {
    if (!isTeamCompatText(text)) return false;
    final pos = TeamCompatPosition.parse(text);
    final cap = pos == null ? TeamCompatCap.parse(text) : null;
    final req = pos == null && cap == null
        ? TeamCompatCapRequest.parse(text)
        : null;
    final isWay =
        text.startsWith(teamWayPrefix) || text.startsWith(teamWrcPrefix);
    if (pos == null && cap == null && req == null && !isWay) {
      return false; // not really TEAM's: leave it as chat
    }
    if (channelIndex != _host.teamChannelIndex) return true;
    final self = _connector.selfName;
    if (senderName.isEmpty || senderName == self) return true;
    _markHeard();
    if (pos != null) {
      _onPosition(senderName, pos);
    } else if (cap != null) {
      _onCap(senderName, cap);
    } else if (req != null) {
      _onRequest(req);
    } else {
      final w = _routes.accept(senderName, text);
      if (w != null) _onWaypoint(senderName, w);
    }
    return true;
  }

  /// The key4 a TEAM sender shows under: its #CAP key, else a contact with
  /// its name, else one made from the name.
  String _key4For(String name) {
    final k = _keyByName[name];
    if (k != null) return k;
    for (final c in _connector.contacts) {
      if (c.name == name && c.publicKeyHex.length >= 8) {
        return c.publicKeyHex.substring(0, 8).toLowerCase();
      }
    }
    return _fnv32(utf8.encode('TEAM:$name')).toRadixString(16).padLeft(8, '0');
  }

  void _onPosition(String name, TeamCompatPosition p) {
    _lastPos[name] = p;
    _showMember(name);
  }

  void _showMember(String name) {
    final p = _lastPos[name];
    if (p == null) return;
    final key4 = _key4For(name);
    final old = _shownKey[name];
    if (old != null && old != key4) _host.forgetCompatMember(old);
    _shownKey[name] = key4;
    final alias = _aliasByName[name];
    _host.acceptCompatPosition(
      TeamPosition(
        senderKey4: key4,
        lat: p.lat,
        lon: p.lon,
        batteryPct: teamBatteryPct(p.batteryMv),
        callsign: alias != null && alias.isNotEmpty ? alias : name,
        fromRadio: p.autonomous,
      ),
    );
  }

  void _onCap(String name, TeamCompatCap c) {
    final key = c.keyPrefix;
    if (key != null) _keyByName[name] = key.substring(0, 8);
    if (c.alias != null) _aliasByName[name] = c.alias!;
    _showMember(name); // the new callsign or key, if we've a position
  }

  void _onRequest(TeamCompatCapRequest r) {
    final self = _connector.selfName;
    final myKey = _connector.selfPublicKeyHex.toLowerCase();
    final forMe =
        r.radioName == self &&
        (r.keyPrefix == null || myKey.startsWith(r.keyPrefix!));
    if (!forMe) return;
    final now = DateTime.now();
    if (_advertSent != null &&
        now.difference(_advertSent!) < const Duration(minutes: 10)) {
      return;
    }
    _advertSent = now;
    unawaited(() async {
      await Future<void>.delayed(
        Duration(milliseconds: 1000 + _rng.nextInt(3000)),
      );
      try {
        await _connector.sendSelfAdvert(flood: true);
      } catch (_) {}
      await sendCap(force: true);
    }());
  }

  void _onWaypoint(String name, TeamCompatWaypoint w) {
    final key4 = _key4For(name);
    final id = _fnv32(utf8.encode(w.meshId ?? 'name:${w.name}'));
    final now = DateTime.now();
    if (w.isRoute) {
      final pts = w.route.isNotEmpty ? w.route : [(w.lat, w.lon)];
      if (pts.length < 2) return;
      _host.putExternalShape(
        TeamShape(
          authorKey4: key4,
          shapeId: id,
          kind: ShapeKind.route,
          time: now,
          points: pts,
          color: w.color == null ? TeamColor.purple : nearestTeamColor(w.color!),
          label: w.name,
        ),
      );
      return;
    }
    _host.putExternalMarker(
      TeamMarker(
        authorKey4: key4,
        markerId: id,
        kind: markerKindForTeam(w.type),
        lat: w.lat,
        lon: w.lon,
        time: now,
        label: w.name,
        note: w.description,
      ),
    );
  }

  // --------------------------------------------------------------- sending

  int get _overhead => utf8.encode('${_connector.selfName ?? ''}: ').length;

  Future<bool> _sendText(String text) async {
    final idx = _host.teamChannelIndex;
    if (idx == null || !_connector.isConnected) return false;
    try {
      // Straight to the radio: not added to our own chat.
      await _connector.sendFrame(buildSendChannelTextMsgFrame(idx, text));
      return true;
    } catch (e) {
      debugPrint('TEAM compat send failed: $e');
      return false;
    }
  }

  /// After one of our position beacons: the same as TEAM's #TEL.
  Future<void> afterBeacon() async {
    if (!active || !_host.sharesPosition) return;
    final f = _host.compatFix;
    if (f == null) return;
    final now = DateTime.now();
    if (_telSent != null &&
        now.difference(_telSent!) < const Duration(seconds: 15)) {
      return;
    }
    _telSent = now;
    final mv = _connector.batteryMillivolts;
    await _sendText(
      TeamCompatPosition(lat: f.lat, lon: f.lon, companionMv: mv).encodeTel(),
    );
    // Our #CAP: when the callsign changed, and every 6 hours.
    if (_capAlias != _host.callsign ||
        _capSent == null ||
        now.difference(_capSent!) > const Duration(hours: 6)) {
      await Future<void>.delayed(const Duration(seconds: 2));
      await sendCap();
    }
  }

  /// Our #CAP: our callsign as the alias, our radio key.
  Future<void> sendCap({bool force = false}) async {
    if (!active && !force) return;
    final key = _connector.selfPublicKeyHex.toLowerCase();
    final ok = await _sendText(
      TeamCompatCap(
        keyPrefix: key.length >= 12 ? key.substring(0, 12) : null,
        alias: _host.callsign,
      ).encode(),
    );
    if (ok) {
      _capSent = DateTime.now();
      _capAlias = _host.callsign;
    }
  }

  /// One of our markers, as a TEAM waypoint.
  Future<void> ownMarker(TeamMarker m) async {
    if (!active || m.deleted) return;
    await _sendWay(
      TeamCompatWaypoint(
        meshId: '${m.authorKey4}-${m.markerId.toRadixString(16)}',
        name: m.label.isNotEmpty ? m.label : m.kind.label,
        lat: m.lat,
        lon: m.lon,
        description: m.note,
        type: teamTypeForMarker(m.kind),
      ),
    );
  }

  /// One of our routes (a drawn route or line), as a TEAM route.
  Future<void> ownShape(TeamShape s) async {
    if (!active || s.deleted || s.points.length < 2) return;
    if (s.kind != ShapeKind.route && s.kind != ShapeKind.line) return;
    await _sendWay(
      TeamCompatWaypoint(
        meshId: '${s.authorKey4}-${s.shapeId.toRadixString(16)}',
        name: s.label.isNotEmpty ? s.label : s.kind.label,
        lat: s.points.first.$1,
        lon: s.points.first.$2,
        type: TeamCompatWaypointType.route,
        color: s.color.argb,
        route: s.points,
      ),
    );
  }

  Future<void> _sendWay(TeamCompatWaypoint w) async {
    final msgs = w.encode(overhead: _overhead);
    for (var i = 0; i < msgs.length; i++) {
      if (i > 0) await Future<void>.delayed(const Duration(milliseconds: 1500));
      if (!await _sendText(msgs[i])) return;
    }
  }
}

// ------------------------------------------------------------- the mapping

/// TEAM's waypoint types as our marker kinds (our look, the closest kind).
MarkerKind markerKindForTeam(TeamCompatWaypointType t) => switch (t) {
  TeamCompatWaypointType.camp => MarkerKind.staging,
  TeamCompatWaypointType.meetup => MarkerKind.lastKnown,
  TeamCompatWaypointType.danger => MarkerKind.hazard,
  TeamCompatWaypointType.water => MarkerKind.water,
  _ => MarkerKind.point,
};

/// Our marker kinds as TEAM's waypoint types.
TeamCompatWaypointType teamTypeForMarker(MarkerKind k) => switch (k) {
  MarkerKind.staging => TeamCompatWaypointType.camp,
  MarkerKind.lastKnown ||
  MarkerKind.landingZone => TeamCompatWaypointType.meetup,
  MarkerKind.hazard => TeamCompatWaypointType.danger,
  MarkerKind.water => TeamCompatWaypointType.water,
  _ => TeamCompatWaypointType.custom,
};

/// The team colour nearest an ARGB colour.
TeamColor nearestTeamColor(int argb) {
  int ch(int v, int s) => (v >> s) & 0xFF;
  var best = TeamColor.purple;
  var bestD = 1 << 30;
  for (final c in TeamColor.values) {
    final dr = ch(c.argb, 16) - ch(argb, 16);
    final dg = ch(c.argb, 8) - ch(argb, 8);
    final db = ch(c.argb, 0) - ch(argb, 0);
    final d = dr * dr + dg * dg + db * db;
    if (d < bestD) {
      bestD = d;
      best = c;
    }
  }
  return best;
}

int _fnv32(List<int> bytes) {
  var h = 0x811c9dc5;
  for (final b in bytes) {
    h ^= b;
    h = (h * 0x01000193) & 0xFFFFFFFF;
  }
  return h;
}
