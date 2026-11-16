import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/models/image_codec_support.dart';
import 'package:meshcore_open/services/image_chunk_transport.dart';
import 'package:meshcore_open/services/received_image_store.dart';
import 'package:meshcore_open/vox/aeic_hd_repair.dart';
import 'package:meshcore_open/widgets/image_send_codec_binding.dart';

class _Connector extends MeshCoreConnector {
  bool connected = true;

  @override
  bool get isConnected => connected;
}

/// Records each try instead of using radio2, which answers "can't send".
class _Repair extends AeicHdRepairService {
  final List<String> asked = <String>[];

  _Repair({
    required super.connector,
    required super.store,
    required super.reassembler,
    required super.clock,
  }) : super(autoResume: false);

  @override
  Future<bool> requestRest(
    ReceivedImageEntry entry, {
    int round = 1,
    bool auto = false,
  }) async {
    asked.add(entry.streamId);
    return false;
  }
}

void main() {
  late DateTime t;
  late ReceivedImageStore store;
  late ImageReassembler reassembler;
  late _Connector connector;
  late _Repair repair;

  setUp(() {
    t = DateTime(2026, 11, 15, 12);
    store = ReceivedImageStore(decoder: null, clock: () => t);
    reassembler = ImageReassembler(clock: () => t);
    connector = _Connector();
    repair = _Repair(
      connector: connector,
      store: store,
      reassembler: reassembler,
      clock: () => t,
    );
  });

  tearDown(() => repair.dispose());

  ImageChunkSet hdImage(int imgId) => buildImageChunks(
    payload: Uint8List.fromList(List<int>.generate(1200, (i) => i * 7 & 0xFF)),
    metadata: const ImageStreamMetadata(rate: ImageCodecRatePoint.hd),
    senderPrefix: 0x8c41,
    imgId: imgId,
  );

  /// An HD image that got its first chunk, then [fail]ed incomplete.
  Future<ReceivedImageEntry> partial(int imgId, {bool fail = true}) async {
    final set = hdImage(imgId);
    final e = await store.handleOutcome(
      reassembler.addChunk(set.blobs[0]),
      channelIndex: 0,
    );
    if (fail) {
      await store.handleFailure(
        ImageReassemblyFailure(
          key: e!.key,
          total: set.dataChunkCount,
          receivedDataChunks: 1,
          hadParity: false,
          firstSeen: e.firstSeen,
          expiredAt: t,
        ),
      );
    }
    return store.entryFor(e!.streamId)!;
  }

  Future<void> after(Duration d) async {
    t = t.add(d);
    await repair.autoResumeTick();
  }

  test(
    'an incomplete image is asked for again, further apart each time',
    () async {
      final e = await partial(9);
      await repair.autoResumeTick();
      expect(repair.asked, isEmpty);
      expect(repair.autoResumeFor(e.streamId), isNotNull);

      await after(AeicHdRepairService.autoBackoff[0]);
      expect(repair.asked, [e.streamId]);
      expect(repair.autoResumeFor(e.streamId)!.attempts, 1);

      await after(
        AeicHdRepairService.autoBackoff[1] - const Duration(seconds: 1),
      );
      expect(repair.asked, hasLength(1));
      await after(const Duration(seconds: 1));
      expect(repair.asked, hasLength(2));

      // The longest pause repeats, up to the tries that bring nothing.
      final cap = AeicHdRepairService.autoMaxIdleTries;
      for (var i = 2; i < cap; i++) {
        final k = min(i, AeicHdRepairService.autoBackoff.length - 1);
        await after(AeicHdRepairService.autoBackoff[k]);
      }
      expect(repair.asked, hasLength(cap));
      // Then it stops by itself rather than asking every 5 minutes all day.
      for (var i = 0; i < 4; i++) {
        await after(AeicHdRepairService.autoBackoff.last);
      }
      expect(repair.asked, hasLength(cap));
      expect(repair.autoResumeStopped(e.streamId), isTrue);
    },
  );

  test('a try that brings chunks counts again from there', () async {
    final e = await partial(11);
    await repair.autoResumeTick();
    final cap = AeicHdRepairService.autoMaxIdleTries;
    for (var i = 0; i < cap - 1; i++) {
      final k = min(i, AeicHdRepairService.autoBackoff.length - 1);
      await after(AeicHdRepairService.autoBackoff[k]);
    }
    expect(repair.asked, hasLength(cap - 1));
    // One more chunk arrived meanwhile: the count starts over.
    final set = hdImage(11);
    reassembler.expectResend(e.key);
    await store.handleOutcome(reassembler.addChunk(set.blobs[1]), channelIndex: 0);
    for (var i = 0; i < cap; i++) {
      await after(AeicHdRepairService.autoBackoff.last);
    }
    expect(repair.asked.length, greaterThan(cap));
  });

  test('an answer only fills an image this phone is missing pieces of', () {
    final set = hdImage(21);
    const key = ImageStreamKey(senderPrefix: 0x8c41, imgId: 21, channelIndex: 0);
    // Never heard: an answer to someone else's request isn't a new image.
    expect(reassembler.wantsResend(key), isFalse);
    // Under way here: wanted.
    reassembler.addChunk(set.blobs[0]);
    expect(reassembler.wantsResend(key), isTrue);
    // Completed: wanted no more (it was a fresh copy every retry).
    for (final b in set.blobs.skip(1)) {
      reassembler.addChunk(b);
    }
    expect(reassembler.wantsResend(key), isFalse);
  });

  test('waits while the radio is disconnected', () async {
    await partial(9);
    connector.connected = false;
    await repair.autoResumeTick();
    await after(const Duration(minutes: 10));
    expect(repair.asked, isEmpty);
    connector.connected = true;
    await after(Duration.zero);
    expect(repair.asked, hasLength(1));
  });

  test('Stop ends it for that image only', () async {
    final a = await partial(9);
    final b = await partial(10);
    await repair.autoResumeTick();
    repair.stopAutoResume(a.streamId);
    expect(repair.autoResumeFor(a.streamId), isNull);
    expect(repair.autoResumeStopped(a.streamId), isTrue);
    for (var i = 0; i < 4; i++) {
      await after(const Duration(minutes: 5));
    }
    expect(repair.asked, isNotEmpty);
    expect(repair.asked.every((id) => id == b.streamId), isTrue);
  });

  test('one image per pass', () async {
    await partial(9);
    await partial(10);
    await repair.autoResumeTick();
    await after(AeicHdRepairService.autoBackoff[0]);
    expect(repair.asked, hasLength(1));
    await after(Duration.zero);
    expect(repair.asked, hasLength(2));
    expect(repair.asked.toSet(), hasLength(2));
  });

  test('a stalled download is asked for at once', () async {
    final e = await partial(9, fail: false);
    expect(e.state, ReceivedImageState.receiving);
    await after(AeicHdRepairService.stallAfter - const Duration(seconds: 1));
    expect(repair.asked, isEmpty);
    await after(const Duration(seconds: 1));
    expect(repair.asked, [e.streamId]);
  });

  test('a day-old image is left alone', () async {
    await partial(9);
    t = t.add(AeicHdRepairService.autoMaxAge + const Duration(minutes: 1));
    await repair.autoResumeTick();
    await after(const Duration(minutes: 5));
    expect(repair.asked, isEmpty);
  });
}
