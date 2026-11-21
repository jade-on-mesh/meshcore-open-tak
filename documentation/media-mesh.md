# MediaMesh

MediaMesh sends and receives photos and voice clips on a second LoRa frequency
of the connected radio, called `radio2`. Text, adverts, ACKs, team positions and
everything else stay on the main mesh. One radio listens to both frequencies by
switching between them, so you keep hearing the main mesh.

## Setting it up

**Settings → MediaMesh Settings** (under Radio Settings):

1. **radio2**: *Off* or *On* (listen and send there). Listen only is a console
   setting (`set radio2 ...,rx`); it selects neither, and *On* makes it send too.
   A repeater's radio2 page works the same way.
2. **Sent on radio2**: *Photos & voice* puts photos and voice clips there and
   keeps text on the main mesh. A mix set from the console shows as *Custom*
   and is left alone.
3. Pick the **Preset**, or set the **radio2 frequency**, **Bandwidth**,
   **Spreading factor** and **Coding rate** yourself:
   - **250 kHz · fast** (the default): 911.150 MHz, 250 kHz, SF7, 4/5. About
     four times as fast as SF7/62.5, for roughly 6 dB less range.

   The old *125 kHz · range* preset is gone: it confused people and nobody
   used it. A radio2 still set to 125 kHz shows no preset picked and keeps
   working.

   911.150 is a quiet spot found on site, inside a BayMesh 3 cavity filter
   tuned for 910.525 (flat about 908.6-912.8 MHz) and 625 kHz above the main
   channel. It must differ from the main radio, and every node on the MediaMesh
   needs the same settings.
   Not sure which preset the MediaMesh where you are uses? **Find MediaMesh**
   (under the presets) tells you: see below.
4. **Save**. The settings live on the radio, so they also apply when you are not
   connected (for example a Wadamesh radio fetching a photo by itself).

The dialog also shows, every few seconds while it is open: packets received and
sent on each profile, the measured switch time, and the radio's timing warnings.

### Find MediaMesh

