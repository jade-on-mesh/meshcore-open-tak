// MeshCore Open TAK - Cursor on Target (CoT) XML, the format TAK Server,
// ATAK, WinTAK and iTAK exchange. Converts VOX team data to CoT events and
// parses incoming events.

import 'package:xml/xml.dart';

import '../team_wire.dart';

/// ATAK team colour names (the `__group name` attribute).
String takGroupName(TeamColor c) => switch (c) {
  TeamColor.cyan => 'Cyan',
  TeamColor.white => 'White',
  TeamColor.yellow => 'Yellow',
  TeamColor.orange => 'Orange',
  TeamColor.magenta => 'Magenta',
  TeamColor.red => 'Red',
  TeamColor.maroon => 'Maroon',
  TeamColor.purple => 'Purple',
  TeamColor.darkBlue => 'Dark Blue',
  TeamColor.blue => 'Blue',
  TeamColor.teal => 'Teal',
  TeamColor.green => 'Green',
  TeamColor.darkGreen => 'Dark Green',
  TeamColor.brown => 'Brown',
};

TeamColor teamColorFromTakGroup(String? name) {
  for (final c in TeamColor.values) {
    if (takGroupName(c).toLowerCase() == (name ?? '').toLowerCase()) return c;
  }
  return TeamColor.cyan;
}

/// ATAK role names (the `__group role` attribute).
String takRoleName(TeamRole r) => switch (r) {
  TeamRole.member => 'Team Member',
  TeamRole.lead => 'Team Lead',
  TeamRole.medic => 'Medic',
  TeamRole.navigator => 'Team Member',
  TeamRole.comms => 'RTO',
  TeamRole.driver => 'Team Member',
  TeamRole.k9 => 'K9',
  TeamRole.observer => 'Forward Observer',
  TeamRole.command => 'HQ',
};

TeamRole teamRoleFromTak(String? role) => switch ((role ?? '').toLowerCase()) {
  'team lead' => TeamRole.lead,
  'medic' => TeamRole.medic,
  'rto' => TeamRole.comms,
  'k9' => TeamRole.k9,
  'forward observer' || 'sniper' => TeamRole.observer,
  'hq' => TeamRole.command,
  _ => TeamRole.member,
};

/// Alert types as CoT event types and ATAK emergency names.
(String, String) takAlertType(TeamAlertType t) => switch (t) {
  TeamAlertType.sos => ('b-a-o-tbl', '911 Alert'),
  TeamAlertType.inContact => ('b-a-o-opn', 'In Contact'),
  TeamAlertType.ringTheBell => ('b-a-o-pan', 'Ring The Bell'),
  TeamAlertType.geofence => ('b-a-g', 'Geo-fence Breached'),
  TeamAlertType.custom => ('b-a-o-c', 'Custom'),
};

/// ATAK marker colours (ARGB as a signed 32-bit int string) per pin kind.
int takMarkerArgb(MarkerKind k) => switch (k) {
  MarkerKind.point => 0xFFFFFFFF,
  MarkerKind.lastKnown => 0xFFFF0000,
  MarkerKind.staging => 0xFF0000FF,
  MarkerKind.clue => 0xFFFFFF00,
  MarkerKind.hazard => 0xFFFF7F00,
  MarkerKind.landingZone => 0xFF00FF00,
  MarkerKind.medical => 0xFFFF00FF,
  MarkerKind.subjectFound => 0xFF00FFFF,
  MarkerKind.water => 0xFF3399FF,
  MarkerKind.searched => 0xFF888888,
};

int _signed32(int v) => v >= 0x80000000 ? v - 0x100000000 : v;

String _iso(DateTime t) => t.toUtc().toIso8601String();

const _noVal = '9999999.0';

/// The CoT uid for a mesh member.
String takUidForMember(String key4) => 'VOX-$key4';

