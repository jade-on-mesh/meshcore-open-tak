// MeshCore Open TAK - CASEVAC / MEDEVAC 9-line request.
//
//   [0x43][key4][id u32][op u8][lat i32][lon i32][time u32]
//   L2  [freqLen][freq][callsignLen][callsign]
//   L3  urgent, urgentSurgical, priority, routine, convenience   (u8 each)
//   L4  equipment flags u8
//   L5  litter u8, ambulatory u8
//   L6  security u8
//   L7  marking u8, [detailLen][detail]
//   L8  usMilitary, usCivilian, nonUsMilitary, nonUsCivilian, epw, child
//   L9  terrain flags u8, nbc u8
//   [placeLen][place][remarksLen][remarks]
//
// Line 1 is the position. The largest request is under 150 bytes.

part of 'team_wire.dart';

const int teamMaxCasevacFreqBytes = 12;
const int teamMaxCasevacCallsignBytes = 12;
const int teamMaxCasevacMarkingBytes = 12;
const int teamMaxCasevacPlaceBytes = 20;
const int teamMaxCasevacRemarksBytes = 40;

/// Line 4: special equipment.
enum CasevacEquipment {
  none('None', 'A'),
  hoist('Hoist', 'B'),
  extraction('Extraction equipment', 'C'),
  ventilator('Ventilator', 'D'),
  other('Other', 'E');

  const CasevacEquipment(this.label, this.letter);
  final String label;
  final String letter;
}

/// Line 6: security at the pickup site.
enum CasevacSecurity {
  noEnemy('No enemy troops', 'N'),
  possibleEnemy('Possible enemy', 'P'),
  enemy('Enemy in area, approach with caution', 'E'),
  armedEscort('Enemy in area, armed escort required', 'X');

  const CasevacSecurity(this.label, this.letter);
  final String label;
  final String letter;

  static CasevacSecurity fromIndex(int i) =>
      i >= 0 && i < values.length ? values[i] : noEnemy;
}

/// Line 7: how the pickup zone is marked.
enum CasevacMarking {
  panels('Panels', 'A'),
  pyro('Pyrotechnic', 'B'),
  smoke('Smoke', 'C'),
  none('None', 'D'),
  other('Other', 'E');

  const CasevacMarking(this.label, this.letter);
  final String label;
  final String letter;

  static CasevacMarking fromIndex(int i) =>
      i >= 0 && i < values.length ? values[i] : none;
}

/// Line 9 (peacetime): terrain and obstacles at the pickup zone.
enum CasevacTerrain {
  none('Flat / none'),
  slope('Slope'),
  rough('Rough'),
  loose('Loose debris'),
  other('Other');

  const CasevacTerrain(this.label);
  final String label;
}

/// Line 9 (wartime): NBC contamination.
enum CasevacNbc {
  none('None', '-'),
  nuclear('Nuclear', 'N'),
  biological('Biological', 'B'),
  chemical('Chemical', 'C');

  const CasevacNbc(this.label, this.letter);
  final String label;
  final String letter;

  static CasevacNbc fromIndex(int i) =>
      i >= 0 && i < values.length ? values[i] : none;
}

int _flags<T extends Enum>(Set<T> s) => s.fold(0, (a, e) => a | (1 << e.index));

Set<T> _unflags<T extends Enum>(int f, List<T> values) => {
  for (final v in values)
    if (f & (1 << v.index) != 0) v,
};

class TeamCasevac {
  final String authorKey4;
  final int requestId;
  final bool deleted;
  final double lat, lon;
  final DateTime time;

  // Line 2.
  final String frequency;
  final String callsign;

  // Line 3: patients by precedence.
  final int urgent, urgentSurgical, priority, routine, convenience;

  // Line 4.
  final Set<CasevacEquipment> equipment;

  // Line 5: patients by type.
  final int litter, ambulatory;

  // Line 6.
  final CasevacSecurity security;

  // Line 7.
  final CasevacMarking marking;
  final String markingDetail;

  // Line 8: patients by nationality and status.
  final int usMilitary, usCivilian, nonUsMilitary, nonUsCivilian, epw, child;

