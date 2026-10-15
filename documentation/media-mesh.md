# MediaMesh

MediaMesh sends and receives photos and voice clips on a second LoRa frequency
of the connected radio, called `radio2`. Text, adverts, ACKs, team positions and
everything else stay on the main mesh. One radio listens to both frequencies by
switching between them, so you keep hearing the main mesh.

## Setting it up

**Settings → MediaMesh Settings** (under Radio Settings):

1. **radio2**: *Off*, *Listen* (hear radio2, never send there) or
   *Listen + send*.
2. **Sent on radio2**: *Photos & voice* puts only photos and voice clips there;
   *Everything* also copies messages onto radio2 so radio2-only nodes hear
   them. A mix set from the console shows as *Custom* and is left alone.
3. Set the **radio2 frequency**, **Bandwidth**, **Spreading factor** and
   **Coding rate**. The default is 911.500 MHz, 250 kHz, SF7, 4/5: about four
   times faster than SF7/62.5, for roughly 6 dB less range. It must differ from
   the main radio.
4. **Save**. The settings live on the radio, so they also apply when you are not
   connected (for example a Wadamesh radio fetching a photo by itself).

The dialog also shows, every few seconds while it is open: packets received and
sent on each profile, the measured switch time, and the radio's timing warnings.

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

## Firmware

MediaMesh needs radio firmware with a second LoRa profile and media routing:

- **Wadamesh** (jade-on-mesh/wadamesh) on SX1262 boards: T-Deck, Heltec V4,
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