/// Builds a CoT `<event>`.
String cotEvent({
  required String uid,
  required String type,
  required double lat,
  required double lon,
  String how = 'm-g',
  DateTime? time,
  Duration staleAfter = const Duration(minutes: 10),
  double? hae,
  double? ce,
  void Function(XmlBuilder b)? detail,
}) {
  final now = time ?? DateTime.now();
  final b = XmlBuilder();
  b.element(
    'event',
    attributes: {
      'version': '2.0',
      'uid': uid,
      'type': type,
      'how': how,
      'time': _iso(now),
      'start': _iso(now),
      'stale': _iso(now.add(staleAfter)),
    },
    nest: () {
      b.element(
        'point',
        attributes: {
          'lat': lat.toStringAsFixed(7),
          'lon': lon.toStringAsFixed(7),
          'hae': hae == null ? _noVal : hae.toStringAsFixed(1),
          'ce': ce == null || ce <= 0 ? _noVal : ce.toStringAsFixed(1),
          'le': _noVal,
        },
      );
      b.element('detail', nest: () => detail?.call(b));
    },
  );
  return b.buildDocument().toXmlString();
}

/// A team member's position (PLI) as CoT.
String cotForPosition(TeamPosition p, {required String uid}) => cotEvent(
  uid: uid,
  type: 'a-f-G-U-C',
  how: p.fromRadio ? 'm-g' : 'm-g',
  lat: p.lat,
  lon: p.lon,
  hae: p.altitudeM?.toDouble(),
  ce: p.accuracyM > 0 ? p.accuracyM.toDouble() : null,
  staleAfter: const Duration(minutes: 15),
  detail: (b) {
    b.element(
      'contact',
      attributes: {
        'callsign': p.callsign.isEmpty
            ? p.senderKey4.toUpperCase()
            : p.callsign,
      },
    );
    b.element(
      '__group',
      attributes: {'name': takGroupName(p.color), 'role': takRoleName(p.role)},
    );
    if (p.batteryPct != null) {
      b.element('status', attributes: {'battery': '${p.batteryPct}'});
    }
    if (p.speedMps != null && p.headingDeg != null) {
      b.element(
        'track',
        attributes: {
          'course': p.headingDeg!.toStringAsFixed(1),
          'speed': p.speedMps!.toStringAsFixed(1),
        },
      );
    }
    b.element(
      'takv',
      attributes: {
        'device': 'MeshCore radio',
        'platform': 'MeshCore Open TAK',
        'os': 'LoRa mesh',
        'version': '1',
      },
    );
    b.element(
      'remarks',
      nest: [
        'Via MeshCore mesh',
        if (p.status != TeamStatus.none) p.status.label,
        if (p.fromRadio) 'radio GPS',
      ].join(' · '),
    );
  },
);

/// A tactical pin as CoT (an ATAK spot marker).
String cotForMarker(TeamMarker m) {
  final uid = 'VOX-M-${m.authorKey4}-${m.markerId.toRadixString(16)}';
  if (m.deleted) return cotDelete(uid);
  return cotEvent(
    uid: uid,
    type: 'b-m-p-s-m',
    how: 'h-g-i-g-o',
    lat: m.lat,
    lon: m.lon,
    time: m.time,
    staleAfter: const Duration(days: 1),
    detail: (b) {
      b.element(
        'contact',
        attributes: {
          'callsign': m.label.isEmpty
              ? m.kind.label
              : '${m.label} (${m.kind.label})',
        },
      );
      b.element(
        'color',
        attributes: {'argb': '${_signed32(takMarkerArgb(m.kind))}'},
      );
      b.element(
        'link',
        attributes: {
          'uid': takUidForMember(m.authorKey4),
          'relation': 'p-p',
          'type': 'a-f-G-U-C',
        },
      );
      b.element('archive');
      if (m.note.isNotEmpty || m.attachment != null) {
        b.element(
          'remarks',
          nest: [
            if (m.note.isNotEmpty) m.note,
            if (m.attachment != null) '[attachment on the mesh]',
          ].join(' '),
        );
      }
    },
  );
}

/// A SALUTE report as CoT: a point coloured by affiliation, remarks holding
/// the report.
String cotForReport(TeamReport r) => cotEvent(
  uid: 'VOX-R-${r.authorKey4}-${r.reportId.toRadixString(16)}',
  type: switch (r.affiliation) {
    TeamAffiliation.hostile => 'a-h-G',
    TeamAffiliation.neutral => 'a-n-G',
    TeamAffiliation.friendly => 'a-f-G',
    TeamAffiliation.unknown => 'a-u-G',
  },
  how: 'h-g-i-g-o',
  lat: r.lat,
  lon: r.lon,
  time: r.observed,
  staleAfter: const Duration(hours: 6),
  detail: (b) {
    b.element(
      'contact',
      attributes: {
        'callsign':
            'SALUTE ${r.observed.toUtc().toIso8601String().substring(11, 16)}Z',
      },
    );
    b.element(
      'link',
      attributes: {
        'uid': takUidForMember(r.authorKey4),
        'relation': 'p-p',
        'type': 'a-f-G-U-C',
      },
    );
    b.element('archive');
    b.element('remarks', nest: 'SALUTE ${r.summary()}');
  },
);

