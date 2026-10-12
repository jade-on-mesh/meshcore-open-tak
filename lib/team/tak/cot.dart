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
/// The TAK role for a team role id (added roles are team members).
String takRoleName(int roleId) => roleId >= teamFirstAddedRole
    ? 'Team Member'
    : _takRoleName(TeamRole.fromIndex(roleId));

String _takRoleName(TeamRole r) => switch (r) {
  TeamRole.member => 'Team Member',
  TeamRole.lead => 'Team Lead',
  TeamRole.medic => 'Medic',
  TeamRole.navigator => 'Team Member',
  TeamRole.comms => 'RTO',
  TeamRole.driver => 'Team Member',
  TeamRole.security => 'Team Member',
  TeamRole.observer => 'Forward Observer',
  TeamRole.command => 'HQ',
};

TeamRole teamRoleFromTak(String? role) => switch ((role ?? '').toLowerCase()) {
  'team lead' => TeamRole.lead,
  'medic' => TeamRole.medic,
  'rto' => TeamRole.comms,
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
      attributes: {
        'name': takGroupName(p.color),
        'role': takRoleName(p.roleId),
      },
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
  });

  bool get isUnit => type.startsWith('a-');
  bool get isFriendlyUnit => type.startsWith('a-f-G');
  bool get isMarker => type.startsWith('b-m-p');
  bool get isAlert => type.startsWith('b-a-');
  bool get isDelete => type == 't-x-d-d';
  bool get isPing => type.startsWith('t-x-c-t');
  bool get isChat => type == 'b-t-f';
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
