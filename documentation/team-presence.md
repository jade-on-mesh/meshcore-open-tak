# Team presence

How teammates get onto the Team list and map, and stay there. It works the same in MeshCore Open TAK and in Wadamesh TAK's Team app on standalones.

## Beacons

Each member sends a position beacon on the team channel:

- when they first join, or change their callsign, role, colour or status;
- while moving: every 90 seconds, at turns, or after 75 m;
- while still: every 10 minutes.

A phone uses its own GPS. A phone that isn't moving gets no new GPS fixes, so its last fix keeps standing for its position for up to 30 minutes, and the app asks for a fresh fix every 5 minutes. Before, a still phone counted as having no position after 2 minutes. If its radio had no position either, the phone stopped beaconing, and teammates saw it go stale and then disappear.

## Each beacon is new

Team traffic is channel data, which carries no timestamp, and channel encryption gives the same bytes for the same message. Every MeshCore radio drops a packet it has seen recently, and it remembers its last 160. So a member who wasn't moving sent the same beacon each time, and repeaters and teammates dropped every one after the first.

Each beacon now carries a beacon number that goes up every time (position flag `0x80`, a `u16` at the end). The same goes for:

- **Alerts:** each repeat of an alert or its cancel carries its own number (flag `0x04`, a byte after the note).
- **CASEVAC:** each repeat of a 9-line gets a trailing byte.
- **Re-sharing:** **Resend my pins and drawings** sends each item with its time moved to now.

Older app versions and standalones ignore the extra bytes.

## Live, stale, lost

| | Last beacon |
| --- | --- |
| Live | under 25 minutes ago (two missed still beacons) |
| Stale | under an hour ago |
| Lost | older |

The app keeps teammates across restarts for 24 hours, with their last position and when it was heard, so the list doesn't start empty. A teammate who isn't live can be removed from their sheet (**Remove from the team list**).

## The team channel

The team channel is remembered by its slot, its name and its key. It's still found when it's renamed or moved to another slot, and while the radio's channel list reloads (after a reconnect or a channel edit).

## When nobody shows up

When no teammates are listed, the Team tab says what this radio has heard:

- **No team data has reached this radio:** nothing from any teammate. Check that they have team mode on, are in range, and are sharing their position.
- **Team data was heard on another channel:** teammates are on a different channel. Everyone should pick the same team channel, for example by scanning the team's QR code ([Sharing a team in one scan](team-setup.md)).
- **N team messages heard:** traffic arrives. If teammates still don't show, they may be on an older version, so update everyone.

Code: `lib/team/team_service.dart` and `lib/team/team_wire.dart`, with golden bytes in `test/team/team_wire_golden_test.dart` that Wadamesh TAK's `test/test_team_wire.cpp` checks too.
