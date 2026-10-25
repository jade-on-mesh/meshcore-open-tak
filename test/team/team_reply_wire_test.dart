import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/helpers/reaction_helper.dart';
import 'package:meshcore_open/team/team_wire.dart';

String _hex(Uint8List b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

// The same golden bytes and hashes as Wadamesh TAK's
// test/test_quick_reply.cpp.
void main() {
  test('team reply golden bytes', () {
    const r = TeamReply(
      senderKey4: 'a1b2c3d4',
      toKey4: '01020304',
      ref: TeamReplyRef.alert,
      refId: 7,
      code: TeamReplyCode.eta,
      arg: 10,
      callsign: 'Sam',
    );
    expect(_hex(r.encode()), '51a1b2c3d4010203040100000007020a0353616d');
    final back = TeamReply.tryParse(r.encode())!;
    expect(back.refKey, 'alert:01020304:7');
    expect(back.code, TeamReplyCode.eta);
    expect(back.arg, 10);
    expect(back.callsign, 'Sam');
    expect(teamPeek(r.encode())!.$1, teamMsgReply);
    // Unknown kinds and codes are dropped.
    final bad = r.encode()..[9] = 9;
    expect(TeamReply.tryParse(bad), isNull);
  });

  test('watched-channel replies', () {
    expect(watchReplyText(TeamReplyCode.onMyWay, '3fa1'), 'On my way ↩3fa1');
    expect(
      watchReplyText(TeamReplyCode.eta, '3fa1', arg: 10),
      'ETA 10 min ↩3fa1',
    );
    final a = parseWatchReply('On my way ↩3fa1')!;
    expect(a.hash, '3fa1');
    expect(a.code, TeamReplyCode.onMyWay);
    final b = parseWatchReply('ETA 20 min ↩00ff')!;
    expect((b.code, b.arg), (TeamReplyCode.eta, 20));
    final c = parseWatchReply('Heading over now ↩beef')!;
    expect((c.code, c.said), (null, 'Heading over now'));
    expect(parseWatchReply('no mark here'), isNull);
    expect(parseWatchReply('↩3fa1'), isNull);
  });

  test('report hashes (as Wadamesh computes them)', () {
    String h(String name, String text) =>
        ReactionHelper.computeReactionHash(1760000000, name, text);
    expect(h('IceBot', '🔴 CRITICAL / 10-03 11:30 / @Auburn'), '9aa8');
    expect(h('IceBot', 'ACTIVE / 10-03'), '477d');
    expect(h('Sam', 'hi'), '73e2');
    expect(h('Sam', 'abcd🔴x'), '01e8'); // cut inside a surrogate pair
    expect(h('Zoë', 'Déjà vu'), '0b16');
  });
}
