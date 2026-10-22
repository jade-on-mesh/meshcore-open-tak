# MeshCore TEAM

[MeshCore TEAM](https://github.com/tmacinc/MeshCore-TEAM) is another app that tracks a group on a private channel. MeshCore Open TAK's Team understands it: put both on the **same private channel** (TEAM's tracking channel, our team channel) and each side sees the other. Nothing changes in how our Team looks. TEAM users show up as ordinary team members, markers and routes, drawn our way.

Wadamesh TAK standalones do the same in their Team app.

## What you see from TEAM users

- **Positions.** Each TEAM user is a team member on the map and in the Team list. Their callsign is the name they set in TEAM (their alias), or their radio name until that arrives. The battery shows as a percent, from the radio's voltage (or the phone's, when that's all they send). A radio tracking on its own GPS, with no phone (TEAM's autonomous mode), counts as a fix from the radio.
- **Waypoints** become our markers, labelled with their name, with their description as the note:

  | TEAM | Our marker |
  | --- | --- |
  | Camp | Staging / command post |
  | Meetup | Last known point |
  | Danger | Hazard |
  | Water | Water / resources |
  | Game area, deer stand, vehicle, custom | Point |

- **Routes** become our route drawings, in the team colour nearest theirs.

TEAM's tracking messages (`#TEL:`, `#T:`, `#CAP:`, `#WAY:`, `#WRC:`) never show up as chat, on any channel.

## What TEAM users see from us

Once a TEAM user has been heard on the team channel, and for 12 hours after, the app also speaks TEAM's formats on that channel:

- With each of our position beacons (at most every 15 seconds), a `#TEL:` with our position and the radio's battery.
- A `#CAP:` with our callsign as the alias and our radio key, so TEAM shows our callsign: when TEAM is first heard, when the callsign changes, and every 6 hours.
- Each new or moved marker as a TEAM waypoint (kinds mapped back as in the table, others as Custom), and each route or line as a TEAM route with our colour.
- An advert, when a TEAM user asks for ours (`#CAP:R:`), at most every 10 minutes.

Before a TEAM user has been heard, none of this goes on the air, so a team without TEAM users spends no extra airtime. Deleting a marker or route doesn't reach TEAM (TEAM has no way to say it).

TEAM's smart forwarding and topology (`#T:` neighbour lists) aren't used: `#T:` is read for its position and battery only.

## On the air

TEAM sends channel text, where our Team sends binary channel data:

| Message | Format |
| --- | --- |
| Position | `#TEL:` + unpadded base64 of 11 bytes: latitude and longitude (int32 big-endian, degrees × 10⁷), radio battery, phone battery, forwarding byte. Battery bytes: 0/1 unknown, else `(mV − 2750) / 6 + 2`, up to 254; a phone battery of 0xFF marks a radio on its own GPS. |
| Position + neighbours | `#T:` + unpadded base64: the same first 10 bytes, a node count, a neighbour bitmap |
| Alias | `#CAP:2:<flags hex>:<radio key, 12 hex>:<app id, 16 hex or ->:<alias>` (alias last, up to 24 bytes); `#CAP:1:<flags>` from older versions |
| Advert request | `#CAP:R:<key prefix or ->:<radio name>` |
| Waypoint or route | `#WAY:<id>\|<name>\|<lat>\|<lon>\|<description>\|<type>\|<route>`, the route as `lat,lon~lat,lon…` and its colour as an `@C:AARRGGBB` prefix on the description. A long route continues in `#WRC:<id>\|<chunk>\|<n>/<N>` parts, the first `#WAY` ending in `\|1/<N>`. Messages stay within 140 bytes with the radio name in front. |

A TEAM sender is known by its radio name (channel messages carry no key). Its `#CAP` gives the first bytes of its radio key, which is what we file its position under; before that, a contact with the same name, or failing that a number made from the name. Radio names in a team should be unique, as TEAM's own docs ask.

Code: `lib/team/team_compat.dart` (the formats, written for this app from TEAM's wire descriptions; TEAM's code is CC BY-NC-SA and isn't used) and `lib/team/team_compat_bridge.dart`. Tests: `test/team/team_compat_test.dart`, with golden strings Wadamesh TAK's `test/test_team_compat.cpp` checks too.
