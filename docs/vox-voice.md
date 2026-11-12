# VOX voice and photo messages

MeshCore Open TAK sends short voice clips over MeshCore using Codec2 and an
on-demand, pull-based transfer. Codec2 clips use the published VE3 wire
format, so other VE3 apps can exchange them.

## Code map

| File | Role |
| --- | --- |
| `lib/vox/voice_wire.dart` | Modes, `VE3` envelope, voice packet, fetch request, packetizer, airtime estimate |
| `lib/vox/voice_service.dart` | Outgoing cache, fetch/serve logic, retries, raw-frame handling |
| `lib/vox/voice_codec*.dart` | Codec2 entry point (FFI on native, stub on web) |
| `lib/services/codec2_ffi.dart` | Codec2 FFI binding |
| `lib/vox/voice_record_sheet.dart` | Record / Play / Discard / Send sheet and mic button |
| `lib/vox/voice_message_bubble.dart` | Voice bubble: download, progress, playback |
| `lib/vox/voice_clip_store*.dart` | On-disk cache of complete clips |
| `lib/vox/video_codec.dart`, `video_prep.dart`, `video_send_sheet.dart`, `video_message_bubble.dart`, `video_player.dart`, `video_source.dart`, `vox_interp.dart` | Video messages: payload and fitting, clean-up, send sheet, bubble, player with AI views, reading a picked clip, Smooth motion |
| `third_party/codec2`, `android/app/src/main/cpp` | Vendored Codec2 and its Android build |

## Codecs

- **Mimi** (default once its model is downloaded): Kyutai's neural codec,
  8 codebooks × 11 bits at 12.5 frames/s, so 11 bytes per 80 ms frame,
  about 1.1 kb/s at 24 kHz audio. Announced with `VM1:` (same fields as
  `VE3:`, mode id 32 = `w`). VOX only. Packets carry 14 frames (154 bytes).
  The ONNX encoder/decoder (fixed 20 s, fp16-stored weights, ~223 MB) come
  from this repo's `mimi-onnx-v1` release and are verified by SHA-256.
  Built by `.github/workflows/vox-mimi-release.yml`.
- **Codec2 1200** (fallback, and for other VE3 apps): `VE3:`.

The recorder captures 48 kHz and decimates to 24 kHz (Mimi) or 8 kHz (Codec2).
Voice settings has a toggle to keep sending Codec2 even with Mimi installed.

### Codec2 copies for standalones

A standalone (Wadamesh) can't play Mimi, so it asks the sender for a Codec2
copy instead. It fetches a session id derived from the Mimi clip's:

```
copy sid = mimi sid XOR (0xC2C20000 | durS)
```

- **What the copy is.** Always Codec2 1200, exactly `durS` seconds long
  (`durS` from the Mimi envelope), so both sides know it has
  `ceil(durS * 150 / 156)` packets. No second envelope is sent.
- **Sender.** The app keeps a list of its own Mimi clips across restarts.
  The first time a copy is asked for, it decodes the Mimi clip, re-encodes it
  and stores it under the copy's id. It then serves the copy like any other
  clip, in the DM or on the channel.
- **Waiting.** If the Mimi clip is being sent from this phone, or its packets
  were heard on the channel in the last few seconds, the copy waits until that
  goes quiet.
- **Standalone.** In a DM it asks for the copy as soon as the Mimi message
  arrives. On a channel it asks only when you tap **get as Codec2**, and keeps
  a copy someone else asked for as it goes by. While the sender waits for a
  Mimi transfer, the bubble says "Codec2 waiting for Mimi transfer to
  finish".
- **Older apps.** An app without this has no clip under that id and sends
  nothing.

## Wire formats

### Envelope (normal text message, DM or channel)

```
VE3:{sid}:{mode}:{total}:{durS}
```

All four fields are lowercase base36.

- `sid`: 32-bit session id (held internally as 8 hex chars, big-endian)
- `mode`: wire mode id: 0 = 700C, 1 = 1200, 2 = 2400, 3 = 1300, 4 = 1400, 5 = 1600, 6 = 3200. VOX sends 1200.
- `total`: packet count, 1 to 255
- `durS`: duration in whole seconds (rounded up)

### Voice packet (raw data, direct path)

```
[0x56][sid:4][index:1][codec2 frames...]
```

At 1200 bps each packet carries 26 frames (1040 ms, 156 bytes), so a packet
is 162 bytes on the raw-data plane.

### Fetch request (raw data, direct path)

```
[0x72][sid:4][flags:1][requesterKey6:6][count:1][indices...]
```

- `flags & 0x01` = only the listed `indices` are wanted; otherwise all.
- `requesterKey6` = first 6 bytes of the requester's public key. The sender
  uses it to find the contact and its direct route for the reply.
