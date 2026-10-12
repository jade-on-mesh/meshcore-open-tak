// MeshCore Open TAK - team awareness: positions, pins and alerts shared on
// one private team channel.

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../connector/meshcore_connector.dart';
import '../models/channel.dart';
import '../services/image_chunk_transport.dart'
    show parseChannelDataFrame, respCodeChannelDataRecv;
import '../services/notification_service.dart';
import 'team_wire.dart';

/// One teammate (or this phone), as last heard.
class TeamMember {
  final String key4;
  final TeamPosition position;
  final DateTime heard;
  final List<(double, double, DateTime)> trail;

  const TeamMember({
    required this.key4,
    required this.position,
    required this.heard,
    this.trail = const [],
  });

  String get callsign =>
      position.callsign.isEmpty ? key4.toUpperCase() : position.callsign;

  Duration get age => DateTime.now().difference(heard);

  /// ATAK-style freshness: live, stale, or lost.
  TeamFreshness get freshness => age < const Duration(minutes: 12)
      ? TeamFreshness.live
      : age < const Duration(minutes: 30)
      ? TeamFreshness.stale
      : TeamFreshness.lost;
}

enum TeamFreshness { live, stale, lost }

/// Where this phone's position comes from right now.
enum TeamFixSource { none, phone, radio }

class TeamFix {
  final double lat, lon;
  final double? altitude, speed, heading;
  final double accuracy;
  final DateTime time;
  final TeamFixSource source;
  const TeamFix({
    required this.lat,
    required this.lon,
    required this.time,
    required this.source,
    this.altitude,
    this.speed,
    this.heading,
    this.accuracy = 0,
  });
}

class TeamService extends ChangeNotifier {
  TeamService(this._connector) {
    _sub = _connector.receivedFrames.listen(_onFrame);
    _connector.addListener(_onConnectorChanged);
    unawaited(_load());
    _tick = Timer.periodic(const Duration(seconds: 10), (_) => _onTick());
  }

  final MeshCoreConnector _connector;
  late final StreamSubscription<Uint8List> _sub;
  late final Timer _tick;
  final _rng = Random.secure();

  // ------------------------------------------------------------- settings

  static const _kEnabled = 'team_enabled';
  static const _kChannelIdx = 'team_channel_index';
  static const _kChannelName = 'team_channel_name';
  static const _kCallsign = 'team_callsign';
  static const _kRole = 'team_role';
  static const _kColor = 'team_color';
  static const _kShare = 'team_share_position';
  static const _kStatus = 'team_status';
  static const _kMarkers = 'team_markers_v1';

  bool _enabled = false;
  int? _channelIndex;
  String? _channelName;
  String _callsign = '';
  int _roleId = 0;
  TeamColor _color = TeamColor.cyan;
  bool _sharePosition = true;
  TeamStatus _status = TeamStatus.none;

  bool get enabled => _enabled;
  String get callsign =>
      _callsign.isNotEmpty ? _callsign : (_connector.selfName ?? 'Me');
  String get callsignSetting => _callsign;
  int get roleId => _roleId;
  TeamColor get color => _color;
  bool get sharePosition => _sharePosition;
  TeamStatus get status => _status;

  /// The team channel, if it still exists on the radio with the same name.
  Channel? get teamChannel {
    final i = _channelIndex;
    if (i == null) return null;
    for (final c in _connector.channels) {
      if (c.index == i && (_channelName == null || c.name == _channelName)) {
        return c;
      }
    }
    return null;
  }

  /// Channels that can be a team channel (private ones; public and hashtag
  /// channels would broadcast positions to strangers).
  List<Channel> get candidateChannels => [
    for (final c in _connector.channels)
      if (c.name.isNotEmpty && c.isPrivateChannel) c,
  ];

  /// Ready to send: enabled, connected, a team channel, channel data support.
  bool get active =>
      _enabled && teamChannel != null && _connector.supportsChannelData;

  String? get inactiveReason {
    if (!_enabled) return 'Team mode is off';
    if (teamChannel == null) return 'Pick a private team channel';
    if (!_connector.isConnected) return 'Radio not connected';
    if (!_connector.supportsChannelData) {
      return 'Radio firmware too old for team data (needs 1.15+)';
    }
    return null;
  }

