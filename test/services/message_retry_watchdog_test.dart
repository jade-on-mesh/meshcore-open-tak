import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/models/contact.dart';
import 'package:meshcore_open/models/message.dart';
import 'package:meshcore_open/services/message_retry_service.dart';

Contact _contact({int pathLength = -1, List<int> path = const []}) => Contact(
  publicKey: Uint8List.fromList(List<int>.generate(32, (i) => 0xAA + i)),
  name: 'Test',
  type: 1,
  pathLength: pathLength,
  path: Uint8List.fromList(path),
  lastSeen: DateTime.now(),
);

void main() {
  late MessageRetryService service;
  late Map<String, Message> latest;
  late List<({int attempt, int timestamp})> sends;
  late int timeoutMs;
  late List<({int pathLength, int tripTimeMs})> observed;
  final selfKey = Uint8List(32);

  setUp(() {
    service = MessageRetryService(
      sentWatchdogGrace: const Duration(milliseconds: 10),
    );
    latest = {};
    sends = [];
    timeoutMs = 20;
    observed = [];
    service.initialize(
      RetryServiceConfig(
        sendMessage: (_, _, attempt, timestamp) async {
          sends.add((attempt: attempt, timestamp: timestamp));
        },
        addMessage: (_, m) => latest[m.messageId] = m,
        updateMessage: (m) => latest[m.messageId] = m,
        getSelfPublicKey: () => selfKey,
        calculateTimeout: (_, _, {String? contactKey, int? deviceTimeoutMs}) =>
            timeoutMs,
        onDeliveryObserved: (_, pathLength, _, tripTimeMs) =>
            observed.add((pathLength: pathLength, tripTimeMs: tripTimeMs)),
      ),
    );
  });

  tearDown(() => service.dispose());

  int ackHashFor(int attempt) => MessageRetryService.computeExpectedAckHash(
    sends.first.timestamp,
    attempt,
    'hello',
    selfKey,
  );

  test('missing RESP_CODE_SENT times out and retries', () async {
    // A direct path uses the direct budget (default 4). A flood path would
    // stop after the default single flood attempt.
    await service.sendMessageWithRetry(
      contact: _contact(pathLength: 1, path: const [0x11]),
      text: 'hello',
    );
    await pumpEventQueue();
    expect(sends.map((s) => s.attempt), [0]);

    // Watchdog (20ms + 10ms grace) fires, then the 1s retry backoff.
    await Future<void>.delayed(const Duration(milliseconds: 1200));

    expect(sends.map((s) => s.attempt), [0, 1]);
  });

  test('RESP_CODE_SENT replaces the watchdog without a double retry', () async {
    await service.sendMessageWithRetry(contact: _contact(), text: 'hello');
    await pumpEventQueue();

    timeoutMs = 60000;
    expect(service.updateMessageFromSent(ackHashFor(0), 0), isTrue);

    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(sends, hasLength(1));
    expect(latest.values.single.status, MessageStatus.sent);
  });

  // #145: a companion that stamps its own time (Wadamesh TAK) returns an ACK
  // the app can't predict. Its SENT is matched by the command it answers,
  // and the delivery confirmation with that ACK then delivers the message.
  test("SENT with the firmware's own ACK is matched by its command", () async {
    final contact = _contact();
    await service.sendMessageWithRetry(contact: contact, text: 'hello');
    await pumpEventQueue();

    timeoutMs = 60000;
    const firmwareAck = 0x0BADF00D;
    expect(firmwareAck, isNot(ackHashFor(0)));
    // Unmatched without knowing which command it answers (the old behaviour).
    expect(service.updateMessageFromSent(firmwareAck, 0), isFalse);
    final sentFor = (
      contactKey: contact.publicKeyHex,
      timestampSeconds: sends.first.timestamp,
      attempt: 0,
    );
    expect(
      service.updateMessageFromSent(firmwareAck, 0, sentFor: sentFor),
      isTrue,
    );
    expect(latest.values.single.status, MessageStatus.sent);

    service.handleAckReceived(firmwareAck, 900);
    expect(latest.values.single.status, MessageStatus.delivered);
    expect(service.hasPendingMessages, isFalse);

    // No retry went out: the recipient gets it once.
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    expect(sends, hasLength(1));
  });

  test('a SENT for an attempt already retried is not taken', () async {
    final contact = _contact();
    await service.sendMessageWithRetry(contact: contact, text: 'hello');
    await pumpEventQueue();
    // The watchdog gives up on attempt 0; the message moves on to attempt 1.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(latest.values.single.retryCount, 1);

    final stale = (
      contactKey: contact.publicKeyHex,
      timestampSeconds: sends.first.timestamp,
      attempt: 0,
    );
    expect(
      service.updateMessageFromSent(0x0BADF00D, 0, sentFor: stale),
      isFalse,
    );
  });

  test('late ACK for an attempt whose SENT was lost still delivers', () async {
    await service.sendMessageWithRetry(
      contact: _contact(pathLength: 1, path: const [0x11]),
      text: 'hello',
    );
    await pumpEventQueue();

    // Let the watchdog fire; the retry is now waiting on its backoff.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(latest.values.single.retryCount, 1);

    service.handleAckReceived(ackHashFor(0), 500);

    expect(latest.values.single.status, MessageStatus.delivered);
    expect(service.hasPendingMessages, isFalse);

    // The cancelled backoff must not resend.
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    expect(sends, hasLength(1));
  });

  test('late ACK is observed with the path of the attempt it acks', () async {
    final direct = _contact(pathLength: 2, path: [0x11, 0x22]);
    await service.sendMessageWithRetry(contact: direct, text: 'hello');
    await pumpEventQueue();

    // Attempt 0 times out; the retry then goes out as a flood.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    service.updatePendingContact(_contact());
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    expect(sends.map((s) => s.attempt), [0, 1]);

    service.handleAckReceived(ackHashFor(0), 700);

    expect(latest.values.single.status, MessageStatus.delivered);
    expect(observed, [(pathLength: 2, tripTimeMs: 700)]);
  });
}