- `flags & 0x04` = `[path_len][path...]` follows `indices`: the route the
  requester used, which the sender reverses (hop by hop) to reply. `path_len`
  is encoded as on air (hash size - 1 in the top two bits, hop count below),
  so for 1-byte hashes it is the byte count.

### Companion protocol frames used

- `CMD_SEND_RAW_DATA` (25): `[25][path_len][path...][payload]`. Direct only;
  firmware replies `RESP_CODE_OK`. `path_len` carries the hash size like a
  contact path, so routes with 1-, 2- or 3-byte path hashes all work.
- `PUSH_CODE_RAW_DATA` (0x84): `[0x84][snr*4][rssi][0xFF][payload]`.

## Behaviour

- **Sending.** Encode, packetize, save the clip on the phone (it survives
  restarts), send only the envelope.
- **Listening.** Tap the bubble. The app picks the cheapest transport that can
  work and escalates on timeouts (up to 5 attempts):
  1. **Direct**: the sender is a contact with a known route, so a binary
     fetch request goes over raw data and the packets come back the same way.
  2. **`VR3:` DM**: the sender is a contact but there's no route. A silent
     text request (`VR3:{sid}:{a|m<ranges>}:{key6}`, VE3's text form) is
     flooded as a DM. Its ACK path exchange gives both radios a direct
     route, and the sender replies over raw data. VR3 DMs are never shown in
     the chat.
  3. **Channel fallback**: the sender isn't a contact (channel messages only
     carry a name), or direct attempts failed. The binary request and the
     packets are flooded as GRP_DATA (data type `0x5643`) on the channel the
     envelope was posted in. Every VOX listener on that channel keeps the
     packets, so one transfer serves everyone who taps the clip. The original
     sender answers at once; anyone else holding the clip only answers if
     nobody has started within 5 to 8 s. Needs companion firmware with channel
     data (v1.15+).
- **Pacing.** Direct packets are about 2× a packet's airtime apart, and channel
  packets about 4× (min 400 ms / 800 ms), based on the radio's current SF/BW/CR.