  // Line 9.
  final Set<CasevacTerrain> terrain;
  final CasevacNbc nbc;

  final String place;
  final String remarks;

  const TeamCasevac({
    required this.authorKey4,
    required this.requestId,
    required this.lat,
    required this.lon,
    required this.time,
    this.deleted = false,
    this.frequency = '',
    this.callsign = '',
    this.urgent = 0,
    this.urgentSurgical = 0,
    this.priority = 0,
    this.routine = 0,
    this.convenience = 0,
    this.equipment = const {},
    this.litter = 0,
    this.ambulatory = 0,
    this.security = CasevacSecurity.noEnemy,
    this.marking = CasevacMarking.none,
    this.markingDetail = '',
    this.usMilitary = 0,
    this.usCivilian = 0,
    this.nonUsMilitary = 0,
    this.nonUsCivilian = 0,
    this.epw = 0,
    this.child = 0,
    this.terrain = const {},
    this.nbc = CasevacNbc.none,
    this.place = '',
    this.remarks = '',
  });

  String get key => '$authorKey4:${requestId.toRadixString(16)}';

  int get totalPatients =>
      urgent + urgentSurgical + priority + routine + convenience;

  /// Most urgent precedence present, for colour and headline.
  String get precedenceLabel {
    if (urgent + urgentSurgical > 0) return 'URGENT';
    if (priority > 0) return 'PRIORITY';
    if (routine > 0) return 'ROUTINE';
    if (convenience > 0) return 'CONVENIENCE';
    return 'CASEVAC';
  }

  TeamCasevac copyWith({bool? deleted, DateTime? time}) => TeamCasevac(
    authorKey4: authorKey4,
    requestId: requestId,
    lat: lat,
    lon: lon,
    time: time ?? this.time,
    deleted: deleted ?? this.deleted,
    frequency: frequency,
    callsign: callsign,
    urgent: urgent,
    urgentSurgical: urgentSurgical,
    priority: priority,
    routine: routine,
    convenience: convenience,
    equipment: equipment,
    litter: litter,
    ambulatory: ambulatory,
    security: security,
    marking: marking,
    markingDetail: markingDetail,
    usMilitary: usMilitary,
    usCivilian: usCivilian,
    nonUsMilitary: nonUsMilitary,
    nonUsCivilian: nonUsCivilian,
    epw: epw,
    child: child,
    terrain: terrain,
    nbc: nbc,
    place: place,
    remarks: remarks,
  );

  static String _counts(List<(String, int)> c) => [
    for (final (l, n) in c)
      if (n > 0) '$l$n',
  ].join(' ');

  /// The 9 lines, short form.
  List<String> nineLines() {
    final eq = equipment.isEmpty || equipment.contains(CasevacEquipment.none)
        ? 'A None'
        : equipment.map((e) => '${e.letter} ${e.label}').join(', ');
    final ter = terrain.isEmpty
        ? 'Flat / none'
        : terrain.map((t) => t.label).join(', ');
    return [
      '1 ${lat.toStringAsFixed(5)}, ${lon.toStringAsFixed(5)}'
          '${place.isNotEmpty ? ' $place' : ''}',
      '2 ${[if (frequency.isNotEmpty) frequency, if (callsign.isNotEmpty) callsign].join(' / ').ifEmpty('-')}',
      '3 ${_counts([('A', urgent), ('B', urgentSurgical), ('C', priority), ('D', routine), ('E', convenience)]).ifEmpty('-')}',
      '4 $eq',
      '5 ${_counts([('L', litter), ('A', ambulatory)]).ifEmpty('-')}',
      '6 ${security.letter} ${security.label}',
      '7 ${marking.letter} ${marking.label}'
          '${markingDetail.isNotEmpty ? ' ($markingDetail)' : ''}',
      '8 ${_counts([('A', usMilitary), ('B', usCivilian), ('C', nonUsMilitary), ('D', nonUsCivilian), ('E', epw), ('F', child)]).ifEmpty('-')}',
      '9 $ter${nbc == CasevacNbc.none ? '' : ' / NBC ${nbc.label}'}',
    ];
  }

