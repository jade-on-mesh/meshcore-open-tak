// MeshCore Open TAK - a #hashtag typed in a chat, tapped: open that hashtag
// channel, or add it to the radio first (its key comes from its name, as
// Channels > Add > hashtag does). Wadamesh TAK standalones do the same.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_linkify/flutter_linkify.dart';
import 'package:provider/provider.dart';

import '../connector/meshcore_connector.dart';
import '../helpers/snack_bar_builder.dart';
import '../l10n/l10n.dart';
import '../models/channel.dart';
import '../screens/channel_chat_screen.dart';
import '../utils/radio_guard.dart';

/// The link a hashtag in a message becomes (HashtagLinkifier).
const String hashtagLinkScheme = 'meshcore-hashtag:';

/// A hashtag in a message: "#" and 1-31 letters, digits, "_" or "-", with a
/// letter among them ("#40" stays text), not part of a word, a URL ("/#x")
/// or another hashtag. 31 so "#" and the name fit a channel name's 32 bytes.
final RegExp hashtagInText = RegExp(
  r'(?<![\w#/&@])#(?=[A-Za-z0-9_-]*[A-Za-z])[A-Za-z0-9_-]{1,31}(?![\w#-])',
);

/// The channel name a typed hashtag stands for: lowercase, as hashtag
/// channels are named, so "#MediaMesh" finds the #mediamesh everyone uses.
String hashtagChannelName(String tag) =>
    '#${(tag.startsWith('#') ? tag.substring(1) : tag).toLowerCase()}';

/// Makes hashtags in message text tappable (after URLs, so a URL's "#part"
/// stays part of the URL).
class HashtagLinkifier extends Linkifier {
  const HashtagLinkifier();

  @override
  List<LinkifyElement> parse(
    List<LinkifyElement> elements,
    LinkifyOptions options,
  ) {
    final out = <LinkifyElement>[];
    for (final e in elements) {
      if (e is! TextElement) {
        out.add(e);
        continue;
      }
      var last = 0;
      for (final m in hashtagInText.allMatches(e.text)) {
        if (m.start > last)
          out.add(TextElement(e.text.substring(last, m.start)));
        final tag = m[0]!;
        out.add(LinkableElement(tag, '$hashtagLinkScheme${tag.substring(1)}'));
        last = m.end;
      }
      if (last < e.text.length) out.add(TextElement(e.text.substring(last)));
    }
    return out;
  }
}

/// [tag] tapped in a message: the channel if the radio has it (by name or
/// key), else asks, adds it in the first free slot and opens it.
Future<void> openOrJoinHashtagChannel(BuildContext context, String tag) async {
  final connector = context.read<MeshCoreConnector>();
  final l10n = context.l10n;
  final name = hashtagChannelName(tag);
  final psk = Channel.derivePskFromHashtag(name);
  Channel? find() {
    for (final c in connector.channels) {
      if (c.isEmpty) continue;
      if (c.name.toLowerCase() == name || listEquals(c.psk, psk)) return c;
    }
    return null;
  }

  void open(Channel c) => Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => ChannelChatScreen(channel: c)),
  );

  final have = find();
  if (have != null) {
    open(have);
    return;
  }
  final ok = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(l10n.chat_hashtagJoinTitle(name)),
      content: Text(l10n.chat_hashtagJoinBody),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: Text(l10n.common_cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: Text(l10n.chat_hashtagJoin),
        ),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;
  if (!ensureRadioConnected(context)) return;
  final slot = await connector.freeChannelSlotWhenKnown();
  if (!context.mounted) return;
  if (slot == null) {
    showDismissibleSnackBar(context, content: Text(l10n.channels_noFreeSlots));
    return;
  }
  await connector.setChannel(slot, name, psk);
  if (!context.mounted) return;
  showDismissibleSnackBar(
    context,
    content: Text(l10n.chat_hashtagJoined(name)),
  );
  // The radio's channel list catches up shortly after: open it when it does.
  for (var i = 0; i < 25; i++) {
    final c = find();
    if (c != null) {
      if (context.mounted) open(c);
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
    if (!context.mounted) return;
  }
}
