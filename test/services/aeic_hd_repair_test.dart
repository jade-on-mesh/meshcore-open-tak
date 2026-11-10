import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/models/image_codec_support.dart';
import 'package:meshcore_open/services/image_chunk_transport.dart';
import 'package:meshcore_open/services/received_image_store.dart';
import 'package:meshcore_open/vox/aeic_hd_repair.dart';
import 'package:meshcore_open/widgets/image_send_codec_binding.dart';

void main() {
  ImageChunkSet hdImage({int imgId = 9, int bytes = 1200}) => buildImageChunks(
    payload: Uint8List.fromList(List<int>.generate(bytes, (i) => i * 7 & 0xFF)),
    metadata: const ImageStreamMetadata(rate: ImageCodecRatePoint.hd),
    senderPrefix: 0x8c41,
    imgId: imgId,
  );

  group('wire format', () {
    test('announce round-trips and caps the name at 32 bytes', () {
      final p = AeicHdRepairPacket.tryParse(
        encodeAeicHdAnnounce(0x8c41, 9, 'Jade on the mesh'),
      )!;
      expect(p.isRequest, isFalse);
      expect(p.senderPrefix, 0x8c41);
      expect(p.imgId, 9);
      expect(p.name, 'Jade on the mesh');
      final long = encodeAeicHdAnnounce(1, 2, 'é' * 40);
      expect(long.length, lessThanOrEqualTo(4 + 32));
      expect(AeicHdRepairPacket.tryParse(long)!.name, 'é' * 16);
    });

    test('request round-trips', () {
      final p = AeicHdRepairPacket.tryParse(
        encodeAeicHdRequest(
          senderPrefix: 0x8c41,
          imgId: 9,
          total: 8,
          missingMask: 0x80F0,
        ),
      )!;
      expect(p.isRequest, isTrue);
      expect(p.total, 8);
      expect(p.mask, 0x80F0);
    });

    test('a request picks those data chunks, never parity', () {
      final set = hdImage();
      final total = set.dataChunkCount;
      final picked = aeicHdBlobsFor(set.blobs, total, (1 << 1) | 0x8000);
      expect(picked, [set.blobs[1]]);
    });

    test('a request says how many copies follow it', () {
      for (final after in [0, 1, 2]) {
        final q = AeicHdRepairPacket.tryParse(
          encodeAeicHdRequest(
            senderPrefix: 0x8c41,
            imgId: 9,
            total: 8,
            missingMask: 0x0C,
            copiesAfter: after,
          ),
        )!;
        expect(q.isRequest, isTrue);
        expect(q.copiesAfter, after);
        expect(q.mask, 0x0C);
      }
      // An old 7-byte request: none follow.
      final old = AeicHdRepairPacket.tryParse(
        Uint8List.fromList([0x51, 0x8c, 0x41, 9, 8, 0, 0x0C]),
      )!;
      expect(old.copiesAfter, 0);
    });

    test('requests and wrapped chunks differ every time (salt)', () {
      Uint8List req() => encodeAeicHdRequest(
        senderPrefix: 0x8c41,
        imgId: 9,
        total: 8,
        missingMask: 0xFF,
      );
      final seen = {for (var i = 0; i < 20; i++) req()[7]};
      expect(seen.length, greaterThan(1));
      final set = hdImage();
      final w = wrapAeicHdChunk(set.blobs[0]);
      expect(w.length, set.blobs[0].length + 1);
      expect(w.length, lessThanOrEqualTo(kImageChunkBlobBytes));
      expect(unwrapAeicHdChunk(w), set.blobs[0]);
      // Announces and requests aren't taken for chunks.
      expect(unwrapAeicHdChunk(req()), isNull);
      expect(unwrapAeicHdChunk(encodeAeicHdAnnounce(1, 2, 'x')), isNull);
      // Every data chunk still fits once wrapped.
      for (var i = 0; i < set.dataChunkCount; i++) {
        expect(
          wrapAeicHdChunk(set.blobs[i]).length,
          lessThanOrEqualTo(kImageChunkBlobBytes),
        );
      }
    });
  });

  group('reassembler parks partial images', () {
    test('a resend of the missing chunks after the timeout completes it', () {
      final set = hdImage();
      final total = set.dataChunkCount;
      var t = DateTime(2026, 11, 10, 7, 21);
      ImageReassemblyResult? done;
      final r = ImageReassembler(clock: () => t, onImage: (x) => done = x);
      // Half the data chunks arrive, no parity.
      for (var i = 0; i < total; i += 2) {
        r.addChunk(set.blobs[i]);
      }
      t = t.add(kImageReassemblyTtl + const Duration(seconds: 1));
      r.evictExpired();
      expect(r.pendingCount, 0);
      final key = ImageStreamKey(
        senderPrefix: 0x8c41,
        imgId: 9,
        channelIndex: 0,
      );
      final missing = r.missingDataChunks(key)!;
      expect(missing, [for (var i = 1; i < total; i += 2) i]);
      // Asked for, minutes later only the missing ones come back.
      r.expectResend(key);
      t = t.add(const Duration(minutes: 10));
      for (final i in missing) {
        r.addChunk(set.blobs[i]);
      }
      expect(done, isNotNull);
      expect(r.missingDataChunks(key), isNull);
    });

    test('without asking, a late chunk starts afresh (as before)', () {
      final set = hdImage();
      var t = DateTime(2026, 11, 10);
      final r = ImageReassembler(clock: () => t);
      for (var i = 0; i < set.dataChunkCount - 1; i++) {
        r.addChunk(set.blobs[i]);
      }
      t = t.add(kImageReassemblyTtl + const Duration(seconds: 1));
      r.evictExpired();
      final out = r.addChunk(set.blobs[set.dataChunkCount - 1]);
      expect(out.status, ImageChunkStatus.accepted);
    });

    test('a different image reusing the id starts over', () {
      final first = hdImage();
      final second = hdImage(bytes: 1300);
      var t = DateTime(2026, 11, 10);
      final r = ImageReassembler(clock: () => t);
      r.addChunk(first.blobs[0]);
      t = t.add(kImageReassemblyTtl + const Duration(seconds: 1));
      r.evictExpired();
      // Same total, conflicting chunk 0: not merged with the parked one.
      final out = r.addChunk(second.blobs[0]);
      expect(out.status, isNot(ImageChunkStatus.completed));
    });
  });

  group('store', () {
    test('an announced name is the sender label, before or after', () async {
      final store = ReceivedImageStore(decoder: null);
      store.noteSenderName(0x8c41, 9, 'Dave');
      final r = ImageReassembler();
      final set = hdImage();
      final e = await store.handleOutcome(
        r.addChunk(set.blobs[0]),
        channelIndex: 0,
      );
      expect(e!.senderName, 'Dave');
      expect(store.senderNameFor(e), 'Dave');
      // A later image from the same phone, not announced: the last name.
      final other = e.copyWith();
      expect(store.senderNameFor(other), 'Dave');
    });

    test('resuming makes an incomplete image receive again', () async {
      final store = ReceivedImageStore(decoder: null);
      final r = ImageReassembler();
      final set = hdImage();
      final e = await store.handleOutcome(
        r.addChunk(set.blobs[0]),
        channelIndex: 0,
      );
      await store.handleFailure(
        ImageReassemblyFailure(
          key: e!.key,
          total: set.dataChunkCount,
          receivedDataChunks: 1,
          hadParity: false,
          firstSeen: e.firstSeen,
          expiredAt: e.firstSeen,
        ),
      );
      final failed = store.entryFor(e.streamId)!;
      expect(failed.state, ReceivedImageState.failedIncomplete);
      expect(aeicHdResumable(failed), isTrue);
      final resumed = await store.resumeReceiving(e.streamId);
      expect(resumed!.state, ReceivedImageState.receiving);
      await store.resumeGaveUp(e.streamId, resumed.receivedChunks);
      expect(
        store.entryFor(e.streamId)!.state,
        ReceivedImageState.failedIncomplete,
      );
    });

    test('resuming counts from what is still held', () async {
      final store = ReceivedImageStore(decoder: null);
      final r = ImageReassembler();
      final set = hdImage();
      final e = await store.handleOutcome(
        r.addChunk(set.blobs[0]),
        channelIndex: 0,
      );
      await store.handleOutcome(r.addChunk(set.blobs[1]), channelIndex: 0);
      await store.handleFailure(
        ImageReassemblyFailure(
          key: e!.key,
          total: set.dataChunkCount,
          receivedDataChunks: 2,
          hadParity: false,
          firstSeen: e.firstSeen,
          expiredAt: e.firstSeen,
        ),
      );
      expect(store.entryFor(e.streamId)!.receivedChunks, 2);
      // The app restarted: the reassembler holds none of them now.
      final resumed = await store.resumeReceiving(e.streamId, held: 0);
      expect(resumed!.state, ReceivedImageState.receiving);
      expect(resumed.receivedChunks, 0);
      // Some came back but not all: forced incomplete after the last round.
      await store.resumeGaveUp(e.streamId, 1, force: true);
      expect(
        store.entryFor(e.streamId)!.state,
        ReceivedImageState.failedIncomplete,
      );
    });

    test('a regular AI sketch is not offered "ask for the rest"', () {
      final e = ReceivedImageEntry(
        streamId: 'x',
        senderPrefix: 1,
        imgId: 2,
        channelIndex: 0,
        firstSeen: DateTime(2026),
        state: ReceivedImageState.failedIncomplete,
        receivedChunks: 1,
        totalChunks: 2,
        rate: AeicRatePoint.ft32,
        metadataAssumed: false,
      );
      expect(aeicHdResumable(e), isFalse);
      expect(aeicHdResumable(e.copyWith(rate: AeicRatePoint.ft2)), isTrue);
    });
  });
}
