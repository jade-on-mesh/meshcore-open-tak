// MeshCore Open TAK - quick replies: one-tap answers tied to the thing they
// answer (docs: documentation/quick-replies.md).
//
// On the team channel, a reply to a teammate's alert, report or pin is
//   reply     [0x51][key4][toKey4][refKind u8][refId u32][code u8][arg u8]
//             [callsignLen][callsign]
// refKind 1 alert (refId = the alert id), 2 report, 3 pin (marker id).
// Wadamesh TAK reads and writes the same (src/ui-touch/TeamWire.h).
//
// A watched channel report (#icewatch and the like) is answered on that
// channel in plain text, so every client can read it:
//   "On my way ↩3fa1"
// where 3fa1 is the report's reaction hash (ReactionHelper.computeReactionHash:
// its sender time, sender name and first five characters), the same id this
// app's emoji reactions use. [parseWatchReply] finds it.

part of 'team_wire.dart';

const int teamMsgReply = 0x51; // 'Q'

/// What a quick reply says. Only the index goes on the air: add at the end.
enum TeamReplyCode {
  copy('Copy'),
  onMyWay('On my way'),
  eta('ETA'),
  cantHelp("Can't help"),
  seenIt('Seen it'),
  needBackup('Need backup'),
  allClear('All clear');

  const TeamReplyCode(this.english);

  /// The text sent on a watched channel (and shown by older readers).
  final String english;

  static TeamReplyCode? fromIndex(int i) =>
      i >= 0 && i < values.length ? values[i] : null;

  /// The words on a watched channel for this reply ("ETA 10 min").
  String wire(int arg) => this == eta ? 'ETA $arg min' : english;
}

/// What a team reply answers.
enum TeamReplyRef {
  none,
  alert,
  report,
  pin;

  static TeamReplyRef fromIndex(int i) =>
      i > 0 && i < values.length ? values[i] : none;
}

/// The replies offered for each kind of item, in order.
const List<TeamReplyCode> teamAlertReplies = [
  TeamReplyCode.copy,
  TeamReplyCode.onMyWay,
  TeamReplyCode.eta,
  TeamReplyCode.cantHelp,
];
const List<TeamReplyCode> teamReportReplies = [
  TeamReplyCode.seenIt,
  TeamReplyCode.onMyWay,
  TeamReplyCode.needBackup,
  TeamReplyCode.allClear,
];

/// The ETA choices, in minutes.
const List<int> teamReplyEtas = [5, 10, 20, 30];

class TeamReply {
  final String senderKey4;
  final String toKey4;
  final TeamReplyRef ref;
  final int refId;
  final TeamReplyCode code;
  final int arg;
  final String callsign;

  const TeamReply({
    required this.senderKey4,
    required this.toKey4,
    required this.ref,
    required this.refId,
    required this.code,
    this.arg = 0,
    this.callsign = '',
  });

  /// The item answered: "alert:a1b2c3d4:7", the same as [TeamAlert.key] with
  /// its kind in front.
  String get refKey => '${ref.name}:$toKey4:$refId';

  Uint8List encode() {
    final w = _W()
      ..u8(teamMsgReply)
      ..bytes(_key4(senderKey4))
      ..bytes(_key4(toKey4))
      ..u8(ref.index)
      ..u32(refId)
      ..u8(code.index)
      ..u8(arg.clamp(0, 255))
      ..str(callsign, teamMaxCallsignBytes);
    return w.done();
  }

  static TeamReply? tryParse(Uint8List p) {
    final r = _R(p);
    if (!r.has(16) || r.u8() != teamMsgReply) return null;
    final from = teamKey4Hex(r.take(4));
    final to = teamKey4Hex(r.take(4));
    final ref = TeamReplyRef.fromIndex(r.u8());
    final id = r.u32();
    final code = TeamReplyCode.fromIndex(r.u8());
    final arg = r.u8();
    if (ref == TeamReplyRef.none || code == null) return null;
    return TeamReply(
      senderKey4: from,
      toKey4: to,
      ref: ref,
      refId: id,
      code: code,
      arg: arg,
      callsign: r.str() ?? '',
    );
  }
}

/// The key of the item a reply to an alert, report or pin answers.
String teamReplyRefKey(TeamReplyRef ref, String key4, int id) =>
    '${ref.name}:$key4:$id';

/// The mark a watched-channel reply ends with: "↩" and the report's hash.
const String watchReplyMark = '↩';

final RegExp _watchReplyRe = RegExp(r'\s*↩([0-9a-f]{4})\s*$');

/// "On my way ↩3fa1" for [code] answering the report whose reaction hash is
/// [hash].
String watchReplyText(TeamReplyCode code, String hash, {int arg = 0}) =>
    '${code.wire(arg)} $watchReplyMark$hash';

/// A quick reply on a watched channel: the hash of the report it answers and
/// what it says ("On my way"), or null.
({String hash, String said, TeamReplyCode? code, int arg})? parseWatchReply(
  String text,
) {
  final m = _watchReplyRe.firstMatch(text);
  if (m == null) return null;
  final said = text.substring(0, m.start).trim();
  if (said.isEmpty || said.length > 40) return null;
  TeamReplyCode? code;
  var arg = 0;
  final eta = RegExp(r'^ETA (\d{1,3}) min$').firstMatch(said);
  if (eta != null) {
    code = TeamReplyCode.eta;
    arg = int.parse(eta.group(1)!);
  } else {
    for (final c in TeamReplyCode.values) {
      if (c != TeamReplyCode.eta && c.english == said) code = c;
    }
  }
  return (hash: m.group(1)!, said: said, code: code, arg: arg);
}
