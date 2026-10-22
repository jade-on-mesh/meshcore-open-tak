import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/team/team_setup.dart';

// Golden strings shared with Wadamesh TAK's test/test_team_setup.cpp.
const _link =
    'meshcore://team/join?n=Ops%20Team&s=00112233445566778899aabbccddeeff'
    '&w=%23icewatch,%23dronewatch,Hunt%20Camp:ffeeddccbbaa99887766554433221100'
    '&m=911150,250000,7,5';
const _part1 =
    'MCT:abdd:1/2:meshcore://team/join?n=Ops%20Team'
    '&s=00112233445566778899aabbccddeeff&w=%23icewatch,%23dronewatch,'
    'Hunt%20Camp:ffeeddccbbaa9988';
const _part2 = 'MCT:abdd:2/2:7766554433221100&m=911150,250000,7,5';

const _setup = TeamSetup(
  teamName: 'Ops Team',
  teamSecretHex: '00112233445566778899aabbccddeeff',
  watched: [
    TeamSetupChannel('#icewatch'),
    TeamSetupChannel('#dronewatch'),
    TeamSetupChannel('Hunt Camp', 'ffeeddccbbaa99887766554433221100'),
  ],
  mediaMesh: TeamSetupMediaMesh(
    frequencyKHz: 911150,
    bandwidthHz: 250000,
    sf: 7,
    cr: 5,
  ),
);

void main() {
  test('the link', () {
    expect(_setup.toLink(), _link);
    final back = TeamSetup.parse(_link)!;
    expect(back.teamName, 'Ops Team');
    expect(back.teamSecretHex, '00112233445566778899aabbccddeeff');
    expect(back.watched, _setup.watched);
    expect(back.mediaMesh!.frequencyKHz, 911150);
    expect(back.mediaMesh!.bandwidthHz, 250000);
    expect(back.mediaMesh!.label, '911.150 MHz · 250 kHz · SF7 · CR 4/5');
  });

  test('just a team channel fits one sound message', () {
    const s = TeamSetup(
      teamName: 'Ops',
      teamSecretHex: '00112233445566778899aabbccddeeff',
    );
    expect(s.soundParts(), [
      'meshcore://team/join?n=Ops&s=00112233445566778899aabbccddeeff',
    ]);
  });

  test('a long one goes as parts, heard in any order', () {
    final parts = _setup.soundParts();
    expect(parts, [_part1, _part2]);
    for (final p in parts) {
      expect(p.length, lessThanOrEqualTo(teamSetupSoundBytes));
    }
    final a = TeamSetupAssembler();
    expect(a.accept(_part2), isNull);
    expect(a.progress, (1, 2));
    final s = a.accept(_part1)!;
    expect(s.toLink(), _link);
  });

  test('rejects bad links', () {
    expect(TeamSetup.parse('meshcore://team/join?n=Ops&s=123'), isNull);
    expect(TeamSetup.parse('meshcore://channel/add?name=x&secret=00'), isNull);
    final s = TeamSetup.parse(
      'meshcore://team/join?n=Ops&s=00112233445566778899aabbccddeeff'
      '&w=notahashtag,ok:zz&m=1,2,3',
    )!;
    expect(s.watched, isEmpty);
    expect(s.mediaMesh, isNull);
    expect(TeamSetupAssembler.isPart(_part1), isTrue);
    expect(TeamSetupAssembler.isPart('U:Bob|hi'), isFalse);
  });
}
