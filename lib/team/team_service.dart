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
import '../models/channel_message.dart';
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

/// Someone crossed a geofence.
class TeamGeofenceEvent {
  final DateTime time;
  final String fence;
  final String who;
  final bool entered;
  final double lat, lon;
  const TeamGeofenceEvent({
    required this.time,
    required this.fence,
    required this.who,
    required this.entered,
    required this.lat,
    required this.lon,
  });

  String get headline => '$who ${entered ? 'entered' : 'left'} $fence';
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
  TeamRole _role = TeamRole.member;
  TeamColor _color = TeamColor.cyan;
  bool _sharePosition = true;
  TeamStatus _status = TeamStatus.none;

  bool get enabled => _enabled;
  String get callsign =>
      _callsign.isNotEmpty ? _callsign : (_connector.selfName ?? 'Me');
  String get callsignSetting => _callsign;
  TeamRole get role => _role;
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
      _role = TeamRole.fromIndex(p.getInt(_kRole) ?? 0);
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
      for (final b64 in p.getStringList(_kShapes) ?? const <String>[]) {
        final sh = TeamShape.tryParse(base64Decode(b64));
        if (sh != null) _shapes[sh.key] = sh;
      }
      for (final b64 in p.getStringList(_kCasevacs) ?? const <String>[]) {
        final c = TeamCasevac.tryParse(base64Decode(b64));
        if (c != null) _casevacs[c.key] = c;
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
    TeamRole? role,
    TeamColor? color,
    bool? sharePosition,
  }) async {
    final identityChanged =
        callsign != null || role != null || color != null || channel != null;
    if (enabled != null) _enabled = enabled;
    if (channel != null) {
      _channelIndex = channel.index;
      _channelName = channel.name;
    }
    if (callsign != null) _callsign = callsign.trim();
    if (role != null) _role = role;
    if (color != null) _color = color;
    if (sharePosition != null) _sharePosition = sharePosition;
    notifyListeners();
    await _save((p) {
      p.setBool(_kEnabled, _enabled);
      if (_channelIndex != null) p.setInt(_kChannelIdx, _channelIndex!);
      if (_channelName != null) p.setString(_kChannelName, _channelName!);
      p.setString(_kCallsign, _callsign);
      p.setInt(_kRole, _role.index);
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
          _onSelfMoved();
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
    _checkGeofences(
      p.senderKey4,
      _members[p.senderKey4]!.callsign,
      p.lat,
      p.lon,
    );
    notifyListeners();
  }

  /// Hook for the TAK bridge.
  void Function(TeamMember m)? onRemotePosition;
  void Function(TeamMarker m)? onMarkerChanged;
  void Function(TeamAlert a)? onAlertChanged;
  void Function(TeamPosition p)? onSelfPosition;
  void Function(TeamShape s)? onShapeChanged;
  void Function(TeamCasevac c)? onCasevacChanged;

  /// New text on the team channel (for the TAK GeoChat bridge).
  void Function(ChannelMessage m)? onTeamChat;

  // ------------------------------------------------------------ bloodhound

  String? _houndMember;
  (double, double, String)? _houndPoint;

  /// What Bloodhound is tracking: a teammate (follows them) or a fixed point.
  ({double lat, double lon, String label})? get bloodhound {
    final nav = navRoute;
    if (nav != null) {
      final (lat, lon) = nav.points[_routeIdx];
      return (
        lat: lat,
        lon: lon,
        label: '${nav.title} · CP${_routeIdx + 1}/${nav.points.length}',
      );
    }
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
    _routeKey = null;
    _houndMember = key4;
    _houndPoint = null;
    notifyListeners();
  }

  void houndPoint(double lat, double lon, String label) {
    _routeKey = null;
    _houndMember = null;
    _houndPoint = (lat, lon, label);
    notifyListeners();
  }

  void stopHound() {
    _routeKey = null;
    _houndMember = null;
    _houndPoint = null;
    notifyListeners();
  }

  // ------------------------------------------------------- route navigation

  String? _routeKey;
  int _routeIdx = 0;

  /// Metres from a checkpoint that count as reaching it.
  static const double routeArriveM = 30;

  /// The route being followed, if any.
  TeamShape? get navRoute {
    final k = _routeKey;
    if (k == null) return null;
    final s = _shapes[k];
    if (s == null || s.deleted || s.points.isEmpty) return null;
    return _routeReverse ? s.copyWith(points: s.points.reversed.toList()) : s;
  }

  bool _routeReverse = false;

  int get navIndex => _routeIdx;

  /// Follows [route] checkpoint by checkpoint with Bloodhound. Starts at the
  /// checkpoint nearest to you, or the first one.
  void navigateRoute(TeamShape route, {bool reverse = false}) {
    if (route.points.isEmpty) return;
    final r = reverse
        ? route.copyWith(points: route.points.reversed.toList())
        : route;
    _houndMember = null;
    _houndPoint = null;
    _routeKey = route.key;
    _routeReverse = reverse;
    _routeIdx = 0;
    final f = fix;
    if (f != null) {
      var best = double.infinity;
      for (var i = 0; i < r.points.length; i++) {
        final d = teamDistanceMeters(
          f.lat,
          f.lon,
          r.points[i].$1,
          r.points[i].$2,
        );
        if (d < best) {
          best = d;
          _routeIdx = i;
        }
      }
    }
    notifyListeners();
  }

  void skipCheckpoint(int delta) {
    final nav = navRoute;
    if (nav == null) return;
    _routeIdx = (_routeIdx + delta).clamp(0, nav.points.length - 1);
    notifyListeners();
  }

  void _advanceRoute() {
    final nav = navRoute;
    final f = fix;
    if (nav == null || f == null) return;
    final (lat, lon) = nav.points[_routeIdx];
    if (teamDistanceMeters(f.lat, f.lon, lat, lon) > routeArriveM) return;
    if (_routeIdx < nav.points.length - 1) {
      _routeIdx++;
      notifyListeners();
      return;
    }
    final title = nav.title;
    stopHound();
    unawaited(
      NotificationService().showTeamAlert(
        id: 'route-done'.hashCode,
        title: 'Route complete',
        body: 'You reached the end of $title.',
      ),
    );
  }

  void _onSelfMoved() {
    _advanceRoute();
    final f = fix;
    if (f != null) _checkGeofences(selfKey4, 'You', f.lat, f.lon);
  }

  // -------------------------------------------------------------- beacons

  final TeamBeaconPolicy policy = const TeamBeaconPolicy();
  DateTime? _lastBeacon;
  TeamFix? _lastBeaconFix;
  bool _forceBeacon = false;
  bool _sending = false;

  DateTime? get lastBeacon => _lastBeacon;

  int? _chatSeenCount;
  int? _chatSeenChannel;

  void _onConnectorChanged() {
    // Channel list or connection changed: refresh UI that depends on it.
    _watchTeamChat();
    notifyListeners();
  }

  /// Passes new team channel text to [onTeamChat] (for the GeoChat bridge).
  void _watchTeamChat() {
    final ch = teamChannel;
    if (ch == null) {
      _chatSeenCount = null;
      return;
    }
    final msgs = _connector.getChannelMessages(ch);
    if (_chatSeenChannel != ch.index || _chatSeenCount == null) {
      _chatSeenChannel = ch.index;
      _chatSeenCount = msgs.length;
      return;
    }
    if (msgs.length > _chatSeenCount!) {
      final start = max(_chatSeenCount!, msgs.length - 10);
      for (var i = start; i < msgs.length; i++) {
        onTeamChat?.call(msgs[i]);
      }
    }
    _chatSeenCount = msgs.length;
  }

  /// Posts text on the team channel (used for TAK chat relayed to the mesh).
  Future<void> postTeamText(String text) async {
    final ch = teamChannel;
    if (ch == null || text.trim().isEmpty) return;
    await _connector.sendChannelMessage(ch, text);
  }

  void _onTick() {
    _onSelfMoved();
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
      role: _role,
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

  // --------------------------------------------- drawings, routes, fences

  static const _kShapes = 'team_shapes_v1';
  final Map<String, TeamShape> _shapes = {};

  List<TeamShape> get shapes =>
      _shapes.values.where((s) => !s.deleted).toList()
        ..sort((a, b) => b.time.compareTo(a.time));

  bool isMyShape(TeamShape s) => s.authorKey4 == selfKey4;

  Future<void> _persistShapes() => _save(
    (p) => p.setStringList(_kShapes, [
      for (final s in _shapes.values) base64Encode(s.encode()),
    ]),
  );

  void _onShape(TeamShape s) {
    final cur = _shapes[s.key];
    if (cur != null && !s.time.isAfter(cur.time) && cur.deleted == s.deleted) {
      return;
    }
    _shapes[s.key] = s;
    unawaited(_persistShapes());
    onShapeChanged?.call(s);
    notifyListeners();
  }

  /// Shares a new drawing/route/geofence (or an edit of [existing]).
  Future<TeamShape> putShape({
    TeamShape? existing,
    required ShapeKind kind,
    required List<(double, double)> points,
    TeamColor color = TeamColor.yellow,
    String label = '',
    TeamGeofence geofence = TeamGeofence.off,
    RouteMethod routeMethod = RouteMethod.walking,
    int radiusM = 0,
  }) async {
    final s = TeamShape(
      authorKey4: existing?.authorKey4 ?? selfKey4,
      shapeId: existing?.shapeId ?? _rng.nextInt(1 << 32),
      kind: kind,
      time: DateTime.now(),
      points: points,
      color: color,
      label: label,
      geofence: geofence,
      routeMethod: routeMethod,
      radiusM: radiusM,
    ).fitted();
    _shapes[s.key] = s;
    unawaited(_persistShapes());
    onShapeChanged?.call(s);
    notifyListeners();
    await _send(s.encode());
    return s;
  }

  Future<void> deleteShape(TeamShape s) async {
    final d = s.copyWith(deleted: true, time: DateTime.now());
    _shapes[s.key] = d;
    if (_routeKey == s.key) stopHound();
    unawaited(_persistShapes());
    onShapeChanged?.call(d);
    notifyListeners();
    if (isMyShape(s)) await _send(d.encode());
  }

  /// Re-sends my drawings, e.g. for someone who joined late.
  Future<int> resendMyShapes() async {
    var n = 0;
    for (final s in shapes) {
      if (!isMyShape(s)) continue;
      if (await _send(s.encode())) n++;
      await Future<void>.delayed(const Duration(seconds: 3));
    }
    return n;
  }

  // Geofences: each phone watches every teammate (and itself) against every
  // geofence and raises a local notification on entry/exit. Nothing extra
  // goes on air.

  final Map<String, bool> _inside = {};
  final List<TeamGeofenceEvent> _geoEvents = [];

  /// Recent geofence crossings, newest first.
  List<TeamGeofenceEvent> get geofenceEvents => _geoEvents.reversed.toList();

  void _checkGeofences(String who, String name, double lat, double lon) {
    for (final s in _shapes.values) {
      if (s.deleted || !s.isGeofence) continue;
      final k = '${s.key}|$who';
      final now = s.contains(lat, lon);
      final was = _inside[k];
      _inside[k] = now;
      if (was == null || was == now) continue;
      if ((now && !s.geofence.onEntry) || (!now && !s.geofence.onExit)) {
        continue;
      }
      final ev = TeamGeofenceEvent(
        time: DateTime.now(),
        fence: s.title,
        who: name,
        entered: now,
        lat: lat,
        lon: lon,
      );
      _geoEvents.add(ev);
      if (_geoEvents.length > 50) _geoEvents.removeAt(0);
      unawaited(
        NotificationService().showTeamAlert(
          id: k.hashCode,
          title: 'Geofence: ${ev.headline}',
          body: s.geofence.label,
        ),
      );
      notifyListeners();
    }
  }

  // ------------------------------------------------------------- CASEVAC

  static const _kCasevacs = 'team_casevac_v1';
  final Map<String, TeamCasevac> _casevacs = {};

  List<TeamCasevac> get casevacs =>
      _casevacs.values.where((c) => !c.deleted).toList()
        ..sort((a, b) => b.time.compareTo(a.time));

  bool isMyCasevac(TeamCasevac c) => c.authorKey4 == selfKey4;

  Future<void> _persistCasevacs() => _save(
    (p) => p.setStringList(_kCasevacs, [
      for (final c in _casevacs.values) base64Encode(c.encode()),
    ]),
  );

  void _onCasevac(TeamCasevac c) {
    final cur = _casevacs[c.key];
    if (cur != null && cur.deleted == c.deleted) return;
    _casevacs[c.key] = c;
    unawaited(_persistCasevacs());
    onCasevacChanged?.call(c);
    notifyListeners();
    if (!c.deleted) {
      unawaited(
        NotificationService().showTeamAlert(
          id: c.key.hashCode,
          title:
              '🚑 ${c.precedenceLabel} CASEVAC'
              '${c.place.isNotEmpty ? ' @${c.place}' : ''}',
          body: [
            '${c.totalPatients} patient${c.totalPatients == 1 ? '' : 's'}',
            _alertWhereLatLon(c.lat, c.lon),
          ].join(' · '),
        ),
      );
    } else {
      unawaited(NotificationService().cancelTeamAlert(c.key.hashCode));
    }
  }

  /// Sends a CASEVAC request three times (collisions happen; duplicates are
  /// dropped by key), optionally also as text.
  Future<TeamCasevac> requestCasevac(
    TeamCasevac draft, {
    bool alsoAsText = false,
  }) async {
    final c = TeamCasevac(
      authorKey4: selfKey4,
      requestId: _rng.nextInt(1 << 32),
      lat: draft.lat,
      lon: draft.lon,
      time: DateTime.now(),
      frequency: draft.frequency,
      callsign: draft.callsign.isEmpty ? callsign : draft.callsign,
      urgent: draft.urgent,
      urgentSurgical: draft.urgentSurgical,
      priority: draft.priority,
      routine: draft.routine,
      convenience: draft.convenience,
      equipment: draft.equipment,
      litter: draft.litter,
      ambulatory: draft.ambulatory,
      security: draft.security,
      marking: draft.marking,
      markingDetail: draft.markingDetail,
      usMilitary: draft.usMilitary,
      usCivilian: draft.usCivilian,
      nonUsMilitary: draft.nonUsMilitary,
      nonUsCivilian: draft.nonUsCivilian,
      epw: draft.epw,
      child: draft.child,
      terrain: draft.terrain,
      nbc: draft.nbc,
      place: draft.place,
      remarks: draft.remarks,
    );
    _casevacs[c.key] = c;
    unawaited(_persistCasevacs());
    onCasevacChanged?.call(c);
    notifyListeners();
    unawaited(() async {
      for (final delay in const [0, 20, 60]) {
        if (delay > 0) await Future<void>.delayed(Duration(seconds: delay));
        if (_casevacs[c.key]?.deleted != false) return;
        await _send(c.encode());
      }
    }());
    final ch = teamChannel;
    if (alsoAsText && ch != null) {
      try {
        await _connector.sendChannelMessage(ch, c.condensedText());
      } catch (_) {}
    }
    return c;
  }

  /// Closes a request (mine: tells the team; others': hides it here).
  Future<void> closeCasevac(TeamCasevac c) async {
    final d = c.copyWith(deleted: true, time: DateTime.now());
    _casevacs[c.key] = d;
    unawaited(_persistCasevacs());
    unawaited(NotificationService().cancelTeamAlert(c.key.hashCode));
    onCasevacChanged?.call(d);
    notifyListeners();
    if (isMyCasevac(c)) await _send(d.encode());
  }

  String _alertWhereLatLon(double lat, double lon) {
    final f = fix;
    if (f == null)
      return '${lat.toStringAsFixed(5)}, ${lon.toStringAsFixed(5)}';
    return teamRangeBearing(
      teamDistanceMeters(f.lat, f.lon, lat, lon),
      teamBearingDeg(f.lat, f.lon, lat, lon),
    );
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
      case teamMsgShape:
        final sh = TeamShape.tryParse(p);
        if (sh != null) _onShape(sh);
      case teamMsgCasevac:
        final c = TeamCasevac.tryParse(p);
        if (c != null) _onCasevac(c);
    }
  }

  @override
  void dispose() {
    _tick.cancel();
    unawaited(_sub.cancel());
    unawaited(_gpsSub?.cancel());
    _connector.removeListener(_onConnectorChanged);
    super.dispose();
  }
}
