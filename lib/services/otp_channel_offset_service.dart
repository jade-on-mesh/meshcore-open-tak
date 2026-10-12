/// Wire format for channel-only explicit pad-offset framing — fixes a real
/// architectural gap: a channel's OTP pad is shared-sequential (see
/// [OtpPadMode.sharedSequential] on `OtpPad`), meaning every participant
/// consumes bytes off the SAME single front-of-pad counter, with no
/// per-sender split the way a two-party DM pad has (`myOffset`/`theirOffset`,
/// two independent slices). Two participants who compose and transmit into
/// the same channel close enough together that neither has heard the
/// other's message yet will encrypt against the exact same pad bytes. Before
/// this fix, a receiver had no way to tell that apart from an ordinary
/// message — it just decrypted whatever arrived at its own current front,
/// producing garbage for whichever of the two collided messages it happened
/// to process second (the intermittent "garbled channel message" reports).
///
/// This is wire-compatible with the Lua app's identical fix (see
/// `CHANNEL_OFFSET_MARKER`/`z2` handling in `OTP_3_RC1.lua`'s `raw_transmit`
/// and `do_on_message`).
///
/// Wire layout (all ASCII prefix, then the existing bare-hex ciphertext):
///   `z2<offset36>|<cipherHex>`
/// where `<offset36>` is the sender's pad offset AT THE MOMENT this
/// ciphertext was encrypted, in base 36 — the exact same position number
/// [OtpSyncService] already sends in the clear for sync-checks, so this
/// reveals nothing about key material, just where in the (otherwise opaque)
/// byte stream this message claims to sit.
///
/// `z2` was picked for the same reason `z1` (the sync-check marker) was:
/// it can't collide with real ciphertext (always pure hex `[0-9a-f]`), with
/// `z1` itself, or with this app's other plaintext markers (`g:`, `m:`,
/// `V1|`). This is a channel-only marker — a DM pad has no coordination
/// problem to fix (see the class doc above), so DM messages are never
/// wrapped with it.
///
/// Strictly additive: a channel message with no `z2` prefix (an older
/// build on either platform, or before this ships everywhere) is left
/// completely alone by [parse] (returns null) and the caller falls back to
/// treating it exactly as it always has — decrypt at the current front,
/// no offset check. Mixed-version meshes keep working; they just don't get
/// the new detection until both sides have it.
class OtpChannelOffsetService {
  OtpChannelOffsetService._();

  static const String marker = 'z2';

  /// Wraps an already-encrypted [cipherHex] with the sender's claimed pad
  /// [offset] (captured BEFORE that offset was advanced by this send).
  static String wrap(int offset, String cipherHex) =>
      '$marker${offset.toRadixString(36)}|$cipherHex';

  /// Cheap pre-check, mirroring [OtpSyncService.looksLikeSyncMessage] — used
  /// to keep Smaz/Cyr2Lat and other outbound-text transforms from touching
  /// an already-framed outgoing channel payload.
  static bool looksLikeOffsetMessage(String text) => text.startsWith(marker);

  /// Parses a message that may or may not start with [marker]. Returns null
  /// for anything that doesn't match (including a well-formed message with
  /// no marker at all) — callers should treat null as "no offset claimed,
  /// handle exactly as before this fix", not as an error.
  static ({int offset, String cipherHex})? parse(String text) {
    if (!text.startsWith(marker)) return null;
    final rest = text.substring(marker.length);
    final pipeIndex = rest.indexOf('|');
    if (pipeIndex <= 0) return null;
    final offsetStr = rest.substring(0, pipeIndex);
    final cipherHex = rest.substring(pipeIndex + 1);
    if (cipherHex.isEmpty) return null;
    final offset = int.tryParse(offsetStr, radix: 36);
    if (offset == null || offset < 0) return null;
    return (offset: offset, cipherHex: cipherHex);
  }
}
