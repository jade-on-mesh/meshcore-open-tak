import 'dart:typed_data';

import '../connector/meshcore_protocol.dart' show hex2Uint8List;

/// Which end of a shared pad this device sends from.
///
/// Only meaningful when [OtpPad.mode] is [OtpPadMode.twoPartyHalfSplit].
/// This is NOT a fixed 50/50 split of the buffer — it mirrors Lua's actual
/// `pdib()`/`pks()` behavior: Party A's own sends consume bytes growing
/// FORWARD from byte 0; Party B's own sends consume bytes growing BACKWARD
/// from the very end of the buffer. The two growing regions are only
/// guaranteed never to overlap because every send is gated on the combined
/// remaining budget (see [OtpPad.myBytesRemaining]) — there's no separate
/// per-party cap at the midpoint the way an earlier version of this class
/// modeled it (that fixed-half version produced different byte ranges than
/// Lua for Party B and silently failed to decrypt against a real Lua peer
/// — see platform-learnings.md, 2026-10-05).
///
/// The two people sharing a pad must agree out of band on who is A and who
/// is B — get this wrong on either end and messages won't decrypt, but
/// nothing is silently reused, so it fails safely rather than dangerously.
enum OtpPadRole {
  a,
  b;

  String get label => this == OtpPadRole.a ? 'A' : 'B';

  static OtpPadRole fromLabel(String value) =>
      value.trim().toUpperCase() == 'B' ? OtpPadRole.b : OtpPadRole.a;
}

/// Deterministic, symmetric Party A/B tie-break shared byte-for-byte with
/// the Lua app's `resolve_dm_role`: whichever side's own public-key hex
/// sorts lexicographically lower (ASCII, lowercased first) is Party A, the
/// other is Party B. Equal keys (should never happen for two distinct
/// devices) default to A.
///
/// Returns `null` — never a guess — when either side's public key isn't
/// available yet (e.g. the radio hasn't reported this device's own key).
/// Callers must fall back to letting the person pick manually rather than
/// defaulting to a role, since a same-role collision on both sides is not
/// detectable by the sync-check (it only catches a pad-length mismatch).
OtpPadRole? resolveDmRole({
  required String? selfPublicKeyHex,
  required String? contactPublicKeyHex,
}) {
  if (selfPublicKeyHex == null || selfPublicKeyHex.isEmpty) return null;
  if (contactPublicKeyHex == null || contactPublicKeyHex.isEmpty) return null;
  final mine = selfPublicKeyHex.toLowerCase();
  final theirs = contactPublicKeyHex.toLowerCase();
  return mine.compareTo(theirs) <= 0 ? OtpPadRole.a : OtpPadRole.b;
}

/// How a pad's bytes are consumed as messages are sent and received.
///
/// This mirrors WADAMESH OTP_2_RC15.lua's `pmi_v` party-mode setting and
/// its `pdib()` ("pad direction is back?") function:
///
///  - Two-party pads (`pmi_v` 2 or 3 in Lua): Party A always sends growing
///    forward from the front of the buffer; Party B always sends growing
///    backward from the very end. `pdib()` returns true only for the
///    direction reading from the back (Party A decrypting Party B's
///    messages, or Party B's own sends). This is NOT a fixed-size half for
///    each party — see [OtpPadRole]'s doc comment.
///
///  - Multi/channel pads (`pmi_v` 1 in Lua — and Lua *forces* this mode
///    whenever the destination is a channel, via
///    `sync_party_mode_to_destination()`) have no role split at all:
///    `pdib()` always returns false, so sending AND receiving both consume
///    bytes from the same front of one shared pad. This is the only scheme
///    that generalizes past two parties — every participant must process
///    every channel message (their own included) in true chronological
///    order and consume the exact same bytes, or the group desyncs.
enum OtpPadMode {
  /// A/B half-split — exactly the two-party scheme this app already
  /// implemented. Used for contact (DM) pads.
  twoPartyHalfSplit,

  /// One shared front-of-pad counter, consumed identically by every send
  /// and every receive. Used for channel pads — forced, mirroring Lua's
  /// `sync_party_mode_to_destination()`.
  sharedSequential;

  static OtpPadMode fromName(String? value) {
    switch (value) {
      case 'sharedSequential':
        return OtpPadMode.sharedSequential;
      case 'twoPartyHalfSplit':
      default:
        // Also the correct default for pads persisted before this field
        // existed — they were all two-party contact pads.
        return OtpPadMode.twoPartyHalfSplit;
    }
  }
}

