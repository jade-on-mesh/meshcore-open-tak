# MediaMesh

MediaMesh sends and receives photos and voice clips on a second LoRa frequency
of the connected radio, called `radio2`. Text, adverts, ACKs, team positions and
everything else stay on the main mesh. One radio listens to both frequencies by
switching between them, so you keep hearing the main mesh.

## Setting it up

**Settings → MediaMesh Settings** (under Radio Settings):

1. Turn on **Photos & voice on MediaMesh**.
2. Set the **MediaMesh frequency**, **Bandwidth**, **Spreading factor** and
   **Coding rate**. The default is 911.500 MHz, 250 kHz, SF7, 4/5: about four
   times faster than SF7/62.5, for roughly 6 dB less range. It must differ from
   the main radio.
3. **Save**. The settings live on the radio, so they also apply when you are not
   connected (for example a Wadamesh radio fetching a photo by itself).

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
| Read | `get radio2`, `get mediamesh`, `get tx.media` |
| Turn on | `set radio2 <MHz>,<kHz>,<sf>,<cr>,rxtx`, `set radio2.cross off`, `set tx.media radio2` |
| Turn off | `set tx.media radio`, `set radio2 off` |

`set radio2.cross off` keeps MeshCore firmware from copying ordinary traffic
onto radio2.

Code: `lib/services/media_mesh.dart` (commands and parsing),
`lib/widgets/media_mesh_settings_dialog.dart` (dialog),
`MeshCoreConnector.runLocalCliCommand`.

## Limits

- One radio, two frequencies: while it receives or sends on one, it can't hear
  the other. Heavy media traffic costs some main-mesh reception.
- MediaMesh packets use a longer preamble so a switching receiver catches them.
- The dialog text is English only for now.
