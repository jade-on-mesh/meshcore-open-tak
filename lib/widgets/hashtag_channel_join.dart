// MeshCore Open TAK - a #hashtag typed in a chat, tapped: open that hashtag
// channel, or add it to the radio first (its key comes from its name, as
// Channels > Add > hashtag does). Wadamesh TAK standalones do the same.

import 'dart:convert';

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

/// A word character in a hashtag, as Wadamesh TAK's ChatHashtag.h counts
/// them: ASCII letters, digits, "-" and "_", Latin letters with accents
/// (U+00C0-U+02AF but not × or ÷, U+1E00-U+1EFF) and combining accents.
bool _hashtagWordRune(int c) {
  if (c < 0x80) {
    return (c >= 0x30 && c <= 0x39) ||
        (c >= 0x41 && c <= 0x5A) ||
        (c >= 0x61 && c <= 0x7A) ||
        c == 0x2D ||
        c == 0x5F;
  }
  final latin =
      (c >= 0x00C0 && c <= 0x02AF && c != 0x00D7 && c != 0x00F7) ||
      (c >= 0x1E00 && c <= 0x1EFF);
  return latin || (c >= 0x0300 && c <= 0x036F);
}

bool _isHex(int c) =>
    (c >= 0x30 && c <= 0x39) ||
    (c >= 0x41 && c <= 0x46) ||
    (c >= 0x61 && c <= 0x66);

/// "FF8800", "1a2b3c4d": a colour code, not a hashtag (ChatHashtag::isHexColor).
bool _isHexColor(List<int> r) {
  if (r.length != 6 && r.length != 8) return false;
  var colorLike = false;
  var titleCaseHex = r[0] >= 0x41 && r[0] <= 0x46;
  for (var i = 0; i < r.length; i++) {
    final c = r[i];
    if (!_isHex(c)) return false;
    final upper = c >= 0x41 && c <= 0x46;
    if (i > 0 && upper) titleCaseHex = false;
    if ((c >= 0x30 && c <= 0x39) || upper) colorLike = true;
  }
  return colorLike && !titleCaseHex;
}

/// The hashtags in [text], as (start, end) UTF-16 offsets including the "#".
/// The same rules as Wadamesh TAK (src/ui-touch/ChatHashtag.h), so a phone
/// and a standalone make the same words tappable: "#" not inside a word, a
/// URL ("/#x") or another hashtag; the name of word characters, trailing "-"
/// and "_" dropped, under 32 bytes with the "#", not starting with a digit
/// ("#40"), "-" or "_", and not a colour code; "@[name]" mentions skipped.
List<(int, int)> hashtagSpans(String text) {
  final runes = text.runes.toList();
  final at = <int>[]; // UTF-16 offset of each rune, plus the end
  var o = 0;
  for (final r in runes) {
    at.add(o);
    o += r > 0xFFFF ? 2 : 1;
  }
  at.add(o);
  final out = <(int, int)>[];
  for (var i = 0; i < runes.length; i++) {
    if (runes[i] == 0x40 && i + 1 < runes.length && runes[i + 1] == 0x5B) {
      final close = runes.indexOf(0x5D, i + 2);
      if (close < 0) break;
      i = close;
      continue;
    }
    if (runes[i] != 0x23) continue;
    if (i > 0) {
      final p = runes[i - 1];
      if ((p != 0x2D && _hashtagWordRune(p)) || p == 0x2F || p == 0x23) {
        continue;
      }
    }
    var end = i + 1;
    while (end < runes.length && _hashtagWordRune(runes[end])) {
      end++;
    }
    while (end > i + 1 && (runes[end - 1] == 0x2D || runes[end - 1] == 0x5F)) {
      end--;
    }
    if (end < runes.length && runes[end] >= 0x80) {
      i = end;
      continue;
    }
    final name = runes.sublist(i + 1, end);
    if (name.isEmpty) continue;
    final bytes = utf8.encode(String.fromCharCodes(name)).length + 1;
    final first = name[0];
    final startsWithDigit = first >= 0x30 && first <= 0x39;
    final nonHexLetter = name.any(
      (c) => ((c >= 0x67 && c <= 0x7A) || (c >= 0x47 && c <= 0x5A)),
    );
    final malformedSixDigitHex = bytes == 7 && nonHexLetter;
    if (bytes >= 32 ||
        (startsWithDigit && !malformedSixDigitHex) ||
        first == 0x5F ||
        first == 0x2D ||
        _isHexColor(name)) {
      continue;
    }
    out.add((at[i], at[end]));
    i = end - 1;
  }
  return out;
}

/// The channel name a typed hashtag stands for, as Wadamesh derives it
/// (deriveHashtagChannelKey): leading "#"s and spaces dropped, A-Z lowercased
/// and nothing else, so "#MediaMesh" finds the #mediamesh everyone uses and
/// both make the same key from "#Café".
String hashtagChannelName(String tag) {
  final b = StringBuffer('#');
  var i = 0;
  while (i < tag.length && tag.codeUnitAt(i) == 0x23) {
    i++;
  }
  for (; i < tag.length; i++) {
    final c = tag.codeUnitAt(i);
    if (c == 0x20 || c == 0x09 || c == 0x0A) continue;
    b.writeCharCode(c >= 0x41 && c <= 0x5A ? c + 32 : c);
  }
  return b.length == 1 ? '#public' : b.toString();
}

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
      for (final (start, end) in hashtagSpans(e.text)) {
        if (start > last) out.add(TextElement(e.text.substring(last, start)));
        final tag = e.text.substring(start, end);
        out.add(LinkableElement(tag, '$hashtagLinkScheme${tag.substring(1)}'));
        last = end;
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