  Future<void> _load() async {
    try {
      final p = await SharedPreferences.getInstance();
      _enabled = p.getBool(_kEnabled) ?? false;
      _channelIndex = p.getInt(_kChannelIdx);
      _channelName = p.getString(_kChannelName);
      _callsign = p.getString(_kCallsign) ?? '';
      _roleId = (p.getInt(_kRole) ?? 0).clamp(0, teamMaxRoleId);
      for (final b64 in p.getStringList(_kRoles) ?? const <String>[]) {
        final d = TeamRoleDef.tryParse(base64Decode(b64));
        if (d != null) _roleDefs[d.roleId] = d;
      }
      _color = TeamColor.fromIndex(p.getInt(_kColor) ?? 0);
      _sharePosition = p.getBool(_kShare) ?? true;
      _status = TeamStatus.fromIndex(p.getInt(_kStatus) ?? 0);
      for (final b64 in p.getStringList(_kMarkers) ?? const <String>[]) {
        final m = TeamMarker.tryParse(base64Decode(b64));
        if (m != null) _markers[m.key] = m;
      }
      for (final b64 in p.getStringList(_kReports) ?? const <String>[]) {
        final r = TeamReport.tryParse(base64Decode(b64));
        if (r != null) _reports[r.key] = r;
      }
    } catch (e) {
      debugPrint('Team settings load failed: $e');
    }
    notifyListeners();
    _updateGps();
  }

  Future<void> _save(void Function(SharedPreferences p) write) async {
    try {
      write(await SharedPreferences.getInstance());
    } catch (_) {}
  }

  Future<void> configure({
    bool? enabled,
    Channel? channel,
    String? callsign,
    int? roleId,
    TeamColor? color,
    bool? sharePosition,
  }) async {
    final identityChanged =
        callsign != null || roleId != null || color != null || channel != null;
    if (enabled != null) _enabled = enabled;
    if (channel != null) {
      _channelIndex = channel.index;
      _channelName = channel.name;
    }
    if (callsign != null) _callsign = callsign.trim();
    if (roleId != null) _roleId = roleId.clamp(0, teamMaxRoleId);
    if (color != null) _color = color;
    if (sharePosition != null) _sharePosition = sharePosition;
    notifyListeners();
    await _save((p) {
      p.setBool(_kEnabled, _enabled);
      if (_channelIndex != null) p.setInt(_kChannelIdx, _channelIndex!);
      if (_channelName != null) p.setString(_kChannelName, _channelName!);
      p.setString(_kCallsign, _callsign);
      p.setInt(_kRole, _roleId);
      p.setInt(_kColor, _color.index);
      p.setBool(_kShare, _sharePosition);
    });
    _updateGps();
    if (identityChanged) _forceBeacon = true;
  }

  Future<void> setStatus(TeamStatus s) async {
    _status = s;
    _forceBeacon = true;
    notifyListeners();
    await _save((p) => p.setInt(_kStatus, s.index));
  }

  String get selfKey4 {
    final k = _connector.selfPublicKey;
    if (k == null || k.length < 4) return '00000000';
    return teamKey4Hex(k);
  }

  // ----------------------------------------------------------------- GPS

  StreamSubscription<Position>? _gpsSub;
  Position? _phoneFix;
  String? _gpsProblem;

  /// Why the phone's GPS isn't in use, if it isn't.
  String? get gpsProblem => _gpsProblem;

  void _updateGps() {
    final want = _enabled && _sharePosition;
    if (want && _gpsSub == null) {
      unawaited(_startGps());
    } else if (!want && _gpsSub != null) {
      unawaited(_gpsSub!.cancel());
      _gpsSub = null;
    }
  }

