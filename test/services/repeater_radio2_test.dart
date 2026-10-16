import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/models/radio_settings.dart';
import 'package:meshcore_open/services/media_mesh.dart';
import 'package:meshcore_open/services/repeater_radio2.dart';

/// Replies as mikecarper/MeshCore's RadioProfileCLI.cpp writes them.
void main() {
  test('get radio2 with preamble', () {
    final auto = Radio2Reply.tryParse('> 911.500,250.000,7,5,rxtx,32 (auto)')!;
    expect(auto.preamble, 32);
    expect(auto.preambleAuto, isTrue);
    final fixed = Radio2Reply.tryParse('> 911.500,250.000,7,5,rx,72')!;
    expect(fixed.preamble, 72);
    expect(fixed.preambleAuto, isFalse);
    final p = Radio2Profile.fromReply(fixed);
    expect(p.mode, Radio2Mode.rx);
    expect(p.preamble, 72);
    expect(p.setCommand, 'set radio2 911.500,250,7,5,rx,72');
    expect(
      Radio2Profile.fromReply(auto).setCommand,
      'set radio2 911.500,250,7,5,rxtx',
    );
    final off = Radio2Profile.fromReply(Radio2Reply.tryParse('> off')!);
    expect(off.mode, Radio2Mode.off);
    expect(off.setCommand, 'set radio2 off');
    expect(off.tempCommand(60), 'set tempradio2 911.500,250,7,5,rxtx,60');
  });

  test('status line', () {
    final s = Radio2Status.tryParse(
      '> rxtx; RX=12,40 TX=3,9 switches=5120 errors=2 max=1203us '
      'preamble=32,64; test=4/4,4/4 ready budget=1324us',
    )!;
    expect(s.rx, [12, 40]);
    expect(s.tx, [3, 9]);
    expect(s.switches, 5120);
    expect(s.switchErrors, 2);
    expect(s.longestSwitchUs, 1203);
    expect(s.preamble, [32, 64]);
    expect(s.switchUs, 1324);
    expect(s.switchMeasured, isTrue);
    final pending = Radio2Status.tryParse(
      '> radio2 change pending reply transmission; previous channel retained',
    )!;
    expect(pending.pending, isTrue);
  });

  test('tx.reply', () {
    final a = TxReplySetting.tryParse('> both force')!;
    expect(a.route, ReplyRoute.both);
    expect(a.force, isTrue);
    expect(a.command, 'set tx.reply both force');
    final b = TxReplySetting.tryParse('> radio2; radio2 TX unavailable')!;
    expect(b.route, ReplyRoute.radio2);
    expect(b.radio2Unavailable, isTrue);
    expect(
      const TxReplySetting(route: ReplyRoute.radio, force: true).command,
      'set tx.reply radio',
    );
    expect(TxReplySetting.tryParse('Unknown command'), isNull);
  });

  test('main radio and same-channel check', () {
    final main = MainRadio.tryParse('> 910.525,62.5,7,5')!;
    expect(main.frequencyMHz, 910.525);
    expect(main.bandwidthKHz, 62.5);
    const p = Radio2Profile(
      mode: Radio2Mode.rxtx,
      frequencyMHz: 910.525,
      bandwidth: LoRaBandwidth.bw62_5,
      spreadingFactor: LoRaSpreadingFactor.sf7,
      codingRate: LoRaCodingRate.cr4_5,
    );
    expect(p.sameChannelAs(main), isTrue);
    expect(p.copyWith(frequencyMHz: 911.5).sameChannelAs(main), isFalse);
  });

  test('controller: errors and missing firmware', () async {
    final replies = {
      'get radio2': 'Unknown command',
      'set radio2 off': 'Error: this role requires local USB for radio2 changes',
      'set radio2.cross on': 'OK',
    };
    final c = RepeaterRadio2Controller((cmd) async => replies[cmd]!);
    expect(await c.radio2(), isNull);
    expect(await c.setCross(Radio2Cross.on), 'OK');
    await expectLater(
      c.applyProfile(Radio2Profile.defaults),
      throwsA(
        isA<Radio2CommandException>().having((e) => e.needsUsb, 'usb', true),
      ),
    );
  });

  test('radio2 at 250 kHz SF7 is much faster than 62.5 kHz SF7', () {
    final main = Radio2Profile.airtimeMs(bandwidthHz: 62500, sf: 7, cr: 5);
    final r2 = Radio2Profile.airtimeMs(bandwidthHz: 250000, sf: 7, cr: 5);
    expect(main / r2, closeTo(4, 0.01));
  });
}
