// MeshCore Open TAK - AI sketch HD: sender names and "ask for the rest".
//
// AI sketch HD images travel as MeshCore Open's AEIC channel image chunks
// (image_chunk_transport.dart), which are pushed once and carry only a 2-byte
// sender key prefix. Two small Open TAK packets, on their own GRP_DATA data
// type so nothing else reads them, add what they lack:
//
//   'N' announce  [0x4E][prefix:2][imgId][name utf-8, up to 32 bytes]
//       sent by the sender just before an HD image's chunks: receivers show
//       the name instead of "Node 8c41".
//   'Q' request   [0x51][prefix:2][imgId][total][missing:2][salt]
//       sent by a receiver whose copy is incomplete: `missing` has bit i set
//       for each data chunk i it lacks, bit 15 for the parity chunk.
//   0xC_ chunk    [0xC0 | salt:4][an image chunk, as sent the first time]
//       an answer: one data chunk, wrapped.
//
// GRP_DATA carries no timestamp, so two sends of the same bytes are the same
// packet to MeshCore, and every radio that saw the first (companions and
// repeaters alike) drops the second as already seen. A request repeated for
// the same chunks, and a chunk sent again exactly as before, never arrived.
// The random salt makes each one new. An image chunk has no room for one, so
// answers go wrapped in this data type (a data chunk is at most 162 bytes:
// with the wrap byte, still within a packet) and the parity chunk, which
// can't be wrapped, isn't resent: with every data chunk back it isn't needed.
//
// Anyone holding the whole image answers a request with just those chunks:
// the sender at once, others after a few seconds and only with what nobody
// sent meanwhile. Requests, announces and answers all go on MediaMesh
// (radio2), like the HD image itself. Only AI sketch HD (the ft2 rate point)
// is answered: the regular AI sketch is MeshCore Open's own and is left as it
// is. The receiver keeps the chunks it had (ImageReassembler parks them), so
// the answer completes the image rather than starting it over.

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../connector/meshcore_connector.dart';
import '../models/image_codec_support.dart';
import '../services/image_chunk_transport.dart';
import '../services/media_mesh.dart';
import '../services/received_image_store.dart';
import '../utils/app_logger.dart';

void _log(String m) => appLogger.info(m, tag: 'AI sketch HD');

/// GRP_DATA data type of the packets above ('AEIC', one past the images').
const int dataTypeAeicHdRepair = 0xAE1D;

const int _kAnnounce = 0x4E; // 'N'
const int _kRequest = 0x51; // 'Q'
const int _kMaxNameBytes = 32;
const int _kParityBit = 1 << 15;
const int _kWrapMask = 0xF0;
const int _kWrap = 0xC0;
final Random _saltRng = Random();

Uint8List encodeAeicHdAnnounce(int senderPrefix, int imgId, String name) {
  var bytes = utf8.encode(name.trim());
  if (bytes.length > _kMaxNameBytes) {
    // Cut on a character boundary.
    var cut = _kMaxNameBytes;
    while (cut > 0 && (bytes[cut] & 0xC0) == 0x80) {
      cut--;
    }
    bytes = bytes.sublist(0, cut);
  }
  return Uint8List.fromList([
    _kAnnounce,
    (senderPrefix >> 8) & 0xFF,
    senderPrefix & 0xFF,
    imgId & 0xFF,
    ...bytes,
  ]);
}

Uint8List encodeAeicHdRequest({
  required int senderPrefix,
  required int imgId,
  required int total,
  required int missingMask,
}) => Uint8List.fromList([
  _kRequest,
  (senderPrefix >> 8) & 0xFF,
  senderPrefix & 0xFF,
  imgId & 0xFF,
  total & 0x0F,
  (missingMask >> 8) & 0xFF,
  missingMask & 0xFF,
  _saltRng.nextInt(256),
]);

