# VOX voice messages

MeshCore Open VOX sends short voice clips over MeshCore using Codec2 and an
on-demand, pull-based transfer. The wire format follows MeshCore SAR's
published design so clips can be exchanged with SAR users.

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

- **Sending.** Encode, packetize, cache for 15 minutes, send only the envelope.
- **Listening.** Tap the bubble. The app sends a fetch request (all packets
  first, then only missing ones). A watchdog re-requests twice if packets stop
  arriving. When the clip completes it auto-plays and is saved, so it replays
  offline.
- **Serving.** Requests are deduplicated (5 s) and served one at a time,
  paced at roughly 2× a packet's airtime for the current radio settings
  (minimum 400 ms). Clips we have fully received can be served onward too.
- **Channels.** Channel messages carry only a sender name, so the bubble
  resolves the sender to a chat contact by name. If the sender is not a
  contact, the bubble says so.

## Not yet implemented

- SAR's swarm recovery (`0x6d` requests to other peers for missing packets)
- Serving outgoing clips again after an app restart
- Raw data over multi-byte path hashes (firmware limitation)
- Desktop: Linux needs a system `libcodec2`; macOS and Windows don't ship
  Codec2 yet, so voice is hidden there
