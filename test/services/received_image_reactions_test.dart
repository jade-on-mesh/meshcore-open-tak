import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/helpers/reaction_helper.dart';
import 'package:meshcore_open/models/image_codec_support.dart';
import 'package:meshcore_open/services/received_image_store.dart';

void main() {
  Future<ReceivedImageEntry> add(
    ReceivedImageStore store, {
    int senderPrefix = 0xab12,
    int imgId = 7,
    DateTime? at,
  }) => store.registerOutgoing(
    channelIndex: 1,
    senderPrefix: senderPrefix,
    imgId: imgId,
    previewPng: Uint8List.fromList(List<int>.filled(16, 1)),
    rate: AeicRatePoint.ft32,
    chunkCount: 2,
    at: at,
  );

  ReactionInfo reaction(String hash, {String emoji = '👍', String? who}) =>
      ReactionInfo(
        targetHash: hash,
        emoji: emoji,
        hashType: HashType.ours,
        senderName: who,
      );

  test('the hash depends on sender and image id only', () {
    final h = ReactionHelper.imageReactionHash(0xab12, 7);
    expect(h, hasLength(4));
    expect(ReactionHelper.imageReactionHash(0xab12, 7), h);
    expect(ReactionHelper.imageReactionHash(0xab12, 8), isNot(h));
    expect(ReactionHelper.imageReactionHash(0xab13, 7), isNot(h));
  });

  test('a reaction lands on the image it names and survives JSON', () async {
    final store = ReceivedImageStore(decoder: null);
    final e = await add(store);
    expect(store.applyReaction(reaction(e.reactionHash, who: 'Ann')), isTrue);
    expect(
      store.applyReaction(reaction(e.reactionHash, emoji: '❤️', who: 'Bo')),
      isTrue,
    );
    expect(store.applyReaction(reaction(e.reactionHash, who: 'Cy')), isTrue);
    final got = store.entryFor(e.streamId)!;
    expect(got.reactions, {
      '👍': ['Ann', 'Cy'],
      '❤️': ['Bo'],
    });
    final back = ReceivedImageEntry.fromJson(got.toJson());
    expect(back.reactions, got.reactions);
  });

  test('a reaction naming no image is left alone', () async {
    final store = ReceivedImageStore(decoder: null);
    final e = await add(store);
    final other = ReactionHelper.imageReactionHash(0xab12, 8);
    expect(store.applyReaction(reaction(other)), isFalse);
    expect(store.entryFor(e.streamId)!.reactions, isEmpty);
  });

  test('a reused image id goes to the newest image', () async {
    final store = ReceivedImageStore(decoder: null);
    final old = await add(store, at: DateTime(2026, 1, 1));
    final fresh = await add(store, at: DateTime(2026, 1, 2));
    expect(store.applyReaction(reaction(fresh.reactionHash)), isTrue);
    expect(store.entryFor(fresh.streamId)!.reactions, isNotEmpty);
    expect(store.entryFor(old.streamId)!.reactions, isEmpty);
  });
}
