// MeshCore Open TAK - how long a photo or voice transfer waits at its edges.
//
// Mirrored in Wadamesh (src/ui-touch/VoxFetch.cpp), which must make the same
// calls so a T-Deck and a phone behave alike.

/// How long after posting a photo's announcement on a channel the push to the
/// radios in range starts: long enough for the announcement to have gone out
/// on the main mesh and been heard by them (one airtime, plus the radio's
/// queue and the listener's handling), and no longer.
///
/// [announceAir] is the announcement's airtime on the main mesh, or null when
/// the radio's settings aren't known.
Duration voxPushLead(Duration? announceAir) {
  if (announceAir == null) return const Duration(milliseconds: 1500);
  final ms = announceAir.inMilliseconds + 500;
  return Duration(milliseconds: ms.clamp(700, 1500));
}

/// After the last packet the sender meant to send has arrived with some
/// missing: how long to wait for stragglers before asking for the gaps.
///
/// Packets that came straight from the sender ([relayed] false: every one
/// heard at 0 hops) arrive in order, so once the last is in, the rest are
/// lost. Relayed ones can still be on their way through a repeater.
Duration voxGapRequestDelay({
  required bool relayed,
  required Duration packetGap,
  required Duration zeroHopGap,
}) => relayed
    ? packetGap + const Duration(milliseconds: 1000)
    : zeroHopGap + const Duration(milliseconds: 400);

/// While packets are flowing: how long without one before the transfer
/// counts as stalled (its tail lost) and the missing packets are asked for.
/// Three packet gaps, plus time for the sender's radio to clear its queue.
Duration voxStallWait(Duration packetGap) =>
    packetGap * 3 + const Duration(milliseconds: 2500);

/// Packets of a photo or clip nobody here asked for (pushed by the sender, or
/// sent for another listener) stopped arriving with some missing: ask for the
/// rest when at least half is already here.
bool voxShouldFinishPassive({required int received, required int total}) =>
    total > 0 && received < total && received * 2 >= total;
