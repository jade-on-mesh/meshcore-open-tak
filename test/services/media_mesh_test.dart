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
      expect(parseTxMediaReply('> auto'), isNull);
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
}