/// A shared one-time pad plus this device's consumption state for one
/// contact or one channel.
///
/// Stored unencrypted by default (matches every other per-contact /
/// per-channel setting in this app, which all live in plain
/// SharedPreferences) — a deliberate product decision, not an oversight —
/// UNLESS the OTP passphrase-lock feature has been enabled, in which case
/// [OtpPadStore] transparently wraps the persisted JSON in real
/// authenticated encryption (see `OtpPadStore`/`PassphraseLockCrypto`).
/// Nothing about this in-memory class changes either way; only how the
/// store serializes it does.
class OtpPad {
  /// The full shared pad, as lowercase hex. Never transmitted after import;
  /// only ever consumed locally to derive per-message key material.
  final String padHex;

  final OtpPadMode mode;

  /// Only meaningful when [mode] is [OtpPadMode.twoPartyHalfSplit].
  final OtpPadRole role;

  /// Bytes already consumed from THIS device's own sending half.
  /// [OtpPadMode.twoPartyHalfSplit] only — see [offset] for
  /// [OtpPadMode.sharedSequential].
  final int myOffset;

  /// Bytes already consumed from the OTHER party's half, i.e. how far this
  /// device has advanced while decrypting their incoming messages.
  /// [OtpPadMode.twoPartyHalfSplit] only — see [offset] for
  /// [OtpPadMode.sharedSequential].
  final int theirOffset;

  /// Bytes already consumed from the front of the ONE shared pad, by
  /// either sending or receiving — [OtpPadMode.sharedSequential] only.
  /// There is deliberately only one counter here: sending and receiving
  /// are the exact same consumption operation in this mode (see
  /// [takeSharedKeyBytes]/[advanceShared]), not two branches that happen
  /// to compute the same thing.
  final int offset;

  final bool enabled;

  /// Optional human label shown in the pad manager ("Camp trip pad", etc.)
  final String? label;

  final DateTime importedAt;

  const OtpPad({
    required this.padHex,
    this.mode = OtpPadMode.twoPartyHalfSplit,
    this.role = OtpPadRole.a,
    this.myOffset = 0,
    this.theirOffset = 0,
    this.offset = 0,
    this.enabled = true,
    this.label,
    required this.importedAt,
  });

  bool get isSharedSequential => mode == OtpPadMode.sharedSequential;

  int get totalBytes => padHex.length ~/ 2;

  /// The offset actually driving "my" consumption — [offset] in shared
  /// mode, [myOffset] in two-party mode.
  int get _myOffsetEffective => isSharedSequential ? offset : myOffset;
  int get _theirOffsetEffective => isSharedSequential ? offset : theirOffset;

  /// Combined remaining budget. Mirrors Lua's emmb():
  /// `#rec.bytes - ctr_mine - ctr_theirs`. In [OtpPadMode.twoPartyHalfSplit]
  /// there is deliberately no FIXED half-sized cap per direction — my sends
  /// and their sends draw down the SAME pool from opposite ends of one
  /// buffer (see [takeMyKeyBytes]/[takeTheirKeyBytes]), exactly like Lua's
  /// pks()/pdib(), so [myBytesRemaining] and [theirBytesRemaining] below
  /// are the same number by construction — there's no Lua-side concept of
  /// "my half" vs "their half" remaining as two independent figures, only
  /// one shared budget both directions draw from.
  int get _combinedRemaining => isSharedSequential
      ? (totalBytes - offset).clamp(0, totalBytes)
      : (totalBytes - myOffset - theirOffset).clamp(0, totalBytes);

  int get myBytesRemaining => _combinedRemaining;
  int get theirBytesRemaining => _combinedRemaining;

  double get myUsageFraction => totalBytes == 0
      ? 1.0
      : (_myOffsetEffective / totalBytes).clamp(0.0, 1.0);
  double get theirUsageFraction => totalBytes == 0
      ? 1.0
      : (_theirOffsetEffective / totalBytes).clamp(0.0, 1.0);

  /// True once the shared budget is fully consumed — the pad needs
  /// replacing.
  bool get isExhausted => _combinedRemaining <= 0;

  Uint8List _takeBytes(int start, int length) {
    final all = hex2Uint8List(padHex);
    final end = (start + length).clamp(0, all.length);
    if (end <= start) return Uint8List(0);
    return all.sublist(start, end);
  }

  /// Takes [length] bytes starting [offset] bytes from the END of the
  /// buffer and growing toward the middle as [offset] increases — the
  /// mirror image of [_takeBytes], which grows from the front.
  Uint8List _takeBytesFromEnd(int offset, int length) {
    final all = hex2Uint8List(padHex);
    final end = (all.length - offset).clamp(0, all.length);
    final start = (end - length).clamp(0, end);
    if (end <= start) return Uint8List(0);
    return all.sublist(start, end);
  }

