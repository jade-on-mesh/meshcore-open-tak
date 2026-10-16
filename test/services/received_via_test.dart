import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/services/image_chunk_transport.dart';
import 'package:meshcore_open/services/received_image_store.dart';
import 'package:meshcore_open/vox/voice_service.dart' show VoxReceivedVia;

/// Wadamesh's MediaMesh puts the radio profile a packet arrived on into a
/// reserved byte of the frames it sends the app: 0xA0 main mesh, 0xA1 radio2.
void main() {
  test('raw data push: byte 3', () {
    Uint8List frame(int tag) =>
        Uint8List.fromList([pushCodeRawData, 20, 0xB0, tag, 1, 2, 3]);
    expect(RawDataPush.tryParse(frame(0xA1))!.via, 1);
    expect(RawDataPush.tryParse(frame(0xA0))!.via, 0);
    expect(RawDataPush.tryParse(frame(0xFF))!.via, isNull); // stock firmware
    expect(RawDataPush.tryParse(frame(0xA1))!.payload, [1, 2, 3]);
  });

  test('channel data: byte 2', () {
    Uint8List frame(int tag) => Uint8List.fromList([
      respCodeChannelDataRecv, 12, tag, 0, // code, snr, via, reserved
      3, 0xFF, 0x43, 0x56, 2, 9, 8, //      idx, path, type, len, data
    ]);
    final r2 = parseChannelDataFrame(frame(0xA1))!;
    expect(r2.via, 1);
    expect(r2.channelIndex, 3);
    expect(r2.dataType, 0x5643);
    expect(r2.payload, [9, 8]);
    expect(parseChannelDataFrame(frame(0xA0))!.via, 0);
    expect(parseChannelDataFrame(frame(0))!.via, isNull); // stock firmware
  });

  test('mask to label', () {
    expect(VoxReceivedVia.fromMask(null), isNull);
    expect(VoxReceivedVia.fromMask(0), isNull);
    expect(VoxReceivedVia.fromMask(1), VoxReceivedVia.mainMesh);
    expect(VoxReceivedVia.fromMask(2), VoxReceivedVia.mediaMesh);
    expect(VoxReceivedVia.fromMask(3), VoxReceivedVia.both);
    // Untagged (stock firmware, or Wadamesh without radio2): one radio, so
    // the main mesh.
    expect(VoxReceivedVia.forReceived(null), VoxReceivedVia.mainMesh);
    expect(VoxReceivedVia.forReceived(0), VoxReceivedVia.mainMesh);
    expect(VoxReceivedVia.forReceived(2), VoxReceivedVia.mediaMesh);
  });

  test('image entries keep the mask across a restart', () {
    final entry = ReceivedImageEntry(
      streamId: 'abcdef01234567',
      senderPrefix: 1,
      imgId: 2,
      channelIndex: 0,
      firstSeen: DateTime.fromMillisecondsSinceEpoch(1000),
      state: ReceivedImageState.reassembled,
      receivedChunks: 3,
      totalChunks: 3,
      viaMask: 2,
    );
    final back = ReceivedImageEntry.fromJson(entry.toJson());
    expect(back.viaMask, 2);
    final old = ReceivedImageEntry.fromJson(
      entry.toJson()..remove('viaMask'),
    );
    expect(old.viaMask, 0);
  });
}
