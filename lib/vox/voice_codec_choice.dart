// MeshCore Open TAK - which codec a chat's voice messages go out in.
//
// Every listener can tell the codecs apart on receive (`VE3:` is Codec2, `VM1:`
// is Mimi), but a radio such as Wadamesh on a T-Deck can only play Codec2. So
// besides the per-chat switch, the app learns from what each chat sends:
//
//   DM       reply in kind: if the contact's latest clip was Codec2, send
//            Codec2 (they may be on a radio that can't run Mimi).
//   channel  if anyone there sent a Codec2 clip in the last two weeks, send
//            Codec2, so everyone on the channel can play it.
//
// The switch overrides either way: on forces Codec2; off while the automatic
// choice says Codec2 is remembered as "Mimi here", so the next Codec2 clip
// doesn't flip it straight back.

import 'dart:convert';

class VoxCodecChoice {
  /// How long a Codec2 clip heard on a channel keeps the channel on Codec2.
  static const Duration channelMemory = Duration(days: 14);

  /// Chats remembered at most (oldest forgotten first).
  static const int maxRemembered = 300;

  final Set<String> _codec2 = {};
  final Set<String> _mimi = {};

  /// target -> (last Codec2 clip, last Mimi clip), ms since epoch.
  final Map<String, (int?, int?)> _heard = {};

  static bool isChannel(String target) => target.startsWith('ch:');

  /// The user switched Codec2 on for this chat.
  bool manualCodec2(String? target) =>
      target != null && _codec2.contains(target);

  /// The user switched Codec2 off while the automatic choice said Codec2.
  bool manualMimi(String? target) => target != null && _mimi.contains(target);

  /// Whether what the chat has sent us says Codec2 (see the file comment).
  bool autoCodec2(String? target, {required DateTime now}) {
    if (target == null) return false;
    final h = _heard[target];
    final c2 = h?.$1;
    if (c2 == null) return false;
    if (isChannel(target)) {
      return now.millisecondsSinceEpoch - c2 < channelMemory.inMilliseconds;
    }
    final mimi = h!.$2;
    return mimi == null || c2 >= mimi;
  }

  /// Whether clips to [target] go out as Codec2.
  bool forcesCodec2(String? target, {required DateTime now}) =>
      target != null &&
      (manualCodec2(target) ||
          (!manualMimi(target) && autoCodec2(target, now: now)));

  /// The per-chat switch. Returns true if anything changed.
  bool setManual(String target, bool codec2, {required DateTime now}) {
    final before = (manualCodec2(target), manualMimi(target));
    if (codec2) {
      _codec2.add(target);
      _mimi.remove(target);
    } else {
      _codec2.remove(target);
      if (autoCodec2(target, now: now)) {
        _mimi.add(target);
      } else {
        _mimi.remove(target);
      }
    }
    return before != (manualCodec2(target), manualMimi(target));
  }

  /// A voice clip arrived from [target]. Returns true if that changed what
  /// [forcesCodec2] says for it.
  bool learn(
    String target, {
    required bool mimi,
    required DateTime at,
    required DateTime now,
  }) {
    final was = forcesCodec2(target, now: now);
    final h = _heard.remove(target); // re-insert: most recent last
    final t = at.millisecondsSinceEpoch;
    int? keep(int? old) => old == null || t > old ? t : old;
    _heard[target] = mimi ? (h?.$1, keep(h?.$2)) : (keep(h?.$1), h?.$2);
    while (_heard.length > maxRemembered) {
      _heard.remove(_heard.keys.first);
    }
    return was != forcesCodec2(target, now: now);
  }

  // ------------------------------------------------------------ persistence

  List<String> get manualCodec2Targets => _codec2.toList();
  List<String> get manualMimiTargets => _mimi.toList();

  String heardJson() => jsonEncode({
    for (final e in _heard.entries) e.key: [e.value.$1, e.value.$2],
  });

  void load({
    List<String>? codec2,
    List<String>? mimi,
    String? heardJson,
  }) {
    _codec2
      ..clear()
      ..addAll(codec2 ?? const []);
    _mimi
      ..clear()
      ..addAll(mimi ?? const []);
    _heard.clear();
    if (heardJson == null || heardJson.isEmpty) return;
    try {
      final m = jsonDecode(heardJson);
      if (m is! Map) return;
      for (final e in m.entries) {
        final v = e.value;
        if (e.key is! String || v is! List || v.length != 2) continue;
        final c2 = v[0], mi = v[1];
        if ((c2 != null && c2 is! int) || (mi != null && mi is! int)) continue;
        _heard[e.key as String] = (c2 as int?, mi as int?);
      }
    } catch (_) {
      // A damaged entry just means relearning from the next clips.
    }
  }
}
