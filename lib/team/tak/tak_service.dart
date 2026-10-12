// MeshCore Open TAK - TAK interop.
//
//  * TAK Server: streaming CoT over TLS (client certificate, usually port
//    8089) or plain TCP (usually 8087). This phone acts as a gateway: the
//    whole mesh team (positions, pins, SALUTE reports, alerts) appears to TAK
//    users, and TAK users appear on the VOX map.
//  * Local ATAK with no server: CoT on the standard SA multicast group
//    239.2.3.1:6969 on the phone's Wi-Fi.
//  * Optionally relays TAK units onto the mesh, rate-limited (off by default:
//    every relayed position floods the team channel).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xml/xml.dart';

import '../team_service.dart';
import '../team_wire.dart';
import 'cot.dart';

enum TakState { off, connecting, connected, error }

/// A unit or marker known from TAK.
class TakEntity {
  final CotEvent event;
  final DateTime received;
  const TakEntity(this.event, this.received);
  bool get isStale => DateTime.now().isAfter(event.stale);
}

class TakSettings {
  final bool serverEnabled;
  final String host;
  final int port;
  final bool tls;
  final bool allowUntrusted;
  final String clientP12Path;
  final String clientPassword;
  final String trustP12Path;
  final String trustPassword;
  final bool multicastEnabled;
  final bool relayToMesh;

  const TakSettings({
    this.serverEnabled = false,
    this.host = '',
    this.port = 8089,
    this.tls = true,
    this.allowUntrusted = false,
    this.clientP12Path = '',
    this.clientPassword = '',
    this.trustP12Path = '',
    this.trustPassword = '',
    this.multicastEnabled = false,
    this.relayToMesh = false,
  });

  TakSettings copyWith({
    bool? serverEnabled,
    String? host,
    int? port,
    bool? tls,
    bool? allowUntrusted,
    String? clientP12Path,
    String? clientPassword,
    String? trustP12Path,
    String? trustPassword,
    bool? multicastEnabled,
    bool? relayToMesh,
  }) => TakSettings(
    serverEnabled: serverEnabled ?? this.serverEnabled,
    host: host ?? this.host,
    port: port ?? this.port,
    tls: tls ?? this.tls,
    allowUntrusted: allowUntrusted ?? this.allowUntrusted,
    clientP12Path: clientP12Path ?? this.clientP12Path,
    clientPassword: clientPassword ?? this.clientPassword,
    trustP12Path: trustP12Path ?? this.trustP12Path,
    trustPassword: trustPassword ?? this.trustPassword,
    multicastEnabled: multicastEnabled ?? this.multicastEnabled,
    relayToMesh: relayToMesh ?? this.relayToMesh,
  );

  Map<String, Object> toJson() => {
    'serverEnabled': serverEnabled,
    'host': host,
    'port': port,
    'tls': tls,
    'allowUntrusted': allowUntrusted,
    'clientP12Path': clientP12Path,
    'clientPassword': clientPassword,
    'trustP12Path': trustP12Path,
    'trustPassword': trustPassword,
    'multicastEnabled': multicastEnabled,
    'relayToMesh': relayToMesh,
  };

  static TakSettings fromJson(Map<String, dynamic> j) => TakSettings(
    serverEnabled: j['serverEnabled'] == true,
    host: (j['host'] as String?) ?? '',
    port: (j['port'] as num?)?.toInt() ?? 8089,
    tls: j['tls'] != false,
    allowUntrusted: j['allowUntrusted'] == true,
    clientP12Path: (j['clientP12Path'] as String?) ?? '',
    clientPassword: (j['clientPassword'] as String?) ?? '',
    trustP12Path: (j['trustP12Path'] as String?) ?? '',
    trustPassword: (j['trustPassword'] as String?) ?? '',
    multicastEnabled: j['multicastEnabled'] == true,
    relayToMesh: j['relayToMesh'] == true,
  );
}

class TakService extends ChangeNotifier {
  TakService(this._team) {
    _team
      ..onRemotePosition = _onMeshMember
      ..onMarkerChanged = _onMeshMarker
      ..onAlertChanged = _onMeshAlert
      ..onReportChanged = _onMeshReport
      ..onSelfPosition = _onSelfPosition;
    unawaited(_load());
    _ticker = Timer.periodic(const Duration(seconds: 30), (_) => _onTick());
  }

  final TeamService _team;
  late final Timer _ticker;