  Future<void> _startGps() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        _gpsProblem = 'Phone location is off';
        notifyListeners();
        return;
      }
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        _gpsProblem = 'Location permission denied';
        notifyListeners();
        return;
      }
      _gpsProblem = null;
      final settings = defaultTargetPlatform == TargetPlatform.android
          ? AndroidSettings(
              accuracy: LocationAccuracy.high,
              distanceFilter: 5,
              intervalDuration: const Duration(seconds: 5),
              foregroundNotificationConfig: const ForegroundNotificationConfig(
                notificationTitle: 'Sharing your position with your team',
                notificationText:
                    'MeshCore Open TAK sends it over the mesh while team '
                    'mode is on.',
                enableWakeLock: true,
              ),
            )
          : const LocationSettings(
              accuracy: LocationAccuracy.high,
              distanceFilter: 5,
            );
      _gpsSub = Geolocator.getPositionStream(locationSettings: settings).listen(
        (p) {
          _phoneFix = p;
          notifyListeners();
        },
        onError: (Object e) {
          _gpsProblem = 'GPS error: $e';
          _gpsSub = null;
          notifyListeners();
        },
      );
      notifyListeners();
    } catch (e) {
      _gpsProblem = 'GPS unavailable: $e';
      notifyListeners();
    }
  }

  /// This phone's best current position: phone GPS if fresh, else the
  /// radio's own position.
  TeamFix? get fix {
    final p = _phoneFix;
    if (p != null &&
        DateTime.now().difference(p.timestamp) < const Duration(minutes: 2)) {
      return TeamFix(
        lat: p.latitude,
        lon: p.longitude,
        altitude: p.altitude,
        speed: p.speed >= 0 ? p.speed : null,
        heading: p.heading >= 0 && p.speed > 0.5 ? p.heading : null,
        accuracy: p.accuracy,
        time: p.timestamp,
        source: TeamFixSource.phone,
      );
    }
    final lat = _connector.selfLatitude, lon = _connector.selfLongitude;
    if (lat != null && lon != null && (lat != 0 || lon != 0)) {
      return TeamFix(
        lat: lat,
        lon: lon,
        time: DateTime.now(),
        source: TeamFixSource.radio,
      );
    }
    return null;
  }

  // ------------------------------------------------------------ members

  final Map<String, TeamMember> _members = {};

  /// Teammates heard on the team channel, newest first (not including me).
  List<TeamMember> get members =>
      _members.values.toList()..sort((a, b) => b.heard.compareTo(a.heard));

  TeamMember? memberByKey(String key4) => _members[key4];

  static const int _trailMax = 300;

  void _onPosition(TeamPosition p) {
    final prev = _members[p.senderKey4];
    if (prev == null) _newcomerHeard();
    final trail = [...?prev?.trail];
    if (trail.isEmpty ||
        teamDistanceMeters(trail.last.$1, trail.last.$2, p.lat, p.lon) > 3) {
      trail.add((p.lat, p.lon, DateTime.now()));
      if (trail.length > _trailMax) trail.removeAt(0);
    }
    _members[p.senderKey4] = TeamMember(
      key4: p.senderKey4,
      position: p,
      heard: DateTime.now(),
      trail: trail,
    );
    onRemotePosition?.call(_members[p.senderKey4]!);
    notifyListeners();
  }

  /// Hook for the TAK bridge.
  void Function(TeamMember m)? onRemotePosition;
  void Function(TeamMarker m)? onMarkerChanged;
  void Function(TeamAlert a)? onAlertChanged;
  void Function(TeamPosition p)? onSelfPosition;

  // ------------------------------------------------------------ bloodhound

  String? _houndMember;
  (double, double, String)? _houndPoint;

  /// What Bloodhound is tracking: a teammate (follows them) or a fixed point.
  ({double lat, double lon, String label})? get bloodhound {
    final k = _houndMember;
    if (k != null) {
      final m = _members[k];
      if (m == null) return null;
      return (lat: m.position.lat, lon: m.position.lon, label: m.callsign);
    }
    final p = _houndPoint;
    return p == null ? null : (lat: p.$1, lon: p.$2, label: p.$3);
  }

  void houndMember(String key4) {
    _houndMember = key4;
    _houndPoint = null;
    notifyListeners();
  }

  void houndPoint(double lat, double lon, String label) {
    _houndMember = null;
    _houndPoint = (lat, lon, label);
    notifyListeners();
  }

  void stopHound() {
    _houndMember = null;
    _houndPoint = null;
    notifyListeners();
  }

  // -------------------------------------------------------------- beacons

  final TeamBeaconPolicy policy = const TeamBeaconPolicy();
  DateTime? _lastBeacon;
  TeamFix? _lastBeaconFix;
  bool _forceBeacon = false;
  bool _sending = false;

  DateTime? get lastBeacon => _lastBeacon;

  void _onConnectorChanged() {
    // Channel list or connection changed: refresh UI that depends on it.
    notifyListeners();
  }

  void _onTick() {
    if (!active || !_sharePosition || _sending) return;
    final f = fix;
    if (f == null) return;
    final last = _lastBeaconFix;
    final since = _lastBeacon == null
        ? null
        : DateTime.now().difference(_lastBeacon!);
    double? turn;
    if (last?.heading != null && f.heading != null) {
      turn = ((f.heading! - last!.heading! + 540) % 360) - 180;
    }
    final send =
        _forceBeacon ||
        policy.shouldSend(
          sinceLast: since,
          metersSinceLast: last == null
              ? null
              : teamDistanceMeters(last.lat, last.lon, f.lat, f.lon),
          speedMps: f.speed,
          headingChangeDeg: turn,
        ) ||
        (_activeOwnAlert != null &&
            since != null &&
            since >= const Duration(seconds: 60));
    if (send) unawaited(sendPosition());
  }

  TeamPosition? _selfPosition() {
    final f = fix;
    if (f == null) return null;
    final mv = _connector.batteryMillivolts;
    int? batt;
    if (mv != null && mv > 0) {
      batt = ((mv - 3300) / (4200 - 3300) * 100).round().clamp(0, 100);
    }
    return TeamPosition(
      senderKey4: selfKey4,
      lat: f.lat,
      lon: f.lon,
      altitudeM: f.altitude?.round(),
      speedMps: f.speed,
      headingDeg: f.heading,
      accuracyM: f.accuracy.round(),
      batteryPct: batt,
      roleId: _roleId,
      color: _color,
      status: _status,
      callsign: callsign,
      fromRadio: f.source == TeamFixSource.radio,
      sosActive: _activeOwnAlert != null,
    );
  }

  /// Sends this phone's position now.
  Future<bool> sendPosition() async {
    final p = _selfPosition();
    if (p == null || !active) return false;
    _sending = true;
    _forceBeacon = false;
    try {
      final ok = await _send(p.encode());
      if (ok) {
        _lastBeacon = DateTime.now();
        _lastBeaconFix = fix;
        onSelfPosition?.call(p);
        notifyListeners();
      }
      return ok;
    } finally {
      _sending = false;
    }
  }

  Future<bool> _send(Uint8List payload) async {
    final ch = teamChannel;
    if (ch == null || !_connector.supportsChannelData) return false;
    try {
      return await _connector.sendChannelDataBlobs(
        [payload],
        channelIndex: ch.index,
        dataType: teamChannelDataType,
        interChunkDelay: Duration.zero,
      );
    } catch (e) {
      debugPrint('Team send failed: $e');
      return false;
    }
  }

  /// Sends a position from outside the mesh (a TAK user) to the team.
  Future<bool> relayExternalPosition(TeamPosition p) async {
    if (!active) return false;
    return _send(p.encode());
  }

  /// Sends my own position to the TAK bridge even if the mesh is idle.
  TeamPosition? get selfPositionForBridge => _selfPosition();

  // -------------------------------------------------------------- markers

  final Map<String, TeamMarker> _markers = {};

  List<TeamMarker> get markers =>
      _markers.values.where((m) => !m.deleted).toList()
        ..sort((a, b) => b.time.compareTo(a.time));

  bool isMine(TeamMarker m) => m.authorKey4 == selfKey4;

  Future<void> _persistMarkers() => _save(
    (p) => p.setStringList(_kMarkers, [
      for (final m in _markers.values) base64Encode(m.encode()),
    ]),
  );

  void _onMarker(TeamMarker m) {
    final cur = _markers[m.key];
    if (cur != null && !m.time.isAfter(cur.time) && cur.deleted == m.deleted) {
      return;
    }
    _markers[m.key] = m;
    unawaited(_persistMarkers());
    onMarkerChanged?.call(m);
    notifyListeners();
  }

  /// Drops (or updates) a pin and shares it with the team.
  Future<TeamMarker> putMarker({
    TeamMarker? existing,
    required MarkerKind kind,
    required double lat,
    required double lon,
    String label = '',
    String note = '',
    TeamAttachment? attachment,
    bool clearAttachment = false,
  }) async {
    final m = existing == null
        ? TeamMarker(
            authorKey4: selfKey4,
            markerId: _rng.nextInt(1 << 32),
            kind: kind,
            lat: lat,
            lon: lon,
            time: DateTime.now(),
            label: label,
            note: note,
            attachment: attachment,
          )
        : existing.copyWith(
            kind: kind,
            lat: lat,
            lon: lon,
            label: label,
            note: note,
            time: DateTime.now(),
            attachment: attachment,
            clearAttachment: clearAttachment,
          );
    _markers[m.key] = m;
    unawaited(_persistMarkers());
    onMarkerChanged?.call(m);
    notifyListeners();
    await _send(m.encode());
    return m;
  }

  Future<void> deleteMarker(TeamMarker m) async {
    final d = m.copyWith(deleted: true, time: DateTime.now());
    _markers[m.key] = d;
    unawaited(_persistMarkers());
    onMarkerChanged?.call(d);
    notifyListeners();
    if (isMine(m)) await _send(d.encode());
  }

  /// Re-sends my pins, e.g. for someone who joined late.
  Future<int> resendMyMarkers() async {
    var n = 0;
    for (final m in _markers.values) {
      if (!isMine(m)) continue;
      if (await _send(m.encode())) n++;
      await Future<void>.delayed(const Duration(seconds: 3));
    }
    return n;
  }

  /// Adds a marker that came from outside the mesh (TAK), without sending.
  void putExternalMarker(TeamMarker m) => _onMarker(m);

  // ---------------------------------------------------------------- roles
  //
  // The team can rename the nine default roles, give any role an icon, and
  // add up to 16 roles of its own. Each role's newest edit wins and is shared
  // on the team channel, so every phone (and a T-Deck's roster) agrees.

  static const _kRoles = 'team_roles_v1';
  final Map<int, TeamRoleDef> _roleDefs = {};
  Timer? _roleShareTimer;
  DateTime? _lastRoleShare;

  /// Roles to choose from: the nine defaults, then the team's added roles.
  List<int> get roleIds => [
    for (var i = 0; i < teamFirstAddedRole; i++) i,
    for (var i = teamFirstAddedRole; i <= teamMaxRoleId; i++)
      if (_roleDefs[i] != null && !_roleDefs[i]!.reset) i,
  ];

  bool get canAddRole => roleIds.length < teamMaxRoleId + 1;

  /// The team's edit of role [id], if any is in force.
  TeamRoleDef? roleEdit(int id) {
    final d = _roleDefs[id];
    return d == null || d.reset ? null : d;
  }

  bool isAddedRole(int id) => id >= teamFirstAddedRole;

  String defaultRoleName(int id) =>
      id < teamFirstAddedRole ? TeamRole.fromIndex(id).label : 'Role $id';

  String roleName(int id) {
    final d = roleEdit(id);
    if (d != null && d.name.trim().isNotEmpty) return d.name.trim();
    return defaultRoleName(id);
  }

  /// The role's icon from the icon library, or 0 for its default icon.
  int roleIconId(int id) => roleEdit(id)?.iconId ?? 0;

  Future<void> _persistRoles() => _save(
    (p) => p.setStringList(_kRoles, [
      for (final d in _roleDefs.values) base64Encode(d.encode()),
    ]),
  );

  void _onRoleDef(TeamRoleDef d) {
    // Someone else is already sharing the table with a newcomer.
    _roleShareTimer?.cancel();
    _roleShareTimer = null;
    final cur = _roleDefs[d.roleId];
    if (cur != null && !d.beats(cur)) return;
    _roleDefs[d.roleId] = d;
    unawaited(_persistRoles());
    notifyListeners();
  }

  Future<void> _putRoleDef(TeamRoleDef d) async {
    _roleDefs[d.roleId] = d;
    unawaited(_persistRoles());
    notifyListeners();
    await _send(d.encode());
  }

  /// Renames role [id] and/or gives it an icon, for the whole team.
  Future<void> editRole(int id, {required String name, required int iconId}) =>
      _putRoleDef(
        TeamRoleDef(
          authorKey4: selfKey4,
          roleId: id,
          time: _editTime(id),
          iconId: iconId,
          name: name.trim(),
        ),
      );

  /// A default role back to its own name and icon; an added role removed.
  Future<void> resetRole(int id) async {
    await _putRoleDef(
      TeamRoleDef(
        authorKey4: selfKey4,
        roleId: id,
        time: _editTime(id),
        reset: true,
      ),
    );
    if (isAddedRole(id) && _roleId == id) await configure(roleId: 0);
  }

  /// Adds a role (the next free id), or null when all 16 are in use.
  Future<int?> addRole({required String name, required int iconId}) async {
    for (var i = teamFirstAddedRole; i <= teamMaxRoleId; i++) {
      if (roleEdit(i) != null) continue;
      await editRole(i, name: name, iconId: iconId);
      return i;
    }
    return null;
  }

  /// A time that beats the current edit even if a clock runs behind.
  DateTime _editTime(int id) {
    final now = DateTime.now();
    final cur = _roleDefs[id]?.time;
    if (cur != null && !now.isAfter(cur)) {
      return cur.add(const Duration(seconds: 1));
    }
    return now;
  }

  /// Sends the team's role names and icons, e.g. for someone who joined late.
  Future<int> shareRoles() async {
    _roleShareTimer?.cancel();
    _roleShareTimer = null;
    _lastRoleShare = DateTime.now();
    var n = 0;
    final defs = _roleDefs.values.toList()
      ..sort((a, b) => a.roleId.compareTo(b.roleId));
    for (final d in defs) {
      if (n > 0) await Future<void>.delayed(const Duration(seconds: 3));
      if (await _send(d.encode())) n++;
    }
    return n;
  }

  /// A teammate we have not heard before: after a random wait, share the
  /// role table unless someone else does first (or we did recently).
  void _newcomerHeard() {
    if (_roleDefs.isEmpty || !active || _roleShareTimer != null) return;
    final last = _lastRoleShare;
    if (last != null &&
        DateTime.now().difference(last) < const Duration(minutes: 10)) {
      return;
    }
    _roleShareTimer = Timer(Duration(seconds: 20 + _rng.nextInt(100)), () {
      _roleShareTimer = null;
      if (active) unawaited(shareRoles());
    });
  }

  // -------------------------------------------------------------- reports

  static const _kReports = 'team_reports_v1';
  final Map<String, TeamReport> _reports = {};

  List<TeamReport> get reports =>
      _reports.values.toList()
        ..sort((a, b) => b.observed.compareTo(a.observed));

  void Function(TeamReport r)? onReportChanged;

  Future<void> _persistReports() => _save(
    (p) => p.setStringList(_kReports, [
      for (final r in _reports.values) base64Encode(r.encode()),
    ]),
  );

  void _onReport(TeamReport r) {
    if (_reports.containsKey(r.key)) return;
    _reports[r.key] = r;
    unawaited(_persistReports());
    onReportChanged?.call(r);
    notifyListeners();
    unawaited(
      NotificationService().showTeamAlert(
        id: r.key.hashCode,
        title:
            '${r.urgency.dot} ${r.kind.label}: ${r.urgency.label} @${r.placeLabel}',
        body: r.condensedLines().skip(3).join('  '),
      ),
    );
  }

  /// Files a SALUTE report and sends it to the team.
  Future<TeamReport> fileReport({
    required double lat,
    required double lon,
    required DateTime observed,
    TeamAffiliation affiliation = TeamAffiliation.unknown,
    TeamUrgency urgency = TeamUrgency.observed,
    int vehicles = 0,
    int people = 0,
    String place = '',
    bool alsoAsText = false,
    String size = '',
    String activity = '',
    String unit = '',
    String equipment = '',
    TeamAttachment? attachment,
  }) async {
    final r = TeamReport(
      authorKey4: selfKey4,
      reportId: _rng.nextInt(1 << 32),
      affiliation: affiliation,
      urgency: urgency,
      vehicles: vehicles,
      people: people,
      place: place,
      lat: lat,
      lon: lon,
      observed: observed,
      size: size,
      activity: activity,
      unit: unit,
      equipment: equipment,
      attachment: attachment,
    );
    _reports[r.key] = r;
    unawaited(_persistReports());
    onReportChanged?.call(r);
    notifyListeners();
    await _send(r.encode());
    final ch = teamChannel;
    if (alsoAsText && ch != null) {
      // For teammates on MeshCore apps without VOX.
      try {
        await _connector.sendChannelMessage(ch, r.condensedText());
      } catch (_) {}
    }
    return r;
  }

  Future<void> deleteReport(TeamReport r) async {
    _reports.remove(r.key);
    unawaited(_persistReports());
    notifyListeners();
  }

  // --------------------------------------------------------------- alerts

  final Map<String, TeamAlert> _alerts = {};
  final Set<String> _acknowledged = {};
  TeamAlert? _activeOwnAlert;

  TeamAlert? get activeOwnAlert => _activeOwnAlert;

  /// Teammates' active alerts, newest first.
  List<TeamAlert> get activeAlerts =>
      _alerts.values.where((a) => a.active).toList().reversed.toList();

  /// Active alerts this user hasn't dismissed yet (drives the alarm screen).
  List<TeamAlert> get unacknowledgedAlerts => [
    for (final a in activeAlerts)
      if (!_acknowledged.contains(a.key)) a,
  ];

  void acknowledge(TeamAlert a) {
    _acknowledged.add(a.key);
    notifyListeners();
  }

  void _onAlert(TeamAlert a) {
    final prev = _alerts[a.key];
    _alerts[a.key] = a;
    if (a.active && prev?.active != true) {
      unawaited(
        NotificationService().showTeamAlert(
          id: a.key.hashCode,
          title:
              '${a.type.label}: ${a.callsign.isEmpty ? a.senderKey4 : a.callsign}',
          body: a.note.isNotEmpty ? a.note : _alertWhere(a),
        ),
      );
    } else if (!a.active) {
      unawaited(NotificationService().cancelTeamAlert(a.key.hashCode));
    }
    onAlertChanged?.call(a);
    notifyListeners();
  }

  String _alertWhere(TeamAlert a) {
    final f = fix;
    if (a.lat == null || a.lon == null) return 'No position';
    if (f == null) {
      return '${a.lat!.toStringAsFixed(5)}, ${a.lon!.toStringAsFixed(5)}';
    }
    return teamRangeBearing(
      teamDistanceMeters(f.lat, f.lon, a.lat!, a.lon!),
      teamBearingDeg(f.lat, f.lon, a.lat!, a.lon!),
    );
  }

  /// Raises an alert to the team. It is sent three times (radio collisions
  /// happen), then rides on every position update until cancelled.
  Future<void> raiseAlert(TeamAlertType type, {String note = ''}) async {
    final f = fix;
    final a = TeamAlert(
      senderKey4: selfKey4,
      alertId: _rng.nextInt(1 << 16),
      active: true,
      type: type,
      lat: f?.lat,
      lon: f?.lon,
      accuracyM: f?.accuracy.round() ?? 0,
      callsign: callsign,
      note: note,
    );
    _activeOwnAlert = a;
    onAlertChanged?.call(a);
    notifyListeners();
    for (final delay in const [0, 15, 45]) {
      if (_activeOwnAlert?.alertId != a.alertId) return;
      if (delay > 0) await Future<void>.delayed(Duration(seconds: delay));
      if (_activeOwnAlert?.alertId != a.alertId) return;
      await _send(a.encode());
    }
  }

  Future<void> cancelAlert() async {
    final a = _activeOwnAlert;
    if (a == null) return;
    _activeOwnAlert = null;
    final c = TeamAlert(
      senderKey4: a.senderKey4,
      alertId: a.alertId,
      active: false,
      type: a.type,
      lat: a.lat,
      lon: a.lon,
      callsign: a.callsign,
      note: a.note,
    );
    onAlertChanged?.call(c);
    notifyListeners();
    await _send(c.encode());
    await Future<void>.delayed(const Duration(seconds: 10));
    await _send(c.encode());
  }

  // ---------------------------------------------------------- receiving

  void _onFrame(Uint8List frame) {
    if (frame.isEmpty || frame[0] != respCodeChannelDataRecv) return;
    final parsed = parseChannelDataFrame(frame);
    if (parsed == null || parsed.dataType != teamChannelDataType) return;
    final ch = teamChannel;
    if (ch == null || parsed.channelIndex != ch.index) return;
    handlePayload(parsed.payload);
  }

  /// Handles one team payload (exposed for tests).
  @visibleForTesting
  void handlePayload(Uint8List p) {
    final peek = teamPeek(p);
    if (peek == null) return;
    final (type, sender) = peek;
    if (sender == selfKey4) return;
    switch (type) {
      case teamMsgPosition:
        final pos = TeamPosition.tryParse(p);
        if (pos != null) _onPosition(pos);
      case teamMsgAlert:
        final a = TeamAlert.tryParse(p);
        if (a != null) _onAlert(a);
      case teamMsgMarker:
        final m = TeamMarker.tryParse(p);
        if (m != null) _onMarker(m);
      case teamMsgReport:
        final r = TeamReport.tryParse(p);
        if (r != null) _onReport(r);
      case teamMsgRole:
        final d = TeamRoleDef.tryParse(p);
        if (d != null) _onRoleDef(d);
    }
  }

  @override
  void dispose() {
    _tick.cancel();
    _roleShareTimer?.cancel();
    unawaited(_sub.cancel());
    unawaited(_gpsSub?.cancel());
    _connector.removeListener(_onConnectorChanged);
    super.dispose();
  }
}