/// One image chunk wrapped for an answer, with a fresh salt.
Uint8List wrapAeicHdChunk(Uint8List blob) =>
    Uint8List.fromList([_kWrap | _saltRng.nextInt(16), ...blob]);

/// The image chunk inside an answer, or null when [p] isn't one.
Uint8List? unwrapAeicHdChunk(Uint8List p) =>
    p.length > 1 && (p[0] & _kWrapMask) == _kWrap
    ? Uint8List.sublistView(p, 1)
    : null;

/// One decoded packet: an announce has [name], a request [total] and [mask].
class AeicHdRepairPacket {
  final bool isRequest;
  final int senderPrefix;
  final int imgId;
  final String? name;
  final int total;
  final int mask;
  const AeicHdRepairPacket({
    required this.isRequest,
    required this.senderPrefix,
    required this.imgId,
    this.name,
    this.total = 0,
    this.mask = 0,
  });

  static AeicHdRepairPacket? tryParse(Uint8List p) {
    if (p.length < 4) return null;
    final prefix = (p[1] << 8) | p[2];
    if (p[0] == _kAnnounce) {
      if (p.length == 4 || p.length > 4 + _kMaxNameBytes) return null;
      final name = utf8.decode(p.sublist(4), allowMalformed: true).trim();
      if (name.isEmpty) return null;
      return AeicHdRepairPacket(
        isRequest: false,
        senderPrefix: prefix,
        imgId: p[3],
        name: name,
      );
    }
    // 7 bytes: before the salt (still accepted).
    if (p[0] == _kRequest && (p.length == 7 || p.length == 8)) {
      final total = p[4] & 0x0F;
      if (total == 0) return null;
      return AeicHdRepairPacket(
        isRequest: true,
        senderPrefix: prefix,
        imgId: p[3],
        total: total,
        mask: (p[5] << 8) | p[6],
      );
    }
    return null;
  }
}

/// The chunks a request asks for, from the whole image's [blobs] (data
/// chunks in order, then parity): bit i data chunk i, bit 15 the parity.
List<Uint8List> aeicHdBlobsFor(List<Uint8List> blobs, int total, int mask) => [
  for (var i = 0; i < total && i < blobs.length; i++)
    if (mask & (1 << i) != 0) blobs[i],
];

/// Whether [entry] can be asked for the rest: an incomplete AI sketch HD, or
/// one whose first chunk (which names the kind) never came.
bool aeicHdResumable(ReceivedImageEntry entry) =>
    !entry.isOutgoing &&
    entry.state == ReceivedImageState.failedIncomplete &&
    (entry.metadataAssumed || entry.rate == AeicRatePoint.ft2);

class AeicHdRepairService {
  final MeshCoreConnector connector;
  final ReceivedImageStore store;
  final ImageReassembler reassembler;
  final Random _rng = Random();
  StreamSubscription<Uint8List>? _sub;

  /// Image chunks heard lately, by (channel, prefix, imgId, index), so a
  /// holder that isn't the sender leaves out what someone else just sent.
  final Map<String, DateTime> _heard = <String, DateTime>{};

  /// Requests answered lately, so a burst of the same request is served once.
  final Map<String, DateTime> _served = <String, DateTime>{};

  /// How long a resumed image waits for an answer before it is incomplete
  /// again.
  static const Duration answerWait = Duration(seconds: 45);

  AeicHdRepairService({
    required this.connector,
    required this.store,
    required this.reassembler,
  }) {
    _sub = connector.receivedFrames.listen(_onFrame);
  }

  void dispose() => _sub?.cancel();

  static String _chunkKey(int ch, int prefix, int imgId, int index) =>
      '$ch:$prefix:$imgId:$index';