/// An alert (or its cancellation) as CoT.
String cotForAlert(TeamAlert a, {required String memberUid}) {
  final uid = '$memberUid-9-1-1';
  final (type, name) = takAlertType(a.type);
  return cotEvent(
    uid: uid,
    type: a.active ? type : 'b-a-o-can',
    how: 'm-g',
    lat: a.lat ?? 0,
    lon: a.lon ?? 0,
    staleAfter: const Duration(minutes: 10),
    detail: (b) {
      b.element(
        'link',
        attributes: {'uid': memberUid, 'relation': 'p-p', 'type': 'a-f-G-U-C'},
      );
      b.element('contact', attributes: {'callsign': '${a.callsign}-Alert'});
      b.element(
        'emergency',
        attributes: a.active ? {'type': name} : {'cancel': 'true'},
        nest: a.callsign,
      );
      if (a.note.isNotEmpty) b.element('remarks', nest: a.note);
    },
  );
}

// ------------------------------------------------- drawings and routes

/// CoT uid for a mesh drawing/route/geofence.
String takUidForShape(TeamShape s) =>
    'VOX-D-${s.authorKey4}-${s.shapeId.toRadixString(16)}';

String _ll(double lat, double lon) =>
    '${lat.toStringAsFixed(7)},${lon.toStringAsFixed(7)}';

/// CoT event type for a shape.
String takShapeType(ShapeKind k) => switch (k) {
  ShapeKind.line || ShapeKind.polygon => 'u-d-f',
  ShapeKind.freehand => 'u-d-f-m',
  ShapeKind.rectangle => 'u-d-r',
  ShapeKind.circle => 'u-d-c-c',
  ShapeKind.route => 'b-m-r',
};

String _geofenceTrigger(TeamGeofence g) => switch (g) {
  TeamGeofence.entry => 'Entry',
  TeamGeofence.exit => 'Exit',
  _ => 'Both',
};

/// A drawing, route or geofence as CoT (ATAK drawing tools / route format).
String cotForShape(TeamShape sh) {
  final uid = takUidForShape(sh);
  if (sh.deleted) return cotDelete(uid);
  final (alat, alon) = sh.anchor;
  final stroke = '${_signed32(sh.color.argb)}';
  final fill = '${_signed32((sh.color.argb & 0x00FFFFFF) | 0x40000000)}';
  return cotEvent(
    uid: uid,
    type: takShapeType(sh.kind),
    how: 'h-e',
    lat: alat,
    lon: alon,
    time: sh.time,
    staleAfter: const Duration(days: 1),
    detail: (b) {
      b.element('contact', attributes: {'callsign': sh.title});
      if (sh.kind == ShapeKind.route) {
        for (var i = 0; i < sh.points.length; i++) {
          final (lat, lon) = sh.points[i];
          b.element(
            'link',
            attributes: {
              'uid': '$uid-cp${i + 1}',
              'callsign': 'CP${i + 1}',
              'type': 'b-m-p-w',
              'point': _ll(lat, lon),
              'remarks': '',
              'relation': 'c',
            },
          );
        }
        b.element(
          'link_attr',
          attributes: {
            'color': stroke,
            'method': sh.routeMethod.label,
            'prefix': 'CP',
            'type': sh.routeMethod == RouteMethod.driving
                ? 'Vehicle'
                : 'On Foot',
            'order': 'Ascending Check Points',
            'routetype': 'Primary',
            'direction': 'Infil',
            'planningmethod': 'Infil',
            'stroke': '3',
          },
        );
        b.element('__routeinfo', nest: () => b.element('__navcues'));
      } else if (sh.kind == ShapeKind.circle) {
        b.element(
          'shape',
          nest: () => b.element(
            'ellipse',
            attributes: {
              'major': '${sh.radiusM}',
              'minor': '${sh.radiusM}',
              'angle': '360',
            },
          ),
        );
      } else {
        for (final (lat, lon) in sh.points) {
          b.element('link', attributes: {'point': _ll(lat, lon)});
        }
        if (sh.kind == ShapeKind.polygon && sh.points.isNotEmpty) {
          // ATAK closes a freeform shape by repeating the first vertex.
          b.element(
            'link',
            attributes: {'point': _ll(sh.points.first.$1, sh.points.first.$2)},
          );
        }
      }
      b.element('strokeColor', attributes: {'value': stroke});
      b.element('strokeWeight', attributes: {'value': '3.0'});
      if (sh.kind.closed) {
        b.element('fillColor', attributes: {'value': fill});
      }
      b.element('labels_on', attributes: {'value': 'true'});
      if (sh.isGeofence) {
        b.element(
          '__geofence',
          attributes: {
            'trigger': _geofenceTrigger(sh.geofence),
            'monitor': 'All',
            'tracking': 'true',
            'elevationMonitored': 'false',
            'minElevation': '',
            'maxElevation': '',
          },
        );
      }
      b.element(
        'link',
        attributes: {
          'uid': takUidForMember(sh.authorKey4),
          'relation': 'p-p',
          'type': 'a-f-G-U-C',
        },
      );
      b.element('archive');
    },
  );
}

