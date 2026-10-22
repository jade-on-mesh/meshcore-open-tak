# Who got it

Tap one of your channel messages (or long-press it and pick *Who got it
(map)*) to see how far it went: a map with a fan of lines from you, and the
lists under it.

| On the map | Meaning |
| --- | --- |
| Solid orange line | A repeater that heard you directly and re-sent it |
| Dashed orange line | A repeater further out, from the one before it |
| Dotted line in a teammate's colour | A teammate who heard it |

Repeaters come from the echoes of your message the radio hears as it floods
(the same ones *Path* lists); a repeater whose location isn't known is listed
without a line. The screen keeps filling in as echoes and beacons arrive.

## Teammates

With team mode on, each position beacon also carries:

- a short hash of the sender's radio name, so teammates can tell which
  channel messages are from a teammate;
- the ids of the last four teammates' channel messages it heard (each one's
  reaction hash: its time, sender and first five characters).

So a teammate who heard your message says so in their next beacon, which goes
out 15–45 s after hearing it (at most one extra beacon every 2 minutes).
Teammates whose beacons haven't mentioned it are listed as *Not heard yet*;
that includes anyone on an older app or firmware. Wadamesh TAK standalones
send and read the same beacon fields.

On the air it is flag `0x40` of the position message, after the callsign (and
the added-role byte, if any): `[nameHash u16][n u8][heard u16 × n]`, n ≤ 4.
Older readers stop at the callsign. See `lib/team/team_wire.dart`.