  void _onFrame(Uint8List frame) {
    final parsed = parseChannelDataFrame(frame);
    if (parsed == null) return;
    if (parsed.dataType == dataTypeAeicImage) {
      final h = parseImageChunkHeader(parsed.payload);
      if (h != null) {
        _heard[_chunkKey(
              parsed.channelIndex,
              h.senderPrefix,
              h.imgId,
              h.index,
            )] =
            DateTime.now();
        if (_heard.length > 256) _heard.remove(_heard.keys.first);
      }
      return;
    }
    if (parsed.dataType != dataTypeAeicHdRepair) return;
    final chunk = unwrapAeicHdChunk(parsed.payload);
    if (chunk != null) {
      // An answer: the chunk goes in as if it had come the first time.
      final h = parseImageChunkHeader(chunk);
      if (h != null) {
        _heard[_chunkKey(
              parsed.channelIndex,
              h.senderPrefix,
              h.imgId,
              h.index,
            )] =
            DateTime.now();
      }
      _log(
        'got chunk ${h?.index ?? '?'} of '
        '${h == null ? '?' : '${h.senderPrefix.toRadixString(16).padLeft(4, '0')}/${h.imgId}'} '
        'on slot ${parsed.channelIndex}',
      );
      reassembler.addChunk(
        chunk,
        channelIndex: parsed.channelIndex,
        via: parsed.via,
      );
      return;
    }
    final p = AeicHdRepairPacket.tryParse(parsed.payload);
    if (p == null) return;
    if (p.isRequest) {
      _log(
        'request heard for '
        '${p.senderPrefix.toRadixString(16).padLeft(4, '0')}/${p.imgId} '
        'on slot ${parsed.channelIndex}: mask 0x${p.mask.toRadixString(16)}',
      );
    }
    if (!p.isRequest) {
      store.noteSenderName(p.senderPrefix, p.imgId, p.name!);
      return;
    }
    unawaited(_answer(parsed.channelIndex, p));
  }

  /// Sends the sender's name for an HD image about to go out on [slot].
  /// Call inside the image's radio2 hold.
  Future<void> announce(int slot, int senderPrefix, int imgId) async {
    final name = connector.selfName;
    if (name == null || name.trim().isEmpty) return;
    try {
      await connector.sendChannelDataPacket(
        channelIndex: slot,
        dataType: dataTypeAeicHdRepair,
        payload: encodeAeicHdAnnounce(senderPrefix, imgId, name),
      );
    } catch (e) {
      debugPrint('AI sketch HD announce failed: $e');
    }
  }

  /// "Ask for the rest" of [entry]: on radio2, for the chunks this phone
  /// lacks (all of them when it kept none). Returns false when radio2 can't
  /// take the request.
  Future<bool> requestRest(ReceivedImageEntry entry) async {
    final key = entry.key;
    final total = entry.totalChunks.clamp(1, 15).toInt();
    final missing = reassembler.missingDataChunks(key);
    var mask = 0;
    if (missing == null) {
      mask = (1 << total) - 1;
    } else {
      for (final i in missing) {
        mask |= 1 << i;
      }
    }
    // The parity chunk isn't resent (see the top): not asked for.
    reassembler.expectResend(key);
    final release = await MediaMeshChannelHold.hold(
      connector,
      entry.channelIndex,
    );
    if (release == null) {
      _log('ask for the rest: radio2 can\'t send');
      return false;
    }
    _log(
      'asking for the rest of '
      '${entry.senderPrefix.toRadixString(16).padLeft(4, '0')}/${entry.imgId} '
      'on slot ${entry.channelIndex}: mask '
      '0x${mask.toRadixString(16)} of ${entry.totalChunks}',
    );
    try {
      final resumed = await store.resumeReceiving(entry.streamId);
      await connector.sendChannelDataPacket(
        channelIndex: entry.channelIndex,
        dataType: dataTypeAeicHdRepair,
        payload: encodeAeicHdRequest(
          senderPrefix: entry.senderPrefix,
          imgId: entry.imgId,
          total: total,
          missingMask: mask,
        ),
      );
      final at = resumed?.receivedChunks ?? entry.receivedChunks;
      Timer(
        answerWait,
        () => unawaited(store.resumeGaveUp(entry.streamId, at)),
      );
      return true;
    } finally {
      await release();
    }
  }

