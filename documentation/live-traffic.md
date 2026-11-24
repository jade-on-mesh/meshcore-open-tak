# Live traffic on the map

Every packet your companion radio hears can run across the map as it arrives, drawn the way the CoreScope analyzer's live map draws it: the same colours for each packet type, the same moving dot, contrail, fading line and pulses.

## Turning it on

Either switch does it, and they stay in step:

- **The map**: the broadcast button (podcast icon) above the filter button. Filled while live traffic shows. Turning it on shows a hint with a **Colours** button for the legend.
- **App Settings › Map display › Live traffic**. Under it, **Colours** opens the legend.

It's off until you turn it on, and it's remembered on this phone. Nothing is sent: the app only draws what the radio already reports in its RX log (push `0x88`).

## What you see

Each packet runs hop by hop, 660 ms a hop:

- a soft 6 px contrail and a 2 px line in the packet type's colour grow behind a white dot ringed in that colour;
- each point it passes pulses: a thin ring that grows fast and fades, and a thicker highlight ring;
- a finished hop stays as a line that fades out in about half a second; the last five are kept;
- at most 20 packets run at once; more are skipped.

Where it runs:

| Packet | Path drawn |
|---|---|
| Flooded | The repeaters in its path (resolved from the companion backward, like received paths elsewhere in the app), then **your radio**, which heard it. An advert with a location starts at its sender. |
| Direct | A pulse at your radio only: a direct packet's path is the hops still to go, not the ones it came through. |
| Trace | Along its route. Lines to repeaters that passed it on are solid; the rest are grey dashes. |

A repeater in the path that has no location (or isn't a contact) is placed evenly between the known points on either side of it, as a small grey dot, and the lines to and from it are grey dashes (CoreScope's "Inferred Hops"). One outside any known points is left out. Your radio needs a location for packets to end at it.

## Colours

The same as CoreScope's `TYPE_COLORS`:

| Type | Colour |
|---|---|
| Advert | `#22C55E` green |
| Channel message | `#3B82F6` blue |
| Direct message | `#F59E0B` amber |
| Acknowledgement | `#6B7280` grey |
| Request | `#A855F7` purple |
| Response | `#06B6D4` cyan |
| Trace | `#EC4899` pink |
| Path | `#14B8A6` teal |
| Anonymous request | `#F43F5E` rose |
| Group data (photos, voice) | `#8B5CF6` violet |
| Multipart | `#0D9488` dark teal |
| Control | `#B45309` brown |
| Raw custom | `#C026D3` fuchsia |
| Inferred hop / unreached trace hop | `#94A3B8` grey, dashed |

CoreScope's MediaMesh styles (hollow rings, radio2 trace sonar) aren't used: the companion's RX log reports the main mesh only, so nothing it hears is carried on radio2.

## Code

- `lib/services/live_traffic.dart`: `LiveTrafficSettings` (the switch), `parseLiveTrafficFrame`, the type names and colours, and `liveTrafficRoute` (where a packet is drawn).
- `lib/widgets/live_traffic_layer.dart`: `LiveTrafficLayer` (a `Ticker` and `CustomPainter` in the map's children, listening to `MeshCoreConnector.receivedFrames` while it's shown), `LiveTrafficButton` and `showLiveTrafficLegend`.