// ---------------------------------------------------------------- MEDEVAC

/// A CASEVAC / MEDEVAC 9-line as an ATAK MEDEVAC (`b-r-f-h-c`) event.
String cotForCasevac(TeamCasevac c) {
  final uid = 'VOX-C-${c.authorKey4}-${c.requestId.toRadixString(16)}';
  if (c.deleted) return cotDelete(uid);
  String flag(bool v) => v ? 'true' : 'false';
  return cotEvent(
    uid: uid,
    type: 'b-r-f-h-c',
    how: 'h-g-i-g-o',
    lat: c.lat,
    lon: c.lon,
    time: c.time,
    staleAfter: const Duration(hours: 12),
    detail: (b) {
      b.element(
        'contact',
        attributes: {
          'callsign':
              'MED.${c.callsign.isEmpty ? c.authorKey4.toUpperCase() : c.callsign}'
              '.${c.time.toUtc().toIso8601String().substring(11, 16).replaceAll(':', '')}',
        },
      );
      b.element(
        '_medevac_',
        attributes: {
          'title': c.place.isEmpty ? 'CASEVAC' : c.place,
          'casevac': 'true',
          'freq': c.frequency,
          'urgent': '${c.urgent}',
          'urgent_surgical': '${c.urgentSurgical}',
          'priority': '${c.priority}',
          'routine': '${c.routine}',
          'convenience': '${c.convenience}',
          'equipment_none': flag(
            c.equipment.isEmpty || c.equipment.contains(CasevacEquipment.none),
          ),
          'hoist': flag(c.equipment.contains(CasevacEquipment.hoist)),
          'extraction_equipment': flag(
            c.equipment.contains(CasevacEquipment.extraction),
          ),
          'ventilator': flag(c.equipment.contains(CasevacEquipment.ventilator)),
          'equipment_other': flag(c.equipment.contains(CasevacEquipment.other)),
          'litter': '${c.litter}',
          'ambulatory': '${c.ambulatory}',
          'security': '${c.security.index}',
          'hlz_marking': '${c.marking.index}',
          'hlz_other': c.markingDetail,
          'us_military': '${c.usMilitary}',
          'us_civilian': '${c.usCivilian}',
          'nonus_military': '${c.nonUsMilitary}',
          'nonus_civilian': '${c.nonUsCivilian}',
          'epw': '${c.epw}',
          'child': '${c.child}',
          'terrain_none': flag(
            c.terrain.isEmpty || c.terrain.contains(CasevacTerrain.none),
          ),
          'terrain_slope': flag(c.terrain.contains(CasevacTerrain.slope)),
          'terrain_rough': flag(c.terrain.contains(CasevacTerrain.rough)),
          'terrain_loose': flag(c.terrain.contains(CasevacTerrain.loose)),
          'terrain_other': flag(c.terrain.contains(CasevacTerrain.other)),
          'medline_remarks': c.remarks,
        },
      );
      b.element(
        'link',
        attributes: {
          'uid': takUidForMember(c.authorKey4),
          'relation': 'p-p',
          'type': 'a-f-G-U-C',
        },
      );
      b.element('archive');
      b.element(
        'remarks',
        nest:
            '9-LINE ${c.nineLines().join(' | ')}'
            '${c.remarks.isNotEmpty ? ' | ${c.remarks}' : ''}',
      );
    },
  );
}

