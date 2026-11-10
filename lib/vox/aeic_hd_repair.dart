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
  int copiesAfter = 0,
}) => Uint8List.fromList([
  _kRequest,
  (senderPrefix >> 8) & 0xFF,
  senderPrefix & 0xFF,
  imgId & 0xFF,
  total & 0x0F,
  (missingMask >> 8) & 0xFF,
  missingMask & 0xFF,
  // Top two bits: how many more copies of this request follow, so the
  // holder can wait them out instead of answering over them. The rest: salt.
  ((copiesAfter.clamp(0, 3)) << 6) | _saltRng.nextInt(64),
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

  /// For a request: how many more copies of it the asker is still sending.
  final int copiesAfter;
  const AeicHdRepairPacket({
    required this.isRequest,
    required this.senderPrefix,
    required this.imgId,
    this.name,
    this.total = 0,
    this.mask = 0,
    this.copiesAfter = 0,
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
        copiesAfter: p.length == 8 ? p[7] >> 6 : 0,
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
/// A partial image's chunks as saved to disk:
/// `[0x50][1][total][hasParity][n]`, then n × `[index][len:2][body]`, then
/// `[len:2][parity body]` when there is one.
Uint8List encodeAeicHdPartial({
  required int total,
  required Map<int, Uint8List> bodies,
  Uint8List? parity,
}) {
  final b = BytesBuilder(copy: false)
    ..add([0x50, 1, total & 0xFF, parity == null ? 0 : 1, bodies.length]);
  final keys = bodies.keys.toList()..sort();
  for (final i in keys) {
    final body = bodies[i]!;
    b.add([i & 0xFF, (body.length >> 8) & 0xFF, body.length & 0xFF]);
    b.add(body);
  }
  if (parity != null) {
    b.add([(parity.length >> 8) & 0xFF, parity.length & 0xFF]);
    b.add(parity);
  }
  return b.toBytes();
}

/// [encodeAeicHdPartial] read back; null when [p] isn't one.
({int total, Map<int, Uint8List> bodies, Uint8List? parity})?
decodeAeicHdPartial(Uint8List p) {
  if (p.length < 5 || p[0] != 0x50 || p[1] != 1) return null;
  final total = p[2];
  final hasParity = p[3] == 1;
  final n = p[4];
  var o = 5;
  final bodies = <int, Uint8List>{};
  for (var k = 0; k < n; k++) {
    if (o + 3 > p.length) return null;
    final i = p[o];
    final len = (p[o + 1] << 8) | p[o + 2];
    o += 3;
    if (o + len > p.length || i >= total) return null;
    bodies[i] = Uint8List.fromList(p.sublist(o, o + len));
    o += len;
  }
  Uint8List? parity;
  if (hasParity) {
    if (o + 2 > p.length) return null;
    final len = (p[o] << 8) | p[o + 1];
    o += 2;
    if (o + len > p.length) return null;
    parity = Uint8List.fromList(p.sublist(o, o + len));
  }
  return (total: total, bodies: bodies, parity: parity);
}

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

  /// How many times one "Ask for the rest" sends its request, and how far
  /// apart.
  static const int requestCopies = 3;
  static const Duration requestSpacing = Duration(seconds: 3);

  /// Request rounds per tap: the first, then follow-ups for what's still
  /// missing.
  static const int maxRounds = 3;

  /// Taps per image, so a newer tap's rounds replace an older one's.
  final Map<String, int> _rounds = <String, int>{};

  AeicHdRepairService({
    required this.connector,
    required this.store,
    required this.reassembler,
  }) {
    _sub = connector.receivedFrames.listen(_onFrame);
    store.addListener(_keepPartials);
  }

  void dispose() {
    _sub?.cancel();
    store.removeListener(_keepPartials);
  }

  /// Chunk counts of the partial images saved to disk, by stream.
  final Map<String, int> _savedPartials = <String, int>{};

  /// Saves the chunks of each incomplete HD image, so a restart doesn't lose
  /// them (the reassembler only holds them in memory), and drops the file
  /// once the image is done or gone.
  void _keepPartials() {
    for (final e in store.entries) {
      // Incomplete HD images, and ones receiving a resend after being saved.
      final resending =
          e.state == ReceivedImageState.receiving &&
          _savedPartials.containsKey(e.streamId);
      if (!aeicHdResumable(e) && !resending) continue;
      final held = reassembler.heldChunks(e.key);
      if (held == null) continue;
      final count = held.bodies.length + (held.parity == null ? 0 : 1);
      if (_savedPartials[e.streamId] == count) continue;
      _savedPartials[e.streamId] = count;
      unawaited(
        store.blobs.writePartial(
          e.streamId,
          encodeAeicHdPartial(
            total: held.total,
            bodies: held.bodies,
            parity: held.parity,
          ),
        ),
      );
    }
    for (final id in _savedPartials.keys.toList()) {
      final e = store.entryFor(id);
      if (e != null &&
          (e.state == ReceivedImageState.receiving ||
              e.state == ReceivedImageState.failedIncomplete)) {
        continue;
      }
      _savedPartials.remove(id);
      unawaited(store.blobs.deletePartial(id));
    }
  }

  /// Puts [entry]'s saved chunks back in the reassembler, if it holds none
  /// of them (the app restarted since they came).
  Future<void> _restorePartial(ReceivedImageEntry entry) async {
    if (reassembler.heldChunks(entry.key) != null) return;
    final bytes = await store.blobs.readPartial(entry.streamId);
    if (bytes == null) return;
    final saved = decodeAeicHdPartial(bytes);
    if (saved == null || saved.total != entry.totalChunks) return;
    reassembler.restoreParked(
      entry.key,
      total: saved.total,
      bodies: saved.bodies,
      parity: saved.parity,
    );
    _savedPartials[entry.streamId] =
        saved.bodies.length + (saved.parity == null ? 0 : 1);
    _log('restored ${saved.bodies.length} saved chunk(s) of ${entry.streamId}');
  }

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
  ///
  /// Answers get lost too, so when some chunks are still missing once the
  /// answers have had time to arrive, it asks again for just those, up to
  /// [maxRounds] times in all ([round] counts them).
  Future<bool> requestRest(ReceivedImageEntry entry, {int round = 1}) async {
    final key = entry.key;
    final total = entry.totalChunks.clamp(1, 15).toInt();
    await _restorePartial(entry);
    final missing = reassembler.missingDataChunks(key);
    if (missing != null && missing.isEmpty) return true;
    if (round == 1)
      _rounds[entry.streamId] = (_rounds[entry.streamId] ?? 0) + 1;
    final generation = _rounds[entry.streamId];
    final held = missing == null ? 0 : total - missing.length;
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
      '0x${mask.toRadixString(16)} of ${entry.totalChunks}, '
      'holding $held (round $round of $maxRounds)',
    );
    try {
      final resumed = await store.resumeReceiving(entry.streamId, held: held);
      // A single request is easily missed: the holder's radio only visits
      // radio2 part of the time, and the original image already lost
      // packets on the way. So it goes out [requestCopies] times, a few
      // seconds apart, each with its own salt. The holder answers the first
      // it hears and skips the rest (the 20 s guard in [_answer]).
      for (var copy = 0; copy < requestCopies; copy++) {
        if (copy > 0) await Future<void>.delayed(requestSpacing);
        await connector.sendChannelDataPacket(
          channelIndex: entry.channelIndex,
          dataType: dataTypeAeicHdRepair,
          payload: encodeAeicHdRequest(
            senderPrefix: entry.senderPrefix,
            imgId: entry.imgId,
            total: total,
            missingMask: mask,
            copiesAfter: requestCopies - 1 - copy,
          ),
        );
        _log('request ${copy + 1} of $requestCopies sent');
      }
      final at = resumed?.receivedChunks ?? held;
      Timer(
        answerWait,
        () => unawaited(_afterAnswers(entry.streamId, at, round, generation)),
      );
      return true;
    } finally {
      await release();
    }
  }

  /// Once the answers to round [round] have had their time: done, ask again
  /// for what's still missing, or (after the last round) incomplete again.
  Future<void> _afterAnswers(
    String streamId,
    int receivedAtRequest,
    int round,
    int? generation,
  ) async {
    // A newer tap took over.
    if (_rounds[streamId] != generation) return;
    final e = store.entryFor(streamId);
    if (e == null) return;
    if (e.state != ReceivedImageState.receiving &&
        e.state != ReceivedImageState.failedIncomplete) {
      return;
    }
    final missing = reassembler.missingDataChunks(e.key);
    if (missing != null && missing.isEmpty) return;
    if (round < maxRounds) {
      _log(
        'still missing ${missing ?? 'all'} after round $round: asking again',
      );
      await requestRest(e, round: round + 1);
      return;
    }
    _log('still missing ${missing ?? 'all'} after $maxRounds rounds');
    await store.resumeGaveUp(streamId, receivedAtRequest, force: true);
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

    // First the asker's remaining copies of the request go by (an answer
    // sent over them would be lost: the asker can't hear while it sends).
    // Then the sender answers at once; anyone else waits and leaves out
    // what the sender (or another holder) sends meanwhile.
    final asked = DateTime.now();
    await Future<void>.delayed(
      requestSpacing * q.copiesAfter +
          Duration(
            milliseconds: entry.isOutgoing
                ? 800 + _rng.nextInt(500)
                : 3000 + _rng.nextInt(2500),
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
        mainMeshQuiet: false,
      );
    } finally {
      await release();
    }
  }
}