  /// Role A's own sends grow forward from byte 0 (true only for B).
  bool get _myGrowsBackFromEnd =>
      !isSharedSequential && role == OtpPadRole.b;

  /// The next unused slice of THIS device's own sending stream, [length]
  /// bytes long ([OtpPadMode.twoPartyHalfSplit] only). Does not mutate
  /// state — call [copyWith] (via the store) once the bytes are actually
  /// spent on a sent message.
  ///
  /// Mirrors Lua's pks(rec, n, "mine")/pdib(): Party A consumes forward
  /// from the front of the shared buffer; Party B consumes backward from
  /// the very end. There is no fixed halfway boundary — the two directions
  /// just can never combine past the buffer's full length (enforced by
  /// [myBytesRemaining] before a send is allowed). A FIXED half-split (A
  /// always [0, len/2), B always [len/2, len), both growing forward) is a
  /// different, incompatible byte range from Lua's and will fail to
  /// decrypt against a real Lua peer — see platform-learnings.md.
  Uint8List takeMyKeyBytes(int length) => _myGrowsBackFromEnd
      ? _takeBytesFromEnd(myOffset, length)
      : _takeBytes(myOffset, length);

  /// The next unused slice used to decrypt the OTHER party's incoming
  /// messages, [length] bytes long ([OtpPadMode.twoPartyHalfSplit] only).
  /// The mirror image of [takeMyKeyBytes] — Party A reads the other
  /// party's bytes from the back, Party B reads them from the front.
  Uint8List takeTheirKeyBytes(int length) => _myGrowsBackFromEnd
      ? _takeBytes(theirOffset, length)
      : _takeBytesFromEnd(theirOffset, length);

  /// The next unused slice of the ONE shared pad, [length] bytes long
  /// ([OtpPadMode.sharedSequential] only). Used identically for both
  /// sending and receiving — see the class doc on [offset].
  Uint8List takeSharedKeyBytes(int length) => _takeBytes(offset, length);

  /// Returns a copy with [offset] advanced by [length] bytes
  /// ([OtpPadMode.sharedSequential] only).
  OtpPad advanceShared(int length) => copyWith(offset: offset + length);

  OtpPad copyWith({
    String? padHex,
    OtpPadMode? mode,
    OtpPadRole? role,
    int? myOffset,
    int? theirOffset,
    int? offset,
    bool? enabled,
    Object? label = _unset,
    DateTime? importedAt,
  }) {
    return OtpPad(
      padHex: padHex ?? this.padHex,
      mode: mode ?? this.mode,
      role: role ?? this.role,
      myOffset: myOffset ?? this.myOffset,
      theirOffset: theirOffset ?? this.theirOffset,
      offset: offset ?? this.offset,
      enabled: enabled ?? this.enabled,
      label: label == _unset ? this.label : label as String?,
      importedAt: importedAt ?? this.importedAt,
    );
  }

  static const Object _unset = Object();

  Map<String, dynamic> toJson() => {
    'padHex': padHex,
    'mode': mode.name,
    'role': role.label,
    'myOffset': myOffset,
    'theirOffset': theirOffset,
    'offset': offset,
    'enabled': enabled,
    'label': label,
    'importedAt': importedAt.millisecondsSinceEpoch,
  };

  static OtpPad? fromJson(Map<String, dynamic> json) {
    final padHex = json['padHex'];
    if (padHex is! String || padHex.isEmpty) return null;
    try {
      return OtpPad(
        padHex: padHex,
        // Pads persisted before `mode` existed have no field here at all —
        // they were all two-party contact pads, which is exactly what
        // OtpPadMode.fromName(null) defaults to.
        mode: OtpPadMode.fromName(json['mode'] as String?),
        role: OtpPadRole.fromLabel((json['role'] as String?) ?? 'A'),
        myOffset: (json['myOffset'] as num?)?.toInt() ?? 0,
        theirOffset: (json['theirOffset'] as num?)?.toInt() ?? 0,
        offset: (json['offset'] as num?)?.toInt() ?? 0,
        enabled: (json['enabled'] as bool?) ?? true,
        label: json['label'] as String?,
        importedAt: DateTime.fromMillisecondsSinceEpoch(
          (json['importedAt'] as num?)?.toInt() ??
              DateTime.now().millisecondsSinceEpoch,
        ),
      );
    } catch (_) {
      return null;
    }
  }
}