**Off-Grid Repeat** (Radio Settings) sets radio2 while it's on, on any radio: beside the off-grid channel in the US band (918.800 MHz, 250 kHz, photos and voice on it), off elsewhere, and puts it back when it's turned off; see [Radio Settings](settings.md#radio-settings).

**Find MediaMesh** works like Discover Repeaters: it asks the repeaters in
direct range which radio2 profile they run, and lists them with what each said
and the SNR it heard them at:

- One zero-hop discovery request goes out on the main mesh with the radio2 flag
  (byte 0 `0x82`). Repeaters that support it answer within about 12 seconds
  with their radio2 profile after their key: frequency, bandwidth, SF, CR,
  listen only or listen and send, and whether it is a temporary profile.
- The profile most of them run is offered (the stronger signal breaks a tie),
  and **Use it** saves it, turning radio2 on for photos and voice if it was off.
- Repeaters that don't support it show as *didn't say*; ones with radio2 off
  show as *radio2 off*.

Answering with the profile is a proposed addition to keymindCascade (see
[the wire format](#discover-reply-radio2-profile) below); stock repeaters
ignore the flag and answer as usual. **When no repeater says**, Find falls back
to listening, in about 20 more seconds:

1. radio2 listens on the *250 kHz · fast* preset, at the frequency in the form,
   with a listen-only temporary radio2 (`set tempradio2 <MHz>,250,7,5,rx,2`).
2. A repeater discovery request goes out on the main mesh. MediaMesh repeaters
   (keymindCascade, `tx.reply both` by default) answer on both of their radios,
   so their radio2 answer is only heard when radio2 listens on the preset they
   run. The rise in `get radio2.status`'s radio2 receive count shows it.
3. About 9 seconds later, `set tempradio2 off` brings the saved radio2 back,
   and if radio2 heard packets the 250 kHz preset is offered.

It needs a MediaMesh repeater in direct range. Repeaters answer at most four
discovery requests every two minutes (asking uses one, listening one more), so
running it twice in a row may find nothing the second time. The listening
fallback won't run while a temporary radio2 is running. Wadamesh TAK
standalones have the same button (Settings → MediaMesh).

#### Discover reply: radio2 profile

Requested by bit 1 of DISCOVER_REQ byte 0 (`0x80 | 0x02`, combinable with the
prefix-only bit 0). The repeater appends 12 bytes after its key (after the
8-byte prefix in prefix-only mode):

```
[ver=1][flags][freq u32 LE, MHz x1000][bw u32 LE, kHz x1000][sf][cr]
flags: bit 0 radio2 configured, bits 1-2 mode (0 off, 1 rx, 2 rxtx),
       bit 3 temporary profile (tempradio2)
radio2 off: just [1][0]
example: 910.525 MHz, 250 kHz, SF7, CR5, rxtx = 0105bde40d0090d003000705
```

Stock clients check only `len >= 6+32` and ignore what follows. A later
version may append more; the first twelve bytes keep their meaning.

**Photos and voice stay off the main mesh.** They only go out when the
connected radio sends them on radio2 alone (*On*, *Photos & voice*).
Otherwise the app says so instead of sending, and doesn't answer other
people's requests for them either. There is no setting to allow the main mesh:
*Everything* isn't offered (it only shows when the radio is already set that
way from the console), and saving MediaMesh settings turns a Wadamesh
standalone's `mediamesh.share` off. This covers Open TAK's photos and voice
only: upstream MeshCore Open's channel image messages and OTP photo DMs (sent
direct, never flooded) are unchanged.

**Temporary radio2** tries the profile in the form for 15 minutes, 1 hour or
2 hours without saving it (`tempradio2`); **Stop** brings the saved radio2 back.
A reboot ends it too.

**Radio console** (at the bottom of the dialog) runs any radio command and
keeps a history: schedules (`radioat2`, `tempradioat2`), `tempradio`,
`normalradio`, `get radio2.timing` and the rest of Wadamesh's `MEDIAMESH.md`.

### Coverage map

**Map MediaMesh coverage** (MediaMesh Settings, under Find MediaMesh) records where the MediaMesh repeaters reach as you walk or drive, to find the holes and where the next one should go. Only repeaters with MediaMesh (radio2 on) count; plain repeaters are left out.

- Each time you've moved 150 m (at most every 40 seconds, because repeaters answer four discovery requests every two minutes), the app asks the repeaters in direct range, as Find MediaMesh does, and marks the spot.
- The dot's colour is the best MediaMesh repeater's margin on radio2: **Good** (green, 5 dB or more to spare), **Marginal** (amber, 0-5 dB), **Out** (red, heard but radio2 wouldn't reach), **None** (grey, no MediaMesh repeater answered).
- The ask goes out on the main mesh, and the radio doesn't say which radio an answer came in on, so radio2's reach is estimated: the weaker direction's SNR (ours of the answer, the repeater's of the ask), less the extra noise radio2's wider bandwidth hears (10·log10 of radio2's bandwidth over the main mesh's: 6 dB from 62.5 to 250 kHz), against the lowest SNR radio2's spreading factor decodes (SF7: −7.5 dB, 2.5 dB lower each step).
- **Show on the map** puts the dots on the Tactical map. Tap a dot to see when it was measured and each MediaMesh repeater heard there, best first: its name and key, its margin on radio2 (in the dot's colours) and the SNR both ways. On a dot, the map's long press (drop a pin, SALUTE and the rest) needs a longer hold, 1.2 s: let go before that and the dot opens instead, so the two don't get mixed up. Everywhere else the long press is as before. **Export** shares them as GeoJSON (each point with its time, reach and the repeaters heard, their SNR and margin), for a coverage map on a website. **Clear** starts over. The points are kept across restarts (the latest 3,000).

On Android a notification shows while it's recording, so it keeps going with the screen off. Wadamesh TAK standalones record the same (Settings › MediaMesh › Map coverage), with the same colours.

#### Sharing coverage points

**Share coverage points** (under the coverage map's buttons, off by default) sends what you record to a CoreScope analyzer, where the MediaMesh coverage estimate is checked against it: the whole estimate for people on the ground moves up or down to match, a repeater with enough points of its own gets its own correction, and drives set what a car costs. The analyzer draws them as 200 m squares (green, amber, red and grey, as here), leaves out the first and last 300 m of every trip so nobody's home shows, and never says whose they are.

- **Analyzer** is the address the points are sent to: `https://analyzer.cascadiamesh.org/api/mediamesh/coverage-points` unless you enter your own area's (any CoreScope with the CascadiaMesh fork's coverage points). Its upload address, or just the analyzer's address (the upload path is added).
- Points go out about every 10 samples or 5 minutes while recording, and all that are waiting when you switch it on or tap **Send now**. Only points the connected radio recorded are sent, at most 500 at a time, each batch signed by the radio's key (`CMD_SIGN_START`/`_DATA`/`_FINISH`) over `corescope-coverage:` and the SHA-256 of the batch. The analyzer only takes radios it has heard, so send an advert first if it says it hasn't.
- What goes: each point's time, position, GPS accuracy and speed (so the analyzer can tell a walk from a drive), and each MediaMesh repeater that answered with its key, SNR both ways and the estimated margin.
- **Remove my points from the analyzer** asks it to delete every point that radio sent, and switches sharing off. The points on the phone stay.

The analyzer side is documented in CoreScope's `docs/mediamesh-coverage-points.md`.

### Per contact and per channel

Long-press a contact or channel and pick **Send on…**: *Auto* (follow the
settings above), *Main only*, *radio2 only*, *Both* or *Don't send*. Only
sending changes; the radio still hears both. The dialog shows where the next
message would go right now. An `#r2-` channel always uses radio2; rename it to
change that.

Everyone who shares photos and voice with you needs MediaMesh on, with the same
settings. A photo sent over MediaMesh can't be downloaded by a radio without it:
the announcement shows up on the main mesh, but the photo's packets don't.

### Public and #public

Photos, voice messages and push-to-talk are off on Public and `#public`. Those
are the channels everyone on the mesh shares, and photos and voice there show
up as clutter for everyone, including people on other apps. In those chats the
photo, voice and walkie-talkie buttons are dimmed; tapping one explains why and
shows the switch. It's also in **Settings > App Settings > Messaging** as
**Photos and voice on Public**, with a red warning to switch it on only in an
emergency. Like OTP, which Public refuses outright, the app refuses these sends
whatever started them (a pasted or forwarded photo too). Upstream's own image
messages, from other apps, aren't affected. Wadamesh TAK standalones have
the same switch, also off by default.

## What moves to MediaMesh

| Traffic | Where |
| --- | --- |
| Photo and voice packets (raw data, channel data `0x5643`) and their fetch requests | MediaMesh |
| Photo/voice announcements, `VR3:` fetch DMs, all messages | Main mesh |
| Team positions and other channel data | Main mesh |

The radio's firmware makes this choice for each packet; the app only turns
MediaMesh on and sets its frequency. Nothing changes in how photos and voice
are sent from the app.

## How a photo's missing packets are asked for

A listener missing packets asks for them, and the photo's sender answers with just those. Each answer is timed so it reaches far listeners and slows down only on a busy mesh. Two things make this quicker and easier to follow:

- **End of answer.** When the request goes on the channel, it says the listener can read *marked* packets. The answer's packets then count down how many are still to come. When the count reaches zero, the listener asks for anything still missing straight away. When the last packets are lost, it asks again once their time has passed, not after a fixed wait.
  - Raw (direct) requests and answers aren't marked. The radio's firmware picks radio2 for those by their first byte, and a new kind would go out on the main mesh.
  - Older apps and Wadamesh builds don't ask for marked packets, so they get them as before.
- **Timing in the log.** The transfer log (the ⓘ under a photo or voice message) shows:
  - for each request, how long the first packet took;
  - on a timeout, how long ago it asked and how far apart packets came;
  - on the sender, how long after the request it started, how long a busy MediaMesh held it back, and how long the whole answer took.

## Fast MediaMesh

**Fast MediaMesh** in **Settings → MediaMesh Settings**, under Map MediaMesh coverage (on by default), makes transfers on MediaMesh quicker, through repeaters especially:

- **Repair packets.** A repair packet is a mix of all of a photo's or clip's packets, so any listener missing *m* packets rebuilds them from any *m* repair packets (practically always *m* + 1). A request on the channel says the listener takes them. Whoever answers then sends that many fresh repair packets, plus a margin, instead of the specific packets. One answer mends every listener's gaps at once, whichever packets each one lacks, with far fewer requests on the air. A whole photo sent at once ends with about a tenth repair packets instead of the block parity.
- **Repair packets in a mixed group.** Data packets going out anyway, to a listener on an older app or standalone that asked for them, count towards the repair packets a listener with Fast MediaMesh is owed: it gets repair packets only for what no data packet carries, plus about a tenth of the rest, since a radio scanning radio2 misses some while it's on the main mesh. (In a field test, a listener lacking 221 packets that were all going out as data anyway got 144 repair packets on top; now it gets 24.)
- **Listeners missing most of a clip.** A request names at most 124 packets. A listener with Fast MediaMesh naming that many may lack more after the last one, so it gets those as data too, not repair packets: repair packets only mend once there are as many as it lacks.
- **Thumbnails come as the packets themselves.** A photo nobody has tapped yet still asks for its first two packets, which hold the thumbnail. That ask never takes repair packets: a repair packet only mends a listener that holds nearly all of the photo, and this one holds almost none of it. Before, the ask said it took repair packets, the sender answered with repair packets, and the thumbnail never came, three asks in a row. A sender also answers an ask for only those two packets with the packets themselves, whatever the ask says, so thumbnails come for listeners still on the older app too.
- **Repair packets sized for the losses.** The sender learns from listeners' requests how much of its last answers the worst-placed listener lost (up to 40%), and sizes repair packets for it: a whole pass ends with enough that listeners several hops away finish without asking again (each request round through repeaters costs a minute or more). With no loss seen, a pass ends with about a tenth, as before; a fifth lost, about 29%. The "asks for" log line says what loss they were sized for.
- **No asking again while the transfer is on the air.** A listener whose request times out while it still hears packets of the same transfer (another part of the same clip being sent to another listener, or this clip's repair or parity packets) waits for them to stop, up to 3 minutes after asking, before asking again. The sender answers one request after another, so asking again would only queue behind them; and every request floods the main mesh, where every repeater scanning radio2 misses radio2 packets while it relays one. Other photos and clips on the air don't hold a request. The log says "sender still on this transfer".
- **SuperMax parts asked for together.** Once a SuperMax clip's first part is in, the listener asks for every part still to come at once, so the sender goes straight from one part to the next instead of waiting for a request to cross the mesh after each (a minute or more through repeaters). Each part's gaps are still asked for on their own, and a part waiting while another is on the air holds its next request (above). Wadamesh TAK standalones don't fetch SuperMax clips, so this is the app's alone.
- **Everything through the repeaters on radio2.** Pushes and answers on MediaMesh are flooded through the MediaMesh repeaters, never sent zero-hop (to radios in range only). In a field test with every radio scanning radio2, zero-hop parts arrived with 41-46% of their packets against 91% for one flooded at the fast pace: a scanning radio misses packets while it's on the main mesh, and a repeater's copy is a second chance. A flooded push also reaches listeners repeaters away, so they don't have to ask.
- **A dropped connection keeps the radio2 settings.** The app keeps what the radio said about radio2 over a dropped Bluetooth connection, and asks again once reconnected. Before, a radio too busy to answer right after reconnecting left the app refusing every request ("it would go out on the main mesh") until it did.
- **Closer spacing through repeaters.** Packets flooded through repeaters start about 2.4 airtimes apart (about 0.8 s at 250 kHz) instead of 4 (1.5 s). As before, an answer that loses a third of its packets slows the spacing.
- **Timing in the log.** The sender's log line says how long the radio took to accept each packet, next to its airtime. The "photos and voice go on radio2" line gives the radio2 preamble the radio reported: a radio scanning radio2 sends a long one, so its packets take longer on the air, and every gap is spaced for that.

Wadamesh TAK standalones do the same (**Settings → MediaMesh → Fast MediaMesh**). Older apps and standalones still get every packet itself: they don't ask for repair packets, and they ignore any they hear.

**Adaptive spacing** (**Settings → MediaMesh Settings**, under Fast MediaMesh; on by default, needs Fast MediaMesh). The gap between an answer's packets learns from what listeners' requests say they lost, starting at the fast gap (2.4 airtimes and 150 ms: 517 ms at 153 ms a packet). Hop counts play no part: in a dense mesh a listener next door can be 3 hops away, and what limits the spacing is how many repeaters relay each packet.
- A listener lost under 3% of an answer: the gap goes down a tenth, to at most 1.6 airtimes and 150 ms (395 ms at 153 ms a packet).
- A listener lost 7 points more than it did at its widest recent gap (2% at 517 ms, 9% at 465, say): the spacing caused it, so the gap goes up a quarter (by half if it lost a third) and stays 10% above the gap that lost for 30 minutes.
- A listener that lost as much at a wider gap is on a poor link of its own: the gap stays, and repair packets sized for it cover it. A listener not heard from before that loses 10% puts the gap up a quarter (without the hold), since there's nothing yet to compare with.
- The gap runs from when a packet goes to the radio, so the time the radio takes to accept it over Bluetooth (often 150-320 ms) is part of the gap, not added to it. Before, a "517 ms" pace went out about 700 ms apart.
- Answers wait their turn, but a small one (40 packets or fewer: repair packets, a few missing packets) goes before bigger ones queued ahead of it, so a repair for one part of a clip doesn't wait minutes behind the push of the next part.
- The learnt gap is kept across restarts, per channel, and starts again when the radio2 settings change. The sender's log line says "N ms apart (adaptive)".

Switch it off for the spacing of the 2026-11-18 field test (a 3-part SuperMax in 10.0 minutes), kept as the branch `mediamesh-gold-2026-11-18` in this repo and in Wadamesh TAK.

**Rolling back.** Switch Fast MediaMesh off, on one phone or standalone or on all of them, and transfers work exactly as they did before. That covers the requests, the answers and the spacing. Phones and standalones with it on and off still work together. To take it out of the app altogether, revert the pull request that added it (and its Wadamesh TAK counterpart).

## Transfer test

The voice diagnostics sheet (ⓘ) has **Transfer test**: pick a contact or a channel and 3, 5 or 10 photos. The app sends a small test photo (Standard detail), waits for it to arrive, then sends the next, and shows:

- how many downloads completed, out of all the receivers' reports;
- the median, best and worst time from the announcement to the whole photo;
- the requests it took (each request after the first is a retry).

Receivers running this app fetch a test photo at once, whatever their auto-download settings, and answer with a hidden `VT1:` text (a DM for a contact test, on the channel for a channel test), which this app never shows in the chat. Older apps and other clients show the test photo as an ordinary photo, and the report as text. Each photo waits up to 3 minutes for its report; on a channel, until 30 seconds pass with no new report. The results are also written to the log.

## MediaMesh nearby

A small tower icon next to the radio-stats dot in the app bar and chat screens shows whether a MediaMesh is on the air where you are:

- **Lit** (accent color): radio2 heard a valid packet in the last 2 hours. The tooltip says how long ago.
- **Dim**: radio2 is listening, and nothing has been heard in the last 2 hours.
- **Faint**: the radio has MediaMesh but radio2 is off.
- **Hidden**: the radio has no MediaMesh (or no radio is connected), and nothing was heard recently.

Tap it to open MediaMesh Settings. It appears a few seconds after connecting, once the radio has answered.

The app asks the connected radio for `get radio2.status` once a minute. Wadamesh reports `heard=Ns` (seconds since the last valid radio2 packet), so packets the radio relays or that aren't for you count too. On other firmware, the app counts a rise in the radio2 receive count as heard. A photo or voice packet that reaches the app over radio2 lights the icon straight away. The time is saved, so the icon stays lit across an app restart until the 2 hours run out. A radio that doesn't answer three times in a row is asked every 10 minutes after that.

## Received via

Under a received photo or voice message, the app says how its packets reached your radio: **Received via MediaMesh**, **Received via main mesh**, or both. Wadamesh tells the app which radio each packet came in on (a byte in the frame, see the Wadamesh MEDIAMESH.md). keymindCascade doesn't yet, so with a Cascade companion that has radio2 on, the app shows nothing rather than guess. A radio without radio2 can only have used the main mesh, so that's what it shows.

## Firmware

MediaMesh needs radio firmware with a second LoRa profile and media routing:

- **Wadamesh** (jade-on-mesh/wadamesh-tak) on SX1262 boards: T-Deck, Heltec V4,
  T-LoRa Pager (SX1262) and others. LR1110/LR1121 boards can't run it. See
  Wadamesh's `MEDIAMESH.md`.
- **MeshCore with `radio2`** (mikecarper/MeshCore) has the second profile.
  Media routing needs its `tx.media` setting; without it the dialog says the
  firmware cannot route media yet.

Other firmware shows "This radio's firmware has no MediaMesh".

## How the app talks to the radio

The dialog uses the companion's local CLI frame (`CMD_RUN_CLI_COMMAND`, `0x42`,
answered by `RESP_CODE_CLI_REPLY`, 29) with these commands:

| Action | Commands |
| --- | --- |
| Read | `get radio2`, `get mediamesh`, `get tx.media`, `get radio2.cross`, `get radio2.status`, `get tempradio2` |
| Turn on | `set radio2 <MHz>,<kHz>,<sf>,<cr>,rx\|rxtx`, then for *Photos & voice* `set radio2.cross off` + `set tx.media radio2`, for *Everything* `set radio2.cross on` + `set tx.media auto` |
| Turn off | `set tx.media radio`, `set radio2 off` |
| Temporary | `set tempradio2 <MHz>,<kHz>,<sf>,<cr>,rxtx,<minutes>`, `set tempradio2 off` |
| Per contact | `get/set tx.user key:<32 hex> <auto\|radio\|radio2\|both\|off>` |
| Per channel | `get/set tx.channel <slot> <choice>` |

`set radio2.cross off` keeps MeshCore firmware from copying ordinary traffic
onto radio2.

Code: `lib/services/media_mesh.dart` (commands and parsing),
`lib/widgets/media_mesh_settings_dialog.dart` (dialog),
`lib/widgets/tx_route_dialog.dart` (Send on…),
`lib/screens/radio_console_screen.dart` (console),
`MeshCoreConnector.runLocalCliCommand`.

## Limits

- One radio, two frequencies: while it receives or sends on one, it can't hear
  the other. Heavy media traffic costs some main-mesh reception.
- MediaMesh packets use a longer preamble so a switching receiver catches them.
- The new strings are in `app_en.arb`; other languages show English until translated.