// ---------------------------------------------------------------- GeoChat

const String takAllChatRooms = 'All Chat Rooms';

/// A chat line for TAK's "All Chat Rooms" (GeoChat).
String cotGeoChat({
  required String senderUid,
  required String senderCallsign,
  required String text,
  required String messageId,
  double lat = 0,
  double lon = 0,
  DateTime? time,
}) {
  final now = time ?? DateTime.now();
  return cotEvent(
    uid: 'GeoChat.$senderUid.$takAllChatRooms.$messageId',
    type: 'b-t-f',
    how: 'h-g-i-g-o',
    lat: lat,
    lon: lon,
    time: now,
    staleAfter: const Duration(days: 1),
    detail: (b) {
      b.element(
        '__chat',
        attributes: {
          'parent': 'RootContactGroup',
          'groupOwner': 'false',
          'messageId': messageId,
          'chatroom': takAllChatRooms,
          'id': takAllChatRooms,
          'senderCallsign': senderCallsign,
        },
        nest: () => b.element(
          'chatgrp',
          attributes: {
            'uid0': senderUid,
            'uid1': takAllChatRooms,
            'id': takAllChatRooms,
          },
        ),
      );
      b.element(
        'link',
        attributes: {'uid': senderUid, 'type': 'a-f-G-U-C', 'relation': 'p-p'},
      );
      b.element(
        'remarks',
        attributes: {
          'source': 'BAO.F.ATAK.$senderUid',
          'to': takAllChatRooms,
          'time': _iso(now),
        },
        nest: text,
      );
    },
  );
}

/// Deletes [uid] on TAK clients.
String cotDelete(String uid) => cotEvent(
  uid: '$uid-delete',
  type: 't-x-d-d',
  how: 'h-g-i-g-o',
  lat: 0,
  lon: 0,
  staleAfter: const Duration(seconds: 20),
  detail: (b) {
    b.element(
      'link',
      attributes: {'uid': uid, 'relation': 'none', 'type': 'none'},
    );
    b.element('__forcedelete');
  },
);

/// TAK Server keep-alive.
String cotPing(String uid) => cotEvent(
  uid: '$uid-ping',
  type: 't-x-c-t',
  how: 'h-g-i-g-o',
  lat: 0,
  lon: 0,
  staleAfter: const Duration(seconds: 20),
);

// ----------------------------------------------------------------- parsing

/// The parts of an incoming CoT event VOX uses.
class CotEvent {
  final String uid;
  final String type;
  final double lat, lon;
  final double? hae, ce;
  final DateTime time, stale;
  final String? callsign;
  final String? groupName, groupRole;
  final double? course, speed;
  final int? battery;
  final String? remarks;
  final String? emergencyType;
  final bool emergencyCancel;
  final String? linkUid;
  final int? colorArgb;

  /// Vertices of a drawing or route (`<link point="lat,lon"/>`).
  final List<(double, double)> linkPoints;

  /// Circle/ellipse radius in metres.
  final double? ellipseMajor;
  final int? strokeArgb, fillArgb;

  /// GeoChat fields.
  final String? chatSenderCallsign, chatSenderUid, chatroom;

  /// ATAK geofence trigger ("Entry", "Exit", "Both"), if any.
  final String? geofenceTrigger;

  const CotEvent({
    required this.uid,
    required this.type,
    required this.lat,
    required this.lon,
    required this.time,
    required this.stale,
    this.hae,
    this.ce,
    this.callsign,
    this.groupName,
    this.groupRole,
    this.course,
    this.speed,
    this.battery,
    this.remarks,
    this.emergencyType,
    this.emergencyCancel = false,
    this.linkUid,
    this.colorArgb,
    this.linkPoints = const [],
    this.ellipseMajor,
    this.strokeArgb,
    this.fillArgb,
    this.chatSenderCallsign,
    this.chatSenderUid,
    this.chatroom,
    this.geofenceTrigger,
  });