  /// The whole HD image a request on [slot] names, if this phone holds it.
  /// Matched by sender and image id, and by the channel's ID rather than its
  /// radio slot: two phones seldom keep a channel in the same slot, so the
  /// sender's own copy, keyed by its slot, didn't match the asker's.
  ReceivedImageEntry? _heldFor(int slot, AeicHdRepairPacket q) {
    final channelId = connector.channelIdForSlot(slot);
    ReceivedImageEntry? any;
    for (final e in store.entries) {
      if (e.senderPrefix != q.senderPrefix || e.imgId != q.imgId) continue;
      if (e.rate != AeicRatePoint.ft2 || !e.bitstreamStored) continue;
      if (e.totalChunks != q.total) continue;
      if (channelId != null && e.channelId == channelId) return e;
      if (e.channelId == null || channelId == null) any ??= e;
    }
    return any;
  }

  Future<void> _answer(int slot, AeicHdRepairPacket q) async {
    final tag =
        '${q.senderPrefix.toRadixString(16).padLeft(4, '0')}/${q.imgId}';
    final entry = _heldFor(slot, q);
    if (entry == null) {
      _log('request for $tag on slot $slot: not held here');
      return;
    }
    final servedKey = '$slot:${q.senderPrefix}:${q.imgId}:${q.mask}';
    final last = _served[servedKey];
    final now = DateTime.now();
    if (last != null && now.difference(last) < const Duration(seconds: 20)) {
      _log('request for $tag: answered under 20 s ago');
      return;
    }
    _served[servedKey] = now;
    if (_served.length > 32) _served.remove(_served.keys.first);

    // The sender answers at once; anyone else waits and leaves out what the
    // sender (or another holder) sends meanwhile.
    final asked = DateTime.now();
    await Future<void>.delayed(
      Duration(
        milliseconds: entry.isOutgoing
            ? 300 + _rng.nextInt(500)
            : 2500 + _rng.nextInt(2500),
      ),
    );
    final bits = await store.blobs.readBitstream(entry.streamId);
    if (bits == null) {
      _log('request for $tag: its bytes are gone');
      return;
    }
    final ImageChunkSet set;
    try {
      set = buildImageChunks(
        payload: bits,
        metadata: ImageStreamMetadata(
          rate: uiRatePointForAeic(entry.rate),
          squareSize: entry.resolution,
          aspectCode: entry.aspectCode,
        ),
        senderPrefix: entry.senderPrefix,
        imgId: entry.imgId,
      );
    } on ArgumentError {
      _log('request for $tag: could not rebuild its chunks');
      return;
    }
    if (set.dataChunkCount != q.total) {
      _log(
        'request for $tag: ${set.dataChunkCount} chunks, asked for ${q.total}',
      );
      return;
    }
    var mask = q.mask;
    if (!entry.isOutgoing) {
      for (var i = 0; i <= q.total; i++) {
        final bit = i == q.total ? _kParityBit : 1 << i;
        final heard = _heard[_chunkKey(slot, q.senderPrefix, q.imgId, i)];
        if (heard != null && heard.isAfter(asked)) mask &= ~bit;
      }
    }
    final blobs = aeicHdBlobsFor(set.blobs, q.total, mask);
    if (blobs.isEmpty) {
      _log('request for $tag: others already sent them');
      return;
    }
    final release = await MediaMeshChannelHold.hold(connector, slot);
    if (release == null) {
      _log('request for $tag: radio2 can\'t send, not answered');
      return;
    }
    _log('answering $tag on slot $slot: ${blobs.length} chunk(s)');
    try {
      await connector.sendChannelDataBlobs(
        [for (final b in blobs) wrapAeicHdChunk(b)],
        channelIndex: slot,
        dataType: dataTypeAeicHdRepair,
        interChunkDelay: const Duration(milliseconds: 600),
      );
    } finally {
      await release();
    }
  }
}
