// MeshCore Open TAK - how long a photo or voice transfer waits at its edges.
//
// Mirrored in Wadamesh (src/ui-touch/VoxFetch.cpp), which must make the same
// calls so a T-Deck and a phone behave alike.

import 'dart:math';

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

/// The gap to expect between a transfer's packets: the timing model's
/// [model] until a few have come in ([samples] gaps measured), then twice the
/// gap they actually came at ([seen], smoothed) when that's sooner, but never
/// under [floor] (one zero-hop gap). A transfer sent faster than the model
/// assumes (over radio2, or from a sender with a faster radio) has its lost
/// tail asked for again in seconds rather than tens of seconds.
Duration voxBurstGap({
  required Duration model,
  required Duration seen,
  required int samples,
  required Duration floor,
}) {
  if (samples < 3) return model;
  var g = seen * 2;
  if (g < floor) g = floor;
  return g < model ? g : model;
}

/// Packets of a photo or clip nobody here asked for (pushed by the sender, or
/// sent for another listener) stopped arriving with some missing: ask for the
/// rest when at least half is already here.
bool voxShouldFinishPassive({required int received, required int total}) =>
    total > 0 && received < total && received * 2 >= total;

/// How long a listener waits after a channel photo's announcement before
/// asking for its first two packets (its thumbnail) alone: past the
/// sender's push (voxPushLead, at most 1.5 s, and the packets' airtime), then
/// spread over [voxThumbProbeSpreadMs] so one listener's ask, answered on
/// the channel, serves the rest. Mirrored in Wadamesh (VoxFetch::kThumbProbe*).
const int voxThumbProbeChannelWaitMs = 4000;
const int voxThumbProbeSpreadMs = 4000;

/// The same for a photo sent in a DM, which nobody pushes.
const int voxThumbProbeDirectWaitMs = 1500;

/// Asks for the thumbnail at most this many times, [voxThumbProbeRetryMs]
/// (plus up to [voxThumbProbeSpreadMs]) apart, while it hasn't come. Then the
/// bubble just offers the download.
const int voxThumbProbeTries = 3;
const int voxThumbProbeRetryMs = 8000;

/// Listen before talk on MediaMesh. A photo or voice packet waits while a
/// radio2 packet from someone else was heard lately: until radio2 has been
/// quiet for one packet's airtime plus a random part of another (so two that
/// both waited don't then collide), at most [voxLbtMaxWaitMs] in all, after
/// which it goes anyway rather than never. Mirrored in Wadamesh
/// (MediaMeshCore.h lbtQuietMs / lbtHold).
const int voxLbtMaxWaitMs = 20000;

int voxLbtQuietMs(int packetAirMs, int rnd) {
  final air = packetAirMs > 0 ? packetAirMs : 100;
  return air + 50 + rnd % (air ~/ 2 + 1);
}

/// Whether to hold a packet now: radio2 heard [sinceHeardMs] ago (null:
/// never), waiting [waitedMs] so far.
bool voxLbtHold({
  required int? sinceHeardMs,
  required int quietMs,
  required int waitedMs,
}) =>
    sinceHeardMs != null &&
    sinceHeardMs < quietMs &&
    waitedMs < voxLbtMaxWaitMs;

/// Fetch requests one transfer may make: a photo of hundreds of packets over
/// many hops loses some on most passes, so the budget grows with its size
/// (49 for a 234-packet Super Sharp). Mirrored in Wadamesh (VoxFetch.h
/// attemptBudget / stallBudget / stallBackoff).
const int voxMaxAttempts = 15;
const int voxMaxStalls = 3;

int voxAttemptBudget(int total) => max(voxMaxAttempts, 10 + total ~/ 6);

/// Fetch requests in a row that may bring nothing before giving up. With far
/// fewer than all the packets missing the sender is there and the link
/// works: keep at it rather than stop a packet or two short.
int voxStallBudget(int received, int total) {
  if (received <= 0 || total <= 0) return voxMaxStalls;
  if (received * 10 >= total * 9 || total - received <= 4) return 8;
  if (received * 2 >= total) return 5;
  return voxMaxStalls;
}

/// Each fetch request in a row that brought nothing waits longer for its
/// answer: up to 3x over the first four (a long or busy route is slow, not
/// gone), then half as long again each time, at most 4 minutes. Requests
/// repeated at the same pace kept failing the same way (attempts 4-11 of one
/// clip came every 25-60 s), and each one is airtime on a busy channel.
Duration voxStallBackoff(Duration wait, int stalls) {
  var d = wait + wait * min(stalls, 4) ~/ 2;
  for (var i = 4; i < stalls && d < voxStallBackoffCap; i++) {
    d = d * 3 ~/ 2;
  }
  return d < voxStallBackoffCap || stalls <= 4 ? d : voxStallBackoffCap;
}

const Duration voxStallBackoffCap = Duration(minutes: 4);
