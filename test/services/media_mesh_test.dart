import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/connector/pending_command_replies.dart';
import 'package:meshcore_open/models/radio_settings.dart';
import 'package:meshcore_open/services/media_mesh.dart';

void main() {
  group('local CLI frames', () {
    test('CMD_RUN_CLI_COMMAND carries the text after 0x42', () {
      final frame = buildRunCliCommandFrame('get radio2');
      expect(frame[0], 0x42);
      expect(utf8.decode(frame.sublist(1)), 'get radio2');
    });

    test('RESP_CODE_CLI_REPLY text, trailing NULs dropped', () {
      final frame = Uint8List.fromList([
        respCodeCliReply,
        ...utf8.encode('> off'),
        0,
        0,
      ]);
      expect(parseCliReplyFrame(frame), '> off');
      expect(parseCliReplyFrame(Uint8List.fromList([respCodeOk])), '');
    });

    test('the CLI command waits for RESP_CODE_CLI_REPLY', () {
      expect(
        replyCodeForCommand(buildRunCliCommandFrame('get tx.media')),
        respCodeCliReply,
      );
    });
  });

  group('get radio2 replies', () {
    test('Wadamesh form', () {
      final r = Radio2Reply.tryParse('> 916.000,250.00,7,5,rxtx')!;
      expect(r.off, isFalse);
      expect(r.frequencyMHz, 916.0);
      expect(r.bandwidth, LoRaBandwidth.bw250);
      expect(r.spreadingFactor, LoRaSpreadingFactor.sf7);
      expect(r.codingRate, LoRaCodingRate.cr4_5);
      expect(r.canTransmit, isTrue);
    });

    test('mikecarper form with preamble and warnings', () {
      final r = Radio2Reply.tryParse(
        '> 910.500,500.000,7,5,rx,32; WARN recommended preamble: radio2=64',
      )!;
      expect(r.bandwidth, LoRaBandwidth.bw500);
      expect(r.mode, 'rx');
      expect(r.canTransmit, isFalse);
    });

    test('automatic preamble marker', () {
      final r = Radio2Reply.tryParse('> 911.500,250.000,7,5,rxtx,32 (auto)')!;
      expect(r.frequencyMHz, 911.5);
      expect(r.mode, 'rxtx');
      expect(r.canTransmit, isTrue);
    });

    test('off variants and correlation tag', () {
      expect(Radio2Reply.tryParse('> off')!.off, isTrue);
      expect(Radio2Reply.tryParse('> off (manual)')!.off, isTrue);
      expect(Radio2Reply.tryParse('ab|> off')!.off, isTrue);
    });

    test('non-answers', () {
      expect(Radio2Reply.tryParse('Unknown command'), isNull);
      expect(Radio2Reply.tryParse('Error: bad'), isNull);
      expect(Radio2Reply.tryParse('> 916.0,250'), isNull);
      expect(Radio2Reply.tryParse(''), isNull);
    });

    test('narrow bandwidths map back', () {
      expect(bandwidthFromKHz(62.5), LoRaBandwidth.bw62_5);
      expect(bandwidthFromKHz(31.25), LoRaBandwidth.bw31_25);
      expect(bandwidthFromKHz(7.8), LoRaBandwidth.bw7_8);
      expect(bandwidthFromKHz(300), isNull);
    });
  });

  group('commands', () {
    test('set radio2 uses kHz without trailing zeros', () {
      expect(
        buildSetRadio2Command(MediaMeshSettings.defaults),
        'set radio2 911.500,250,7,5,rxtx',
      );
      expect(
        buildSetRadio2Command(
          MediaMeshSettings.defaults.copyWith(
            frequencyMHz: 869.525,
            bandwidth: LoRaBandwidth.bw62_5,
            spreadingFactor: LoRaSpreadingFactor.sf8,
            codingRate: LoRaCodingRate.cr4_8,
          ),
        ),
        'set radio2 869.525,62.5,8,8,rxtx',
      );
      expect(formatBandwidthKHz(LoRaBandwidth.bw31_25), '31.25');
      expect(formatBandwidthKHz(LoRaBandwidth.bw7_8), '7.8');
    });

    test('tx.media replies', () {
      expect(parseTxMediaReply('> radio2'), 'radio2');
      expect(parseTxMediaReply('> radio'), 'radio');
      expect(parseTxMediaReply('Unknown command'), isNull);
      expect(parseTxMediaReply('> auto'), 'auto');
      expect(parseTxMediaReply('> both; active=both'), 'both');
      expect(parseTxMediaReply('> radio2; active=radio2'), 'radio2');
      expect(parseTxMediaReply('> sideways'), isNull);
    });

    test('OK detection', () {
      expect(isCliOk('OK - radio2 off'), isTrue);
      expect(isCliOk('ab|OK - tx.media radio2'), isTrue);
      expect(isCliOk('Error: radio2 matches the main radio'), isFalse);
      expect(isCliOk('Unknown command'), isFalse);
    });

    test('MediaMesh may not sit on the main channel', () {
      expect(
        sameChannelAsMain(
          MediaMeshSettings.defaults.copyWith(
            frequencyMHz: 910.525,
            bandwidth: LoRaBandwidth.bw62_5,
          ),
          mainFreqHz: 910525000,
          mainBwHz: 62500,
          mainSf: 7,
        ),
        isTrue,
      );
      expect(
        sameChannelAsMain(
          MediaMeshSettings.defaults,
          mainFreqHz: 910525000,
          mainBwHz: 62500,
          mainSf: 7,
        ),
        isFalse,
      );
      expect(
        sameChannelAsMain(
          MediaMeshSettings.defaults,
          mainFreqHz: null,
          mainBwHz: null,
          mainSf: null,
        ),
        isFalse,
      );
    });
  });

  group('radio2 UI replies', () {
    test('mode and media choice', () {
      expect(Radio2Mode.fromCli('rx'), Radio2Mode.rx);
      expect(Radio2Mode.fromCli('rx&tx'), Radio2Mode.rxtx);
      expect(Radio2Mode.fromCli('off'), Radio2Mode.off);
      expect(
        MediaChoice.from(media: 'radio2', cross: 'off'),
        MediaChoice.photosAndVoice,
      );
      expect(
        MediaChoice.from(media: 'auto', cross: 'on'),
        MediaChoice.everything,
      );
      expect(MediaChoice.from(media: 'both', cross: 'off'), MediaChoice.custom);
      expect(parseCrossReply('> off'), 'off');
      expect(parseCrossReply('ab|> auto'), 'auto');
      expect(parseCrossReply('Unknown command'), isNull);
    });

    test('listen-only radio2 command', () {
      expect(
        buildSetRadio2Command(
          MediaMeshSettings.defaults.copyWith(mode: Radio2Mode.rx),
        ),
        'set radio2 911.500,250,7,5,rx',
      );
      expect(
        buildTempRadio2Command(MediaMeshSettings.defaults, 60),
        'set tempradio2 911.500,250,7,5,rxtx,60',
      );
    });

    test('radio2.status', () {
      final s = Radio2Status.tryParse(
        '> rxtx; RX=12,40 TX=3,9 switches=5120 errors=0 max=1203us '
        'preamble=32,64; test=4/4 ready budget=1324us; '
        'WARN recommended preamble: radio2=64',
      )!;
      expect(s.mode, 'rxtx');
      expect(s.rx, [12, 40]);
      expect(s.tx, [3, 9]);
      expect(s.switchUs, 1324);
      expect(s.switchMeasured, isTrue);
      expect(s.warnings, ['recommended preamble: radio2=64']);
      final pending = Radio2Status.tryParse(
        '> rx; RX=0,0 TX=0,0 switches=3 errors=0 max=0us preamble=32,64; '
        'test=1/4 pending budget=1500us',
      )!;
      expect(pending.switchMeasured, isFalse);
      expect(Radio2Status.tryParse('Error: x'), isNull);
    });

    test('tempradio2', () {
      final t = TempRadio2.tryParse(
        '> 910.500,500.000,8,5,rxtx,40 (auto); 0d2h0m (120 min) left',
      )!;
      expect(t.frequencyMHz, 910.5);
      expect(t.minutesLeft, 120);
      expect(TempRadio2.tryParse('> off'), isNull);
    });

    test('tx.user and tx.channel', () {
      final u = TxRouteReply.tryParse(
        '> tx.user "Alice Smith" key:0123456789AB radio2; active=radio2',
      )!;
      expect(u.choice, TxChoice.radio2);
      expect(u.active, 'radio2');
      expect(u.boundByName, isFalse);
      final c = TxRouteReply.tryParse(
        'OK - tx.channel 2 "#r2-ops" radio2; active=none '
        '(radio2 unavailable for TX) (#r2- channel)',
      )!;
      expect(c.boundByName, isTrue);
      expect(c.radio2Unavailable, isTrue);
      expect(c.active, 'none');
      expect(
        TxRouteReply.tryParse('> tx.channel 0 "Public" auto; active=radio')!
            .choice,
        TxChoice.auto,
      );
      expect(TxRouteReply.tryParse('Error: user not found'), isNull);
      expect(txUserTarget('ab' * 32), 'key:${'ab' * 16}');
    });
  });
}
