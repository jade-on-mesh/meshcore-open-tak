import '../models/otp_pad.dart';

/// Wire format for the OTP pad "sync-check" control message — a lightweight,
/// user-triggered exchange of PAD POSITION COUNTERS ONLY, never pad byte
/// content, so it never costs any pad bytes and reveals nothing about key
/// material. This has no Lua equivalent as a *feature*, but the wire format
/// below is wire-compatible with the Lua app's own copy (see the comment on
/// SYNC_MARKER/send_sync_check/handle_sync_message in OTP_3_RC1.lua).
///
/// Deliberately NOT OTP-encrypted (there's nothing secret in "how many
/// bytes have you consumed") but still needs to be recognizable as a
/// distinct control message rather than an ordinary chat message — this
/// follows the same convention as this app's other non-OTP structured
/// outbound-text markers (`g:`, `m:`, `V1|` — see
/// `MeshCoreConnector.prepareContactOutboundText`): a short ASCII prefix,
/// checked against those (and against the OTP chunk/ack markers, which are
/// binary and only ever appear post-decrypt, so there's no collision risk
/// there either).
///
/// Wire layout (v3, all ASCII):
///   `z3p<role><myOffset36>:<theirOffset36>`   (two-party pad, initial check)
///   `z3P<role><myOffset36>:<theirOffset36>`   (two-party pad, reply)
///   `z3s<offset36>`                            (shared/channel pad, initial check)
///   `z3S<offset36>`                            (shared/channel pad, reply)
/// where `<N36>` is N encoded in base 36 (`0-9a-z`), lowercase on send,
/// accepted case-insensitively on receive, and `<role>` is a single `A`/`B`
/// character: the sender's own resolved [OtpPadRole] for this two-party pad
/// (shared/channel pads have no role split, so they carry none).
///
/// This is v3 of the format. v2 (`z1`) was shrunk from v1's `OTPSYNC1|2P|
/// <flag>|<myOffset>:<theirOffset>` / `OTPSYNC1|SS|<flag>|<offset>`
/// (pipe-delimited decimal, ~17-21 bytes per message) down to ~4-8 bytes:
/// the mode and reply-flag are folded into a single case-coded letter
/// (`p`/`P`, `s`/`S`) instead of a 2-char mode token plus a separate `0`/`1`
/// flag field, and counters are base-36 rather than decimal. v3 adds the
/// `<role>` character to two-party payloads: `resolveDmRole`'s own doc
/// comment already flagged that a same-role collision (both sides
/// independently resolving to "A", say) was undetectable by the counter
/// check alone; now each side states its role directly on the wire, so a
/// collision can be caught explicitly the moment it's seen, instead of only
/// being inferred after the fact from implausible byte-count math. `z1`/`z3`
/// is the format-version tag (bump again if the payload shape ever needs to
/// change further, so old and new builds can tell each other's messages
/// apart instead of silently misparsing them) — chosen because it can't
/// collide with real message content (ciphertext is always pure hex
/// `[0-9a-f]`), the other plaintext markers above (`g:`, `m:`, `V1|`), or
/// the start of an ordinary, human-typed chat message. This is a BREAKING
/// change from v2 — every device sharing a pad needs the matching build at
/// the same time; a v2 and a v3 peer cannot sync-check with each other at
/// all (the marker itself won't match).
///
/// NOTE: this was originally shipped with marker `z2`, which collides with
/// [OtpChannelOffsetService.marker] (also `z2`, already in use by the
/// channel-collision-detection feature that wraps every real channel
/// ciphertext message). Since `_maybeHandleChannelSyncMessage` is checked
/// before channel ciphertext is unwrapped in `MeshCoreConnector`, every real
/// channel message got misrouted into this sync-check parser and silently
/// swallowed instead of ever being decrypted — the receiving side's channel
/// counter could never advance, and users saw pad-draining auto-resyncs
/// trying (and failing) to close a gap that real traffic kept silently
/// reopening. Renamed to `z3` to stop colliding; `OtpChannelOffsetService`
/// keeps its original, field-confirmed `z2`.
///
/// `replyFlag` (the letter case) is initial for the message that triggers a
/// check and reply for the automatic reply it provokes — receiving a reply
/// message must never itself provoke another reply, or two devices
/// checking at the same moment (or a multi-party channel) would ping-pong
/// forever.
class OtpSyncPayload {
  final bool isSharedSequential;
  final bool isReply;

  /// Two-party ([isSharedSequential] false) only.
  final int? myOffset;

  /// Two-party ([isSharedSequential] false) only.
  final int? theirOffset;

  /// Two-party ([isSharedSequential] false) only. The role as STATED on the
  /// wire by whoever sent this payload — when building an outgoing payload
  /// this is this device's own resolved role; when parsing an incoming one
  /// it's the peer's claimed role. Never inferred either way.
  final OtpPadRole? role;