  bool get isUnit => type.startsWith('a-');
  bool get isFriendlyUnit => type.startsWith('a-f-G');
  bool get isMarker => type.startsWith('b-m-p');
  bool get isAlert => type.startsWith('b-a-');
  bool get isDelete => type == 't-x-d-d';
  bool get isPing => type.startsWith('t-x-c-t');
  bool get isChat => type == 'b-t-f';
  bool get isShape => type.startsWith('u-d-');
  bool get isRoute => type == 'b-m-r';
  bool get isCasevac => type.startsWith('b-r-f-h-c');
  bool get isCircle => type.startsWith('u-d-c') && ellipseMajor != null;

  /// Closed shapes (polygons, rectangles, circles).
  bool get isClosedShape =>
      type.startsWith('u-d-r') ||
      isCircle ||
      (linkPoints.length > 2 && linkPoints.first == linkPoints.last) ||
      fillArgb != null;
}

double? _d(String? s) {
  final v = s == null ? null : double.tryParse(s);
  return v == null || v >= 9999999 ? null : v;
}

/// Parses one `<event>` element's XML. Null if malformed.
CotEvent? parseCot(String xml) {
  try {
    final doc = XmlDocument.parse(xml);
    final e = doc.rootElement;
    if (e.name.local != 'event') return null;
    final pt = e.getElement('point');
    final lat = double.tryParse(pt?.getAttribute('lat') ?? '');
    final lon = double.tryParse(pt?.getAttribute('lon') ?? '');
    if (lat == null || lon == null) return null;
    final d = e.getElement('detail');
    final contact = d?.getElement('contact');
    final group = d?.getElement('__group');
    final track = d?.getElement('track');
    final status = d?.getElement('status');
    final emergency = d?.getElement('emergency');
    final link = d?.getElement('link');
    final color = d?.getElement('color');
    final pts = <(double, double)>[];
    for (final l in d?.findElements('link') ?? const <XmlElement>[]) {
      final pt = l.getAttribute('point')?.split(',');
      if (pt == null || pt.length < 2) continue;
      final a = double.tryParse(pt[0]), o = double.tryParse(pt[1]);
      if (a != null && o != null) pts.add((a, o));
    }
    final ellipse = d?.getElement('shape')?.getElement('ellipse');
    final chat = d?.getElement('__chat');
    return CotEvent(
      uid: e.getAttribute('uid') ?? '',
      type: e.getAttribute('type') ?? '',
      lat: lat,
      lon: lon,
      hae: _d(pt?.getAttribute('hae')),
      ce: _d(pt?.getAttribute('ce')),
      time: DateTime.tryParse(e.getAttribute('time') ?? '') ?? DateTime.now(),
      stale:
          DateTime.tryParse(e.getAttribute('stale') ?? '') ??
          DateTime.now().add(const Duration(minutes: 5)),
      callsign: contact?.getAttribute('callsign'),
      groupName: group?.getAttribute('name'),
      groupRole: group?.getAttribute('role'),
      course: _d(track?.getAttribute('course')),
      speed: _d(track?.getAttribute('speed')),
      battery: int.tryParse(status?.getAttribute('battery') ?? ''),
      remarks: d?.getElement('remarks')?.innerText,
      emergencyType: emergency?.getAttribute('type'),
      emergencyCancel: emergency?.getAttribute('cancel') == 'true',
      linkUid: link?.getAttribute('uid'),
      colorArgb: int.tryParse(color?.getAttribute('argb') ?? ''),
      linkPoints: pts,
      ellipseMajor: _d(ellipse?.getAttribute('major')),
      strokeArgb: int.tryParse(
        d?.getElement('strokeColor')?.getAttribute('value') ?? '',
      ),
      fillArgb: int.tryParse(
        d?.getElement('fillColor')?.getAttribute('value') ?? '',
      ),
      chatSenderCallsign: chat?.getAttribute('senderCallsign'),
      chatSenderUid: chat?.getElement('chatgrp')?.getAttribute('uid0'),
      chatroom: chat?.getAttribute('chatroom'),
      geofenceTrigger: d?.getElement('__geofence')?.getAttribute('trigger'),
    );
  } catch (_) {
    return null;
  }
}