  static const _kSettings = 'tak_settings_v1';
  TakSettings _settings = const TakSettings();
  TakSettings get settings => _settings;

  TakState _state = TakState.off;
  String? _error;
  TakState get state => _state;
  String? get error => _error;

  /// Units and markers from TAK, by uid.
  final Map<String, TakEntity> _entities = {};
  List<TakEntity> get entities =>
      _entities.values.where((e) => !e.isStale).toList();

  int _sent = 0, _received = 0;
  int get sentCount => _sent;
  int get receivedCount => _received;

  Future<void> _load() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_kSettings);
      if (raw != null) {
        _settings = TakSettings.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
      }
    } catch (_) {}
    notifyListeners();
    _apply();
  }

  Future<void> update(TakSettings s) async {
    _settings = s;
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_kSettings, jsonEncode(s.toJson()));
    } catch (_) {}
    await _disconnect();
    _apply();
  }

  void _apply() {
    if (_settings.serverEnabled && _settings.host.isNotEmpty) {
      unawaited(_connect());
    }
    unawaited(_updateMulticast());
  }

  // ------------------------------------------------------------ server

  Socket? _socket;
  StreamSubscription<String>? _rx;
  final StringBuffer _buffer = StringBuffer();
  int _backoff = 5;
  Timer? _reconnect;

  Future<SecurityContext> _securityContext() async {
    final ctx = SecurityContext(withTrustedRoots: true);
    if (_settings.clientP12Path.isNotEmpty) {
      final bytes = await File(_settings.clientP12Path).readAsBytes();
      ctx
        ..useCertificateChainBytes(bytes, password: _settings.clientPassword)
        ..usePrivateKeyBytes(bytes, password: _settings.clientPassword);
    }
    if (_settings.trustP12Path.isNotEmpty) {
      final bytes = await File(_settings.trustP12Path).readAsBytes();
      ctx.setTrustedCertificatesBytes(bytes, password: _settings.trustPassword);
    }
    return ctx;
  }

  Future<void> _connect() async {
    _reconnect?.cancel();
    _state = TakState.connecting;
    _error = null;
    notifyListeners();
    try {
      final s = _settings;
      final Socket sock;
      if (s.tls) {
        sock = await SecureSocket.connect(
          s.host,
          s.port,
          context: await _securityContext(),
          onBadCertificate: s.allowUntrusted ? (_) => true : null,
          timeout: const Duration(seconds: 15),
        );
      } else {
        sock = await Socket.connect(
          s.host,
          s.port,
          timeout: const Duration(seconds: 15),
        );
      }
      _socket = sock;
      _state = TakState.connected;
      _backoff = 5;
      notifyListeners();
      _rx = sock
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(
            _onServerData,
            onError: (Object e) => _onServerClosed('$e'),
            onDone: () => _onServerClosed('Server closed the connection'),
          );
      _publishAll();
    } catch (e) {
      _onServerClosed(_friendly(e));
    }
  }

  String _friendly(Object e) {
    final s = '$e';
    if (s.contains('CERTIFICATE_VERIFY_FAILED')) {
      return 'Server certificate not trusted. Import the server\'s trust '
          'store, or allow untrusted servers.';
    }
    if (s.contains('BAD_PKCS12') || s.contains('PKCS12')) {
      return 'Couldn\'t open the certificate. Check its password.';
    }
    if (s.contains('Connection refused')) return 'Connection refused';
    if (s.contains('timed out')) return 'Timed out reaching the server';
    return s.length > 160 ? '${s.substring(0, 160)}…' : s;
  }

  void _onServerClosed(String why) {
    unawaited(_rx?.cancel());
    _rx = null;
    _socket?.destroy();
    _socket = null;
    if (!_settings.serverEnabled) {
      _state = TakState.off;
      notifyListeners();
      return;
    }
    _state = TakState.error;
    _error = why;
    notifyListeners();
    _reconnect = Timer(
      Duration(seconds: _backoff),
      () => unawaited(_connect()),
    );
    _backoff = min(_backoff * 2, 300);
  }

  Future<void> _disconnect() async {
    _reconnect?.cancel();
    await _rx?.cancel();
    _rx = null;
    _socket?.destroy();
    _socket = null;
    _state = TakState.off;
    _error = null;
    notifyListeners();
  }

  void _onServerData(String chunk) {
    _buffer.write(chunk);
    if (_buffer.length > 1 << 20) _buffer.clear(); // runaway garbage
    for (final xml in takSplitEvents(_buffer)) {
      final e = parseCot(xml);
      if (e != null) _onCot(e);
    }
  }

  void _write(String xml) {
    final sock = _socket;
    if (sock != null && _state == TakState.connected) {
      try {
        sock.write(xml);
        _sent++;
      } catch (e) {
        _onServerClosed('$e');
      }
    }
    _multicast(xml);
  }

  // ---------------------------------------------------------- multicast

  static final InternetAddress _saGroup = InternetAddress('239.2.3.1');
  static const int _saPort = 6969;
  RawDatagramSocket? _mcast;

  Future<void> _updateMulticast() async {
    if (_settings.multicastEnabled && _mcast == null) {
      try {
        final s = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4,
          _saPort,
          reuseAddress: true,
        );
        s.multicastLoopback = false;
        try {
          s.joinMulticast(_saGroup);
        } catch (_) {
          // Receiving needs a multicast lock on some phones; sending works.
        }
        s.listen((ev) {
          if (ev != RawSocketEvent.read) return;
          final d = s.receive();
          if (d == null) return;
          final e = parseCot(utf8.decode(d.data, allowMalformed: true));
          if (e != null) _onCot(e);
        });
        _mcast = s;
        _publishAll();
      } catch (e) {
        debugPrint('TAK multicast unavailable: $e');
      }
    } else if (!_settings.multicastEnabled && _mcast != null) {
      _mcast!.close();
      _mcast = null;
    }
  }

  void _multicast(String xml) {
    final s = _mcast;
    if (s == null) return;
    try {
      s.send(utf8.encode(xml), _saGroup, _saPort);
    } catch (_) {}
  }

  bool get _publishing => _state == TakState.connected || _mcast != null;

  // ------------------------------------------- mesh -> TAK (gateway out)

  void _onSelfPosition(TeamPosition p) {
    if (_publishing) {
      _write(cotForPosition(p, uid: takUidForMember(p.senderKey4)));
    }
  }

  void _onMeshMember(TeamMember m) {
    if (m.position.relayed) return; // came from TAK; don't echo it back
    if (_publishing) {
      _write(cotForPosition(m.position, uid: takUidForMember(m.key4)));
    }
  }

  void _onMeshMarker(TeamMarker m) {
    if (_publishing) _write(cotForMarker(m));
  }

  void _onMeshReport(TeamReport r) {
    if (_publishing) _write(cotForReport(r));
  }

  void _onMeshAlert(TeamAlert a) {
    if (_publishing) {
      _write(cotForAlert(a, memberUid: takUidForMember(a.senderKey4)));
    }
  }

  void _publishAll() {
    final self = _team.selfPositionForBridge;
    if (self != null) _onSelfPosition(self);
    for (final m in _team.members) {
      if (m.freshness != TeamFreshness.lost) _onMeshMember(m);
    }
    for (final m in _team.markers) {
      _onMeshMarker(m);
    }
    for (final r in _team.reports.take(20)) {
      _onMeshReport(r);
    }
    final own = _team.activeOwnAlert;
    if (own != null) _onMeshAlert(own);
    for (final a in _team.activeAlerts) {
      _onMeshAlert(a);
    }
  }

  void _onTick() {
    final sock = _socket;
    if (sock != null && _state == TakState.connected) {
      try {
        sock.write(cotPing(takUidForMember(_team.selfKey4)));
      } catch (_) {}
    }
    // Keep our self PLI fresh on TAK even when the mesh beacon is idle.
    final self = _team.selfPositionForBridge;
    if (self != null && _publishing) _onSelfPosition(self);
    _entities.removeWhere(
      (_, e) =>
          DateTime.now().difference(e.event.stale) > const Duration(hours: 1),
    );
  }

  // -------------------------------------------- TAK -> VOX (gateway in)

  final Map<String, DateTime> _lastRelay = {};
  DateTime? _lastAnyRelay;

  void _onCot(CotEvent e) {
    if (e.uid.startsWith('VOX-')) return; // our own, echoed by the server
    _received++;
    if (e.isPing) return;
    if (e.isDelete) {
      if (e.linkUid != null) _entities.remove(e.linkUid);
      notifyListeners();
      return;
    }
    if (e.isUnit || e.isMarker || e.isAlert) {
      _entities[e.uid] = TakEntity(e, DateTime.now());
      notifyListeners();
    }
    if (_settings.relayToMesh && e.isFriendlyUnit) _maybeRelay(e);
  }

  /// Relays a TAK unit's position onto the mesh, at most once per 5 minutes
  /// per unit and once per 30 s overall. It is flagged as relayed so other
  /// gateways never echo it back to TAK.
  void _maybeRelay(CotEvent e) {
    final now = DateTime.now();
    final last = _lastRelay[e.uid];
    if (last != null && now.difference(last) < const Duration(minutes: 5)) {
      return;
    }
    if (_lastAnyRelay != null &&
        now.difference(_lastAnyRelay!) < const Duration(seconds: 30)) {
      return;
    }
    _lastRelay[e.uid] = now;
    _lastAnyRelay = now;
    final h = e.uid.codeUnits.fold<int>(
      0x811C9DC5,
      (a, c) => ((a ^ c) * 0x01000193) & 0xFFFFFFFF,
    );
    final key4 = '7a${(h & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
    unawaited(
      _team.relayExternalPosition(
        TeamPosition(
          senderKey4: key4,
          lat: e.lat,
          lon: e.lon,
          altitudeM: e.hae?.round(),
          speedMps: e.speed,
          headingDeg: e.course,
          accuracyM: (e.ce ?? 0).round().clamp(0, 255),
          batteryPct: e.battery,
          roleId: teamRoleFromTak(e.groupRole).index,
          color: teamColorFromTakGroup(e.groupName),
          callsign: e.callsign ?? 'TAK',
          relayed: true,
        ),
      ),
    );
  }

  // ------------------------------------------- ATAK data package import

  /// Imports an ATAK/TAK Server connection data package (.zip with a .pref
  /// and .p12 certificates). Returns a short description of what it set up.
  Future<String> importDataPackage(Uint8List zipBytes) async {
    final archive = ZipDecoder().decodeBytes(zipBytes);
    final files = <String, Uint8List>{};
    for (final f in archive.files) {
      if (f.isFile) {
        files[f.name.split('/').last] = Uint8List.fromList(f.content);
      }
    }
    final prefName = files.keys.firstWhere(
      (n) => n.toLowerCase().endsWith('.pref'),
      orElse: () => '',
    );
    if (prefName.isEmpty) {
      throw const FormatException('No .pref file in this package');
    }
    final entries = <String, String>{};
    final doc = XmlDocument.parse(utf8.decode(files[prefName]!));
    for (final e in doc.findAllElements('entry')) {
      final k = e.getAttribute('key');
      if (k != null) entries[k] = e.innerText.trim();
    }
    final connect = entries['connectString0'] ?? '';
    final parts = connect.split(':');
    if (parts.length < 2) {
      throw const FormatException('No server address (connectString0)');
    }
    final dir = await _certDir();
    Future<String> save(String? location) async {
      if (location == null || location.isEmpty) return '';
      final name = location.split('/').last;
      final bytes = files[name];
      if (bytes == null) return '';
      final f = File('${dir.path}/$name');
      await f.writeAsBytes(bytes, flush: true);
      return f.path;
    }

    final client = await save(
      entries['certificateLocation0'] ?? entries['certificateLocation'],
    );
    final trust = await save(entries['caLocation0'] ?? entries['caLocation']);
    final s = _settings.copyWith(
      serverEnabled: true,
      host: parts[0],
      port: int.tryParse(parts[1]) ?? 8089,
      tls: parts.length < 3 || parts[2].toLowerCase() == 'ssl',
      clientP12Path: client,
      clientPassword:
          entries['clientPassword0'] ?? entries['clientPassword'] ?? 'atakatak',
      trustP12Path: trust,
      trustPassword:
          entries['caPassword0'] ?? entries['caPassword'] ?? 'atakatak',
    );
    await update(s);
    return '${s.host}:${s.port} (${s.tls ? 'TLS' : 'TCP'})'
        '${client.isNotEmpty ? ', client certificate' : ''}'
        '${trust.isNotEmpty ? ', trust store' : ''}';
  }

  /// Stores a single certificate file picked by the user.
  Future<String> saveCertificate(String name, Uint8List bytes) async {
    final dir = await _certDir();
    final f = File('${dir.path}/$name');
    await f.writeAsBytes(bytes, flush: true);
    return f.path;
  }

  Future<Directory> _certDir() async {
    final base = await getApplicationSupportDirectory();
    final d = Directory('${base.path}/tak_certs');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  @override
  void dispose() {
    _ticker.cancel();
    unawaited(_disconnect());
    _mcast?.close();
    super.dispose();
  }
}
