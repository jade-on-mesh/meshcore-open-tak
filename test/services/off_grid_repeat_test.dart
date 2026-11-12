import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/services/media_mesh.dart';
import 'package:meshcore_open/storage/off_grid_repeat_store.dart';

/// Answers the local CLI from [replies] and records what was sent.
class _CliConnector extends MeshCoreConnector {
  final Map<String, String> replies;
  final List<String> sent = [];
  _CliConnector(this.replies);

  @override
  Future<String> runLocalCliCommand(String command) async {
    sent.add(command);
    return replies[command] ?? (command.startsWith('set ') ? 'OK' : '');
  }
}

void main() {
  group('buildRadio2RestoreCommand', () {
    test('puts back the profile and mode', () {
      final r = Radio2Reply.tryParse('> 911.150,250.00,7,5,rxtx')!;
      expect(buildRadio2RestoreCommand(r), 'set radio2 911.150,250,7,5,rxtx');
    });

    test('keeps a preamble set by hand, not an automatic one', () {
      final manual = Radio2Reply.tryParse('> 910.500,500.00,8,5,rx,88')!;
      expect(
        buildRadio2RestoreCommand(manual),
        'set radio2 910.500,500,8,5,rx,88',
      );
      final auto = Radio2Reply.tryParse('> 910.500,500.00,8,5,rx,32 (auto)')!;
      expect(
        buildRadio2RestoreCommand(auto),
        'set radio2 910.500,500,8,5,rx',
      );
    });

    test('nothing to put back for radio2 off', () {
      expect(buildRadio2RestoreCommand(Radio2Reply.offReply), isNull);
    });
  });

  group('holdForOffGridRepeat', () {
    test('Keymind Cascade: radio2 off, media to the main radio', () async {
      final c = _CliConnector({
        'get radio2': '> 911.150,250.00,7,5,rxtx',
        'get tx.media': '> tx.media radio2; active=radio2',
      });
      final held = await MediaMeshController(c).holdForOffGridRepeat();
      expect(held.radio2Restore, 'set radio2 911.150,250,7,5,rxtx');
      expect(held.txMedia, 'radio2');
      expect(c.sent, [
        'get radio2',
        'get tx.media',
        'set tx.media radio',
        'set radio2 off',
      ]);
    });

    test('media already on the main radio is left alone', () async {
      final c = _CliConnector({
        'get radio2': '> 911.150,250.00,7,5,rx',
        'get tx.media': '> tx.media auto; active=channel/global',
      });
      final held = await MediaMeshController(c).holdForOffGridRepeat();
      expect(held.txMedia, isNull);
      expect(c.sent, ['get radio2', 'get tx.media', 'set radio2 off']);
    });

    test('Wadamesh TAK holds radio2 off itself: nothing sent', () async {
      final c = _CliConnector({
        'get radio2':
            '> off; client repeat is on (radio2 back to rxtx when it is off)',
      });
      final held = await MediaMeshController(c).holdForOffGridRepeat();
      expect(held.radio2Restore, isNull);
      expect(held.txMedia, isNull);
      expect(c.sent, ['get radio2']);
    });

    test('a radio without radio2: nothing sent', () async {
      final c = _CliConnector({'get radio2': 'Unknown command'});
      await MediaMeshController(c).holdForOffGridRepeat();
      expect(c.sent, ['get radio2']);
    });

    test('a refused radio2 off throws', () async {
      final c = _CliConnector({
        'get radio2': '> 911.150,250.00,7,5,rxtx',
        'get tx.media': '> tx.media auto',
        'set radio2 off': 'Error: busy',
      });
      expect(
        MediaMeshController(c).holdForOffGridRepeat(),
        throwsA(isA<MediaMeshException>()),
      );
    });
  });

  test('releaseAfterOffGridRepeat puts both back', () async {
    final c = _CliConnector({});
    await MediaMeshController(c).releaseAfterOffGridRepeat(
      radio2Restore: 'set radio2 911.150,250,7,5,rxtx',
      txMedia: 'radio2',
    );
    expect(c.sent, ['set radio2 911.150,250,7,5,rxtx', 'set tx.media radio2']);
    final none = _CliConnector({});
    await MediaMeshController(none).releaseAfterOffGridRepeat();
    expect(none.sent, isEmpty);
  });

  group('OffGridRepeatMemory', () {
    test('round-trips through JSON', () {
      const m = OffGridRepeatMemory(
        radio: MeshCoreRadioStateSnapshot(
          freqHz: 910525,
          bwHz: 62500,
          sf: 7,
          cr: 5,
          txPowerDbm: 22,
        ),
        radio2Restore: 'set radio2 911.150,250,7,5,rxtx',
        txMedia: 'radio2',
      );
      final back = OffGridRepeatMemory.fromJson(
        jsonDecode(jsonEncode(m.toJson())),
      )!;
      expect(back.radio!.freqHz, 910525);
      expect(back.radio!.bwHz, 62500);
      expect(back.radio!.txPowerDbm, 22);
      expect(back.radio2Restore, m.radio2Restore);
      expect(back.txMedia, 'radio2');
    });

    test('ignores anything that is not a radio2 command', () {
      final m = OffGridRepeatMemory.fromJson({
        'radio2Restore': 'erase',
        'radio': {'freqHz': 'x'},
      })!;
      expect(m.radio2Restore, isNull);
      expect(m.radio, isNull);
      expect(OffGridRepeatMemory.fromJson('nope'), isNull);
    });
  });
}
