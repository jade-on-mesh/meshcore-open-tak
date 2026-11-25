import 'reaction_helper.dart';

/// How long after sending a message can still be edited.
const Duration messageEditWindow = Duration(minutes: 15);

/// How late a received edit may arrive after the message it changes, by the
/// sender's clock: the edit window plus slack for queued delivery.
const Duration messageEditAcceptWindow = Duration(minutes: 20);

/// Why an edit can't be sent.
enum EditRefusal {
  /// The text is the same as before, or empty.
  unchanged,

  /// The change doesn't fit in one message.
  tooLong,
}

/// A correction to a sent message: only the changed words travel.
///
/// On the wire it is two lines. The first is readable, so apps that don't
/// know edits show a sensible correction; the second says where it goes:
///
/// ```
/// ✎ …see you at 6
/// e:3fa1:7c:14:5
/// ```
///
/// `3fa1` is the target message's reaction hash (timestamp, sender and the
/// first five characters of the text it was first sent with), `7c` checks the
/// text the edit applies to, and `14:5` replaces 5 UTF-16 units at offset 14
/// with the words on the first line. `…` marks text left out before or after
/// those words; it is not part of the replacement.
class MessageEdit {
  static const String mark = '✎ ';
  static const String ellipsis = '…';
  static final RegExp _tag = RegExp(
    r'^e:([0-9a-f]{4}):([0-9a-f]{2}):(\d{1,4}):(\d{1,4})$',
  );

  final String targetHash;
  final String baseCheck;
  final int offset;
  final int deleteLength;
  final String replacement;

  const MessageEdit({
    required this.targetHash,
    required this.baseCheck,
    required this.offset,
    required this.deleteLength,
    required this.replacement,
  });

  /// Two hex characters that tell whether [base] is the text an edit was
  /// made against, so an edit is never applied to the wrong version.
  static String checkOf(String base) =>
      (ReactionHelper.stableStringHash(base) & 0xFF)
          .toRadixString(16)
          .padLeft(2, '0');

  /// The edit turning [before] into [after], or null when they are the same
  /// or [after] is empty. [targetHash] identifies the message.
  ///
  /// The replacement is widened to whole words so it reads on its own.
  static MessageEdit? between({
    required String targetHash,
    required String before,
    required String after,
  }) {
    if (before == after || after.trim().isEmpty) return null;
    var start = 0;
    final maxPrefix = before.length < after.length
        ? before.length
        : after.length;
    while (start < maxPrefix &&
        before.codeUnitAt(start) == after.codeUnitAt(start)) {
      start++;
    }
    var suffix = 0;
    while (suffix < before.length - start &&
        suffix < after.length - start &&
        before.codeUnitAt(before.length - 1 - suffix) ==
            after.codeUnitAt(after.length - 1 - suffix)) {
      suffix++;
    }
    // Widen to word boundaries. The text before [start] and the last
    // [suffix] units are the same in both, so one walk suits both.
    while (start > 0 && !_isSpace(before.codeUnitAt(start - 1))) {
      start--;
    }
    while (suffix > 0 && !_isSpace(before.codeUnitAt(before.length - suffix))) {
      suffix--;
    }
    // Then one more word each side, so an app without edits shows the change
    // in context: "…at 6 tonight" rather than "…6…".
    while (start > 0 && _isSpace(before.codeUnitAt(start - 1))) {
      start--;
    }
    while (start > 0 && !_isSpace(before.codeUnitAt(start - 1))) {
      start--;
    }
    while (suffix > 0 && _isSpace(before.codeUnitAt(before.length - suffix))) {
      suffix--;
    }
    while (suffix > 0 && !_isSpace(before.codeUnitAt(before.length - suffix))) {
      suffix--;
    }
    return MessageEdit(
      targetHash: targetHash,
      baseCheck: checkOf(before),
      offset: start,
      deleteLength: before.length - suffix - start,
      replacement: after.substring(start, after.length - suffix),
    );
  }

  static bool _isSpace(int unit) =>
      unit == 0x20 || unit == 0x0A || unit == 0x09 || unit == 0x0D;

  /// The wire text. [baseLength] is the length of the text it applies to,
  /// which decides whether a trailing `…` is shown.
  String encode(int baseLength) {
    final before = offset > 0 ? ellipsis : '';
    final after = offset + deleteLength < baseLength ? ellipsis : '';
    return '$mark$before$replacement$after\n'
        'e:$targetHash:$baseCheck:$offset:$deleteLength';
  }

  /// Reads an edit's wire text, or null when [text] isn't one. The
  /// replacement keeps any `…`; [applyTo] removes it.
  static MessageEdit? parse(String text) {
    if (!text.startsWith(mark)) return null;
    final newline = text.lastIndexOf('\n');
    if (newline < 0) return null;
    final m = _tag.firstMatch(text.substring(newline + 1));
    if (m == null) return null;
    return MessageEdit(
      targetHash: m.group(1)!,
      baseCheck: m.group(2)!,
      offset: int.parse(m.group(3)!),
      deleteLength: int.parse(m.group(4)!),
      replacement: text.substring(mark.length, newline),
    );
  }

  /// Whether [text] looks like an edit, for callers that only need to know.
  static bool looks(String text) => parse(text) != null;

  /// [base] with this edit applied, or null when the edit was made against
  /// other text (a missed earlier edit) or doesn't fit.
  String? applyTo(String base) {
    if (checkOf(base) != baseCheck) return null;
    final end = offset + deleteLength;
    if (end > base.length) return null;
    var words = replacement;
    if (offset > 0) {
      if (!words.startsWith(ellipsis)) return null;
      words = words.substring(ellipsis.length);
    }
    if (end < base.length) {
      if (!words.endsWith(ellipsis)) return null;
      words = words.substring(0, words.length - ellipsis.length);
    }
    final result = base.replaceRange(offset, end, words);
    return result.trim().isEmpty ? null : result;
  }

  /// Whether [current] already reads as this edit made it: a repeat of an
  /// edit that was applied.
  bool alreadyIn(String current) {
    var words = replacement;
    if (offset > 0 && words.startsWith(ellipsis)) {
      words = words.substring(ellipsis.length);
    }
    if (words.endsWith(ellipsis)) {
      words = words.substring(0, words.length - ellipsis.length);
    }
    if (offset > current.length) return false;
    return current.startsWith(words, offset);
  }

  /// Dedupe key: one sender's one edit.
  String identifier(String? senderName) =>
      '$targetHash:$baseCheck:$offset:$deleteLength:'
      '${replacement.hashCode}:${senderName ?? ''}';
}
