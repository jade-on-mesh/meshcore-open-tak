# VOX voice and photo messages

MeshCore Open VOX sends short voice clips over MeshCore using Codec2 and an
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

### Companion protocol frames used

- `CMD_SEND_RAW_DATA` (25): `[25][path_len][path...][payload]`. Direct only;
  firmware replies `RESP_CODE_OK`.
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
- Raw data over multi-byte path hashes (firmware limitation)
- Desktop: Linux needs a system `libcodec2`; macOS and Windows don't ship
  Codec2 yet, so voice is hidden there