/// Splits a TCP stream of concatenated `<event>`s. Returns complete events
/// and leaves the remainder in [buffer].
List<String> takSplitEvents(StringBuffer buffer) {
  final s = buffer.toString();
  final out = <String>[];
  var start = 0;
  while (true) {
    final end = s.indexOf('</event>', start);
    if (end < 0) break;
    final open = s.indexOf('<event', start);
    final stop = end + '</event>'.length;
    if (open >= 0 && open < end) out.add(s.substring(open, stop));
    start = stop;
  }
  // Self-closing events (<event .../>) are rare but legal.
  buffer
    ..clear()
    ..write(s.substring(start));
  return out;
}

// ------------------------------------------------ CoT -> team items

/// The team colour nearest to an ARGB value.
TeamColor teamColorNearest(int argb) {
  final r = (argb >> 16) & 0xFF, g = (argb >> 8) & 0xFF, b = argb & 0xFF;
  var best = TeamColor.yellow;
  var bestD = 1 << 30;
  for (final c in TeamColor.values) {
    final dr = ((c.argb >> 16) & 0xFF) - r;
    final dg = ((c.argb >> 8) & 0xFF) - g;
    final db = (c.argb & 0xFF) - b;
    final d = dr * dr + dg * dg + db * db;
    if (d < bestD) {
      bestD = d;
      best = c;
    }
  }
  return best;
}

/// A TAK point (spot marker or unit) as a team pin.
TeamMarker? teamMarkerFromCot(
  CotEvent e, {
  required String authorKey4,
  required int markerId,
}) {
  if (!e.isMarker && !e.isUnit) return null;
  var kind = MarkerKind.point;
  final c = e.colorArgb;
  if (c != null) {
    for (final k in MarkerKind.values) {
      if ((takMarkerArgb(k) & 0xFFFFFF) == (c & 0xFFFFFF)) kind = k;
    }
  }
  if (e.type.startsWith('a-h')) kind = MarkerKind.hazard;
  return TeamMarker(
    authorKey4: authorKey4,
    markerId: markerId,
    kind: kind,
    lat: e.lat,
    lon: e.lon,
    time: DateTime.now(),
    label: e.callsign ?? '',
    note: e.remarks ?? '',
  );
}

/// A TAK drawing or route as a team shape.
TeamShape? teamShapeFromCot(
  CotEvent e, {
  required String authorKey4,
  required int shapeId,
}) {
  final color = teamColorNearest(e.strokeArgb ?? e.colorArgb ?? 0xFFFFEB3B);
  final geo = switch ((e.geofenceTrigger ?? '').toLowerCase()) {
    'entry' => TeamGeofence.entry,
    'exit' => TeamGeofence.exit,
    'both' => TeamGeofence.both,
    _ => TeamGeofence.off,
  };
  TeamShape make(
    ShapeKind kind,
    List<(double, double)> pts, {
    int radius = 0,
  }) => TeamShape(
    authorKey4: authorKey4,
    shapeId: shapeId,
    kind: kind,
    time: DateTime.now(),
    points: pts,
    color: color,
    label: e.callsign ?? '',
    geofence: kind.closed ? geo : TeamGeofence.off,
    radiusM: radius,
  ).fitted();

  if (e.isRoute && e.linkPoints.length >= 2) {
    return make(ShapeKind.route, e.linkPoints);
  }
  if (!e.isShape) return null;
  if (e.isCircle) {
    return make(
      ShapeKind.circle,
      [(e.lat, e.lon)],
      radius: e.ellipseMajor!.round(),
    );
  }
  final pts = e.linkPoints;
  if (pts.length < 2) return null;
  if (e.type.startsWith('u-d-r') && pts.length >= 4) {
    return make(ShapeKind.rectangle, pts.sublist(0, 4));
  }
  if (e.isClosedShape && pts.length >= 3) {
    final open = pts.length > 3 && pts.first == pts.last
        ? pts.sublist(0, pts.length - 1)
        : pts;
    return make(ShapeKind.polygon, open);
  }
  return make(
    e.type.startsWith('u-d-f-m') ? ShapeKind.freehand : ShapeKind.line,
    pts,
  );
}