  /// Shared-sequential ([isSharedSequential] true) only.
  final int? offset;

  const OtpSyncPayload.twoParty({
    required this.isReply,
    required int myOffset,
    required int theirOffset,
    required OtpPadRole role,
  }) : isSharedSequential = false,
       myOffset = myOffset,
       theirOffset = theirOffset,
       role = role,
       offset = null;

  const OtpSyncPayload.shared({required this.isReply, required int offset})
    : isSharedSequential = true,
      myOffset = null,
      theirOffset = null,
      role = null,
      offset = offset;
}

class OtpSyncService {
  OtpSyncService._();

  static const String marker = 'z3';

  /// Markers used by earlier wire-format generations, kept here ONLY so a
  /// stale peer's old-format sync-check chatter is still recognized and
  /// suppressed from chat display by [looksLikeSyncMessage], even though
  /// this build can't actually parse or act on it ([parse] still only ever
  /// matches [marker] — see the real-world report below). Without this, an
  /// up-to-date device sees a message it doesn't recognize as a control
  /// message at all, and it falls straight through to the chat view as
  /// literal garbage ("z1sak", "z1sao", ...) — reported from CascadiaMesh
  /// field testing where one device had gone a while without an update.
  ///
  /// Deliberately does NOT include the transient 'z2' this marker held for
  /// one patch, between the role-handshake bump and the very next one that
  /// moved it again to 'z3' - 'z2' is ALSO (and permanently)
  /// [OtpChannelOffsetService]'s channel-offset marker, so treating it as a
  /// legacy sync marker here would misidentify real channel ciphertext
  /// (which legitimately starts with 'z2' too) as sync-check control
  /// chatter and silently drop it from the chat entirely - a worse bug
  /// (losing a real message) than the display leak this list is fixing.
  /// 'OTPSYNC1|' is the original v1 pipe-delimited format, from before any
  /// single-letter marker existed.
  static const List<String> _legacyMarkers = ['z1', 'OTPSYNC1|'];

  static String buildTwoParty({
    required bool isReply,
    required int myOffset,
    required int theirOffset,
    required OtpPadRole role,
  }) => '$marker'
      '${isReply ? 'P' : 'p'}'
      '${role.label}'
      '${myOffset.toRadixString(36)}:${theirOffset.toRadixString(36)}';

  static String buildShared({required bool isReply, required int offset}) =>
      '$marker'
      '${isReply ? 'S' : 's'}'
      '${offset.toRadixString(36)}';

  /// Cheap pre-check before bothering to [parse] — also what
  /// `prepareContactOutboundText`/`prepareChannelOutboundText` use to keep
  /// Smaz/Cyr2Lat from touching an outgoing sync-check message. Recognizes
  /// the current wire format and known-safe legacy ones (see
  /// [_legacyMarkers]) so old-format control chatter from a stale peer is
  /// always hidden from chat, never shown as garbage text. [parse] still
  /// only ever succeeds against [marker], so a legacy-marker message always
  /// resolves to "suppress, nothing actionable" - its already-documented
  /// null-parse behavior - never to a real (mis-)parsed sync exchange.
  static bool looksLikeSyncMessage(String text) =>
      text.startsWith(marker) || _legacyMarkers.any(text.startsWith);

  /// Parses a message already known to start with [marker]. Returns null
  /// for anything malformed — callers should still treat a null result as
  /// "this WAS a sync-check control message" (suppress it from chat
  /// display) even though there was nothing usable to act on, since a
  /// corrupted-in-transit control message is still not a chat message.
  static OtpSyncPayload? parse(String text) {
    if (!text.startsWith(marker)) return null;
    final rest = text.substring(marker.length);
    if (rest.isEmpty) return null;
    final modeChar = rest[0];
    final body = rest.substring(1);
    final isReply = modeChar == 'P' || modeChar == 'S';
    final isTwoParty = modeChar == 'p' || modeChar == 'P';
    final isShared = modeChar == 's' || modeChar == 'S';
    if (isTwoParty) {
      if (body.isEmpty) return null;
      final roleChar = body[0].toUpperCase();
      if (roleChar != 'A' && roleChar != 'B') return null;
      final counters = body.substring(1);
      final fields = counters.split(':');
      if (fields.length != 2) return null;
      final myOffset = int.tryParse(fields[0], radix: 36);
      final theirOffset = int.tryParse(fields[1], radix: 36);
      if (myOffset == null || theirOffset == null) return null;
      if (myOffset < 0 || theirOffset < 0) return null;
      return OtpSyncPayload.twoParty(
        isReply: isReply,
        myOffset: myOffset,
        theirOffset: theirOffset,
        role: OtpPadRole.fromLabel(roleChar),
      );
    }
    if (isShared) {
      final offset = int.tryParse(body, radix: 36);
      if (offset == null || offset < 0) return null;
      return OtpSyncPayload.shared(isReply: isReply, offset: offset);
    }
    return null;
  }
}
