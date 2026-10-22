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
3. Pick a **Preset**, or set the **radio2 frequency**, **Bandwidth**,
   **Spreading factor** and **Coding rate** yourself:
   - **250 kHz · fast** (the default): 911.150 MHz, 250 kHz, SF7, 4/5. About
     four times as fast as SF7/62.5, for roughly 6 dB less range.
   - **125 kHz · range**: the same at 125 kHz. About half the speed of the fast
     preset and roughly 40% farther.

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
3. About 9 seconds later, the same on *125 kHz · range*.
4. `set tempradio2 off` brings the saved radio2 back, and the preset that heard
   packets is offered (a tie goes to 250 kHz).

It needs a MediaMesh repeater in direct range. Repeaters answer at most four
discovery requests every two minutes (asking uses one, listening two more), so
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
people's requests for them either. This covers Open TAK's photos and voice
only: upstream MeshCore Open's channel image messages and OTP photo DMs (sent
direct, never flooded) are unchanged.

**Temporary radio2** tries the profile in the form for 15 minutes, 1 hour or
2 hours without saving it (`tempradio2`); **Stop** brings the saved radio2 back.
A reboot ends it too.

**Radio console** (at the bottom of the dialog) runs any radio command and
keeps a history: schedules (`radioat2`, `tempradioat2`), `tempradio`,
`normalradio`, `get radio2.timing` and the rest of Wadamesh's `MEDIAMESH.md`.

### Per contact and per channel

Long-press a contact or channel and pick **Send on…**: *Auto* (follow the
settings above), *Main only*, *radio2 only*, *Both* or *Don't send*. Only
sending changes; the radio still hears both. The dialog shows where the next
message would go right now. An `#r2-` channel always uses radio2; rename it to
change that.

Everyone who shares photos and voice with you needs MediaMesh on, with the same
settings. A photo sent over MediaMesh can't be downloaded by a radio without it:
the announcement shows up on the main mesh, but the photo's packets don't.

## What moves to MediaMesh

| Traffic | Where |
| --- | --- |
| Photo and voice packets (raw data, channel data `0x5643`) and their fetch requests | MediaMesh |
| Photo/voice announcements, `VR3:` fetch DMs, all messages | Main mesh |
| Team positions and other channel data | Main mesh |

The radio's firmware makes this choice for each packet; the app only turns
MediaMesh on and sets its frequency. Nothing changes in how photos and voice
are sent from the app.

## MediaMesh nearby

A small tower icon next to the radio-stats dot in the app bar and chat screens shows whether a MediaMesh is on the air where you are:

- **Lit** (accent color): radio2 heard a valid packet in the last 2 hours. The tooltip says how long ago.
- **Dim**: radio2 is listening, and nothing has been heard in the last 2 hours.
- **Faint**: the radio has MediaMesh but radio2 is off.
- **Hidden**: the radio has no MediaMesh (or no radio is connected), and nothing was heard recently.

Tap it to open MediaMesh Settings. It appears a few seconds after connecting, once the radio has answered.

The app asks the connected radio for `get radio2.status` once a minute. Wadamesh reports `heard=Ns` (seconds since the last valid radio2 packet), so packets the radio relays or that aren't for you count too. On other firmware, the app counts a rise in the radio2 receive count as heard. A photo or voice packet that reaches the app over radio2 lights the icon straight away. The time is saved, so the icon stays lit across an app restart until the 2 hours run out. A radio that doesn't answer three times in a row is asked every 10 minutes after that.

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
