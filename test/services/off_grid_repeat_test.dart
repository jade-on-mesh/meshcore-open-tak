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
      expect(buildRadio2RestoreCommand(auto), 'set radio2 910.500,500,8,5,rx');
    });

    test('nothing to put back for radio2 off', () {
      expect(buildRadio2RestoreCommand(Radio2Reply.offReply), isNull);
    });
  });

  group('offGridRadio2Frequency', () {
    test('800 kHz above in the US band, below near its top', () {
      expect(offGridRadio2Frequency(918.0), 918.8);
      expect(offGridRadio2Frequency(927.8), 927.0);
    });

    test('none outside the US band', () {
      expect(offGridRadio2Frequency(869.495), isNull);
      expect(offGridRadio2Frequency(433.0), isNull);
    });

    test('clear of a 62.5 kHz main channel', () {
      final apartKHz = (offGridRadio2Frequency(918.0)! - 918.0) * 1000;
      expect(apartKHz, greaterThan((62.5 + 250) / 2 + 6));
    });
  });

  group('holdForOffGridRepeat', () {
    test(
      'Keymind Cascade, US: radio2 beside, cross off, media on it',
      () async {
        final c = _CliConnector({
          'get radio2': '> 911.150,250.00,7,5,rxtx',
          'get tx.media': '> tx.media auto; active=radio2',
          'get radio2.cross': '> on',
        });
        final hold = await MediaMeshController(c).holdForOffGridRepeat(918.0);
        expect(c.sent, [
          'get radio2',
          'get tx.media',
          'get radio2.cross',
          'set radio2 918.800,250,7,5,rxtx',
          'set radio2.cross off',
          'set tx.media radio2',
        ]);
        expect(hold.radio2Restore, 'set radio2 911.150,250,7,5,rxtx');
        expect(hold.txMedia, 'auto');
        expect(hold.cross, 'on');
      },
    );

    test('Keymind Cascade, US, radio2 was off: put back off', () async {
      final c = _CliConnector({
        'get radio2': '> off',
        'get tx.media': '> tx.media radio2',
        'get radio2.cross': '> off',
      });
      final hold = await MediaMeshController(c).holdForOffGridRepeat(918.0);
      expect(hold.radio2Restore, 'set radio2 off');
      expect(hold.txMedia, isNull); // already radio2
      expect(hold.cross, isNull); // already off
      expect(c.sent.last, 'set radio2.cross off');
    });

    test(
      'Keymind Cascade, EU868: radio2 off, media to the main radio',
      () async {
        final c = _CliConnector({
          'get radio2': '> 869.525,125.00,5,7,rxtx',
          'get tx.media': '> tx.media radio2; active=radio2',
          'get radio2.cross': '> off',
        });
        final hold = await MediaMeshController(c).holdForOffGridRepeat(869.495);
        expect(c.sent.sublist(3), ['set tx.media radio', 'set radio2 off']);
        expect(hold.radio2Restore, 'set radio2 869.525,125,5,7,rxtx');
        expect(hold.txMedia, 'radio2');
      },
    );

    test('EU868 with radio2 already off: nothing to change', () async {
      final c = _CliConnector({
        'get radio2': '> off',
        'get tx.media': '> tx.media auto',
        'get radio2.cross': '> auto',
      });
      final hold = await MediaMeshController(c).holdForOffGridRepeat(869.495);
      expect(hold.radio2Restore, isNull);
      expect(c.sent.where((s) => s.startsWith('set ')), isEmpty);
    });

    test('Wadamesh TAK sets radio2 itself: nothing sent', () async {
      final c = _CliConnector({
        'get radio2':
            '> 918.800,250.00,7,5,rxtx; client repeat is on (radio2 back to rxtx when it is off)',
      });
      final hold = await MediaMeshController(c).holdForOffGridRepeat(918.0);
      expect(hold.radio2Restore, isNull);
      expect(c.sent, ['get radio2']);
    });

    test('a radio without radio2: nothing sent', () async {
      final c = _CliConnector({'get radio2': 'Unknown command'});
      await MediaMeshController(c).holdForOffGridRepeat(918.0);
      expect(c.sent, ['get radio2']);
    });

    test('a refused radio2 throws', () async {
      final c = _CliConnector({
        'get radio2': '> 911.150,250.00,7,5,rxtx',
        'get tx.media': '> tx.media auto',
        'get radio2.cross': '> off',
        'set radio2 918.800,250,7,5,rxtx': 'Error: busy',
      });
      expect(
        MediaMeshController(c).holdForOffGridRepeat(918.0),
        throwsA(isA<MediaMeshException>()),
      );
    });
  });

  test('releaseAfterOffGridRepeat puts it all back', () async {
    final c = _CliConnector({});
    await MediaMeshController(c).releaseAfterOffGridRepeat(
      const OffGridRadio2Hold(
        radio2Restore: 'set radio2 911.150,250,7,5,rxtx',
        txMedia: 'auto',
        cross: 'on',
      ),
    );
    expect(c.sent, [
      'set radio2 911.150,250,7,5,rxtx',
      'set radio2.cross on',
      'set tx.media auto',
    ]);
    final none = _CliConnector({});
    await MediaMeshController(
      none,
    ).releaseAfterOffGridRepeat(const OffGridRadio2Hold());
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
        cross: 'on',
      );
      final back = OffGridRepeatMemory.fromJson(
        jsonDecode(jsonEncode(m.toJson())),
      )!;
      expect(back.radio!.freqHz, 910525);
      expect(back.radio!.bwHz, 62500);
      expect(back.radio!.txPowerDbm, 22);
      expect(back.radio2Restore, m.radio2Restore);
      expect(back.txMedia, 'radio2');
      expect(back.cross, 'on');
      expect(back.holdsRadio2, isTrue);
      expect(const OffGridRepeatMemory().holdsRadio2, isFalse);
    });

    test('ignores anything that is not a radio2 command', () {
      final m = OffGridRepeatMemory.fromJson({
        'radio2Restore': 'erase',
        'radio': {'freqHz': 'x'},
        'txMedia': 'rm -rf',
      })!;
      expect(m.radio2Restore, isNull);
      expect(m.txMedia, isNull);
      expect(m.radio, isNull);
      expect(OffGridRepeatMemory.fromJson('nope'), isNull);
    });
  });
}