  String get timeLabel {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(time.month)}-${two(time.day)} '
        '${two(time.hour)}:${two(time.minute)}';
  }

  /// As a plain text message for MeshCore apps without VOX.
  String condensedText({int maxChars = 150}) {
    final t = [
      '🚑 $precedenceLabel CASEVAC $timeLabel',
      ...nineLines(),
      if (remarks.isNotEmpty) remarks,
    ].join('\n');
    return t.length <= maxChars ? t : '${t.substring(0, maxChars - 1)}…';
  }

  Uint8List encode() {
    final w = _W()
      ..u8(teamMsgCasevac)
      ..bytes(_key4(authorKey4))
      ..u32(requestId)
      ..u8(deleted ? 1 : 0)
      ..i32(_deg(lat))
      ..i32(_deg(lon))
      ..u32(time.millisecondsSinceEpoch ~/ 1000)
      ..str(frequency, teamMaxCasevacFreqBytes)
      ..str(callsign, teamMaxCasevacCallsignBytes);
    for (final n in [urgent, urgentSurgical, priority, routine, convenience]) {
      w.u8(n.clamp(0, 255));
    }
    w
      ..u8(_flags(equipment))
      ..u8(litter.clamp(0, 255))
      ..u8(ambulatory.clamp(0, 255))
      ..u8(security.index)
      ..u8(marking.index)
      ..str(markingDetail, teamMaxCasevacMarkingBytes);
    for (final n in [
      usMilitary,
      usCivilian,
      nonUsMilitary,
      nonUsCivilian,
      epw,
      child,
    ]) {
      w.u8(n.clamp(0, 255));
    }
    w
      ..u8(_flags(terrain))
      ..u8(nbc.index)
      ..str(place, teamMaxCasevacPlaceBytes)
      ..str(remarks, teamMaxCasevacRemarksBytes);
    return w.done();
  }

  static TeamCasevac? tryParse(Uint8List p) {
    final r = _R(p);
    if (!r.has(22) || r.u8() != teamMsgCasevac) return null;
    final key = teamKey4Hex(r.take(4));
    final id = r.u32();
    final op = r.u8();
    final lat = _undeg(r.i32()), lon = _undeg(r.i32());
    if (lat.abs() > 90 || lon.abs() > 180) return null;
    final t = DateTime.fromMillisecondsSinceEpoch(r.u32() * 1000);
    final freq = r.str(), cs = r.str();
    if (freq == null || cs == null || !r.has(10)) return null;
    final prec = [for (var i = 0; i < 5; i++) r.u8()];
    final eq = _unflags(r.u8(), CasevacEquipment.values);
    final litter = r.u8(), amb = r.u8();
    final sec = CasevacSecurity.fromIndex(r.u8());
    final mark = CasevacMarking.fromIndex(r.u8());
    final markDetail = r.str();
    if (markDetail == null || !r.has(8)) return null;
    final nat = [for (var i = 0; i < 6; i++) r.u8()];
    final ter = _unflags(r.u8(), CasevacTerrain.values);
    final nbc = CasevacNbc.fromIndex(r.u8());
    final place = r.str(), remarks = r.str();
    if (place == null || remarks == null) return null;
    return TeamCasevac(
      authorKey4: key,
      requestId: id,
      deleted: op == 1,
      lat: lat,
      lon: lon,
      time: t,
      frequency: freq,
      callsign: cs,
      urgent: prec[0],
      urgentSurgical: prec[1],
      priority: prec[2],
      routine: prec[3],
      convenience: prec[4],
      equipment: eq,
      litter: litter,
      ambulatory: amb,
      security: sec,
      marking: mark,
      markingDetail: markDetail,
      usMilitary: nat[0],
      usCivilian: nat[1],
      nonUsMilitary: nat[2],
      nonUsCivilian: nat[3],
      epw: nat[4],
      child: nat[5],
      terrain: ter,
      nbc: nbc,
      place: place,
      remarks: remarks,
    );
  }
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}