- **Lost answers.** The first packet of an answer goes out while the request
  may still be relayed around the listener, and is the one most often lost.
  So the sender adds a second copy (salted, so repeaters don't drop it) in
  these cases:
  - the first packet of every relayed answer, sent again at the end;
  - a packet the same listener asks for again, sent twice (at most 4 such
    packets per answer).
  - **Why it pays:** each copy costs one packet gap, while a lost packet costs a
    round of asking again.
  - **Slowing down:** after 4 asks for the same clip within 10 minutes, a
    listener is answered at most once a minute.
- **Playback.** One shared player. While a clip decodes (Mimi takes a few
  seconds) the button shows a spinning accent-coloured ring; while it plays
  the ring fills with progress around a stop button. Completed clips are
  decoded in the background and the last few decoded clips are cached, so a
  tap usually plays at once. The recorder decodes its preview right after
  encoding.
- **Auto-play** (Voice settings, on by default). New incoming voice DMs are
  downloaded and played as they arrive, one after another, never while the
  recorder is open, and not for a backlog older than 15 minutes. In channels,
  clips only auto-play if they reach the phone anyway, unless **Also
  auto-download in channels** is on (every listener then pulls its own copy).
- **Channel senders** are matched to contacts by name (case and emoji
  variation selectors ignored).

## Photo messages

Photos ride the same on-demand transport as voice (direct, through
repeaters, channel fallback, salted resends). They're announced with `VI1:`
(same fields as `VE3:`, mode id 40 = `14`, and the last field is the aspect
ratio, width × 100 / height). Android only.

- **Codec.** A single AV1 key frame (libaom, reduced still-picture header,
  4:2:0, tuned for SSIM) sent as raw OBUs with no AVIF container, so every
  byte is picture data. Payload: `[0x01 version][OBUs]`. Native code:
  `android/app/src/main/cpp/vox_av1.c`; CI builds libaom from the source
  mirrored on the `deps-cache` branch.
- **Budget.** Standard is one full voice message (2,750 B, 18 packets);
  More detail is 2× (36 packets).
- **Fitting.** The sending phone scales the photo to at most 768 px, then
  searches sizes and quantizers for the best-scoring encode within the
  budget. The preview is the decoded result, so the sender sees exactly what
  the receiver will.
- **Focus.** Two small bundled detectors (YuNet faces, PP-OCRv3 text, see
  `assets/vox/LICENSES.md`) mark text and faces. Everything else is softened
  slightly before encoding so the bytes go where they matter. Nothing is
  generated: every pixel comes from the photo.
- **Small-text check.** When detected text scores poorly at the chosen
  detail, the sheet suggests More detail.
- **Receiving** follows the auto-play setting: new photo DMs download on
  arrival; channel photos download on tap unless channel auto-download is on.

## Video messages

Short clips ride the same transport as photos, with the same budgets, so a
video never costs more airtime than a Super Sharp photo. They're announced
with `VV1:` (same fields as `VE3:`, mode id 41 = `15`, the last field is the
clip's length in seconds), then the word `VIDEO` and any caption. Sent from
Android and iPhone (record or pick) and Windows, macOS and Linux (pick a
file: Media Foundation, AVFoundation and the `ffmpeg` program read it);
played wherever photos show.

- **Codec.** One AV1 sequence (libaom good-quality mode, a key frame then
  inter frames, constant quantizer), 4:2:0 like the photos. Each encoder
  packet is stored as a LEB128 length and its OBUs, temporal delimiter
  removed. Native code: `vox_av1_clip_encode` / `vox_av1_clip_decode` in
  `third_party/vox_av1/vox_av1.c`.
- **Payload** (version 3, `lib/vox/video_codec.dart`):
  `[3][thumb len][thumb][w:2][h:2][fps][frames:2][ms:2][sound mode][sound len:2][sound][video]`.
  The thumbnail is the first frame as a photo thumbnail, in the same place, so
  bubbles show it from the first two packets exactly as for photos. The
  sound is a voice message's bits (Mimi or Codec2, `sound mode` is its wire
  id, 255 for none).
- **Budgets.** Quick 11 KB (71 packets, 6 s), Clear 22 KB (141 packets,
  10 s), Max 38.5 KB (247 packets, 15 s: Super Sharp). A longer clip sends
  its start.
- **Fitting.** The sound comes off the top of the budget. The frame size and
  rate are the most pixels per second that still get 0.12 bits per pixel
  (from 96 px at 6 fps up to 256 px at 12 fps), then the quantizer is found
  by bisection at speed 6 and re-encoded at speed 4. A 10 s clip at Max comes
  out about 160×120 at 12 fps. The preview is the decoded result.
- **Reading the clip.** Android (`VoxVideoChannel.kt`): frames through
  `MediaMetadataRetriever` (in order, a few at a time, on Android 9+), sound
  through `MediaExtractor`/`MediaCodec` to 48 kHz mono. iPhone
  (`MeshVideoReader` in `ios/Runner/AppDelegate.swift`): frames through
  `AVAssetImageGenerator` in one batch (upright, SDR), sound through
  `AVAssetReader`, which resamples to 48 kHz mono itself.
- **Clean-up before encoding** (`lib/vox/video_prep.dart`, pure Dart). Steady:
  whole-frame shifts measured coarse to fine (quarter then half resolution),
  the path smoothed with a half-second Gaussian, each frame cropped (at most
  6% a side) to follow it and scaled back. Clean: each pixel averaged with the
  two frames either side, weighted by how alike their 3×3 neighbourhoods are
  against the estimated grain. Faces and text, found on the first, middle and
  last frames, keep their detail while the rest is softened, as for photos.
  AV1's own film grain synthesis was tried and dropped: libaom sends the grain
  parameters with every frame, which made these small clips 45–135% bigger.
- **AI views when watching** (display only): Smooth motion
  (`lib/vox/vox_interp.dart`, RIFE 4.9 as ONNX from the `interp-onnx-v1`
  release built by `.github/workflows/interp-model.yml`) and Enhance
  (`VoxUpscaler.enhanceClip`, the photo enhancer at 2x). Switches in the
  full-screen player, remembered, never downloading by themselves; with
  Enhance on, Smooth motion keeps the clip to 240 frames.
- **Not on Wadamesh.** Standalone radios show the envelope as text.

## Testing: force voice through repeaters

Two devices on a desk will always talk directly. To exercise real repeater
paths, open **Voice settings** (record sheet) or the ⓘ on any voice bubble
and turn on **Force voice through repeaters**, then pick one or more repeaters
in order.

- Requests are sent with that path; replies use the reverse order. This
  works because a radio drops a direct packet that isn't addressed to it as
  the next hop, so the listener only accepts the copy the last repeater
  re-sends.
- While it's on, every fetch uses raw data along the forced path. The DM and
  channel fallbacks are skipped, and the sender doesn't even need to be a
  contact.
- Turn it on, with the same repeaters, on **both** devices: the sender uses
  its own setting to reply.
- The diagnostics log marks these transfers `(FORCED)`, with the path bytes.

## Not yet implemented

- Swarm recovery (`0x6d`); the channel fallback covers a similar need
- Desktop: Linux needs a system `libcodec2`; macOS and Windows don't ship
  Codec2 yet, so voice is hidden there
