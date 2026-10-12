/// Result of the most recent pad sync-check exchange with one peer — a
/// contact's DM pad, or one participant of a channel's shared pad.
///
/// [inSync] is deliberately nullable with three real states, not a bool:
///   - `null`  — unknown: no sync-check has been run yet, or one is still
///     awaiting a reply (see [timedOut] to tell those two apart).
///   - `true`  — the peer's reported counters matched what this device
///     expects.
///   - `false` — they didn't; see [driftBytes]/[driftDirection].
class OtpSyncStatus {
  /// When THIS device last sent (or received, for the responding side's own
  /// bookkeeping) a sync-check for this peer.
  final DateTime checkedAt;

  /// When a reply (or, for the receiving side, the triggering message
  /// itself) was last processed. Null while a just-sent check is still
  /// awaiting its reply.
  final DateTime? repliedAt;

  /// True once [checkedAt] is old enough that a reply is no longer
  /// expected. Left as "unknown" (not "out of sync") — see the class doc.
  final bool timedOut;

  final bool? inSync;

  /// Signed byte drift, only meaningful when [inSync] is false. Positive
  /// means this device's counter is ahead of the peer's; negative means the
  /// peer is ahead. (See [driftDirection] for the human-readable form.)
  final int? driftBytes;

  /// `'mine-ahead'`, `'theirs-ahead'`, or null (in sync / unknown).
  final String? driftDirection;

  /// Non-null only on the status update produced by an automatic resync
  /// (see `MeshCoreConnector._maybeAutoResyncContact`/`_maybeAutoResyncChannel`):
  /// how many bytes this device just skipped forward to catch up. A
  /// message worth of pad may have been unrecoverably lost in transit —
  /// this is surfaced in the UI rather than silently absorbed.
  final int? autoResyncedBytes;

  /// True only for a two-party DM pad where the peer's sync-check stated
  /// the SAME resolved role ("A"/"B") as this device's own — both sides
  /// think they own the same half of the pad, so the counters aren't even
  /// comparable and [inSync] is forced false. This is a hard stop, not a
  /// drift to auto-fix: see `MeshCoreConnector._maybeHandleContactSyncMessage`.
  /// The affected pad needs to be wiped and re-imported on one device.
  final bool roleCollision;

  const OtpSyncStatus({
    required this.checkedAt,
    this.repliedAt,
    this.timedOut = false,
    this.inSync,
    this.driftBytes,
    this.driftDirection,
    this.autoResyncedBytes,
    this.roleCollision = false,
  });

  /// Still waiting on a reply to a check this device sent.
  bool get isPending => repliedAt == null && !timedOut;

  OtpSyncStatus copyWith({
    DateTime? checkedAt,
    Object? repliedAt = _unset,
    bool? timedOut,
    Object? inSync = _unset,
    Object? driftBytes = _unset,
    Object? driftDirection = _unset,
    Object? autoResyncedBytes = _unset,
    bool? roleCollision,
  }) {
    return OtpSyncStatus(
      checkedAt: checkedAt ?? this.checkedAt,
      repliedAt: repliedAt == _unset
          ? this.repliedAt
          : repliedAt as DateTime?,
      timedOut: timedOut ?? this.timedOut,
      inSync: inSync == _unset ? this.inSync : inSync as bool?,
      driftBytes: driftBytes == _unset
          ? this.driftBytes
          : driftBytes as int?,
      driftDirection: driftDirection == _unset
          ? this.driftDirection
          : driftDirection as String?,
      autoResyncedBytes: autoResyncedBytes == _unset
          ? this.autoResyncedBytes
          : autoResyncedBytes as int?,
      roleCollision: roleCollision ?? this.roleCollision,
    );
  }

  static const Object _unset = Object();
}
