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
| Trace | Along its route, up to the first repeater it hasn't reached; the rest of the route as faint dashes (see [Traces](#traces)). |

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
| Inferred hop | `#94A3B8` grey dot, dashed lines |
| MediaMesh (radio2) | `#D946EF` light / `#E879F9` dark, hollow rings |

## MediaMesh (radio2)

A companion on Keymind Cascade firmware hears radio2 too, and marks each packet it heard there: a `[0x92][0xA1]` frame just before the RX log frame, which stays unchanged (`LiveTrafficFrameReader` pairs them). Those packets are drawn like the analyzer draws MediaMesh traffic:

- hollow rings every 12 px along each hop instead of the line (radius 3.5, 1.6 px; at most 40 a hop and 200 a path), in fuchsia: `#D946EF` in the light theme, `#E879F9` in the dark one;
- a fainter contrail (15 %) and a glowing ring as the head;
- the hop's number in a small badge on the fading copy;
- a **trace on radio2** (the coverage pings, and any other trace sent there): three rings ripple out at each repeater it reached, with a label giving the SNR that repeater heard it at ("+4.5 dB on radio2").

Lines to and from inferred hops stay grey and dashed, as in the analyzer. Other companion firmware sends no marker, so everything it hears is drawn as the main mesh.

### The map's MediaMesh filter

With the filter sheet's **MediaMesh** switch on, only radio2 traffic runs. If the Repeaters and Companions switches are both on too, main-mesh traffic still runs, at 15 %. See [Map & Location](map-and-location.md#filter-dialog-fab).

### Traces

A trace runs up to the first repeater it hasn't reached yet. The rest of its route shows as faint dashes in the trace colour for 10 seconds, with a faint dot on any inferred repeater there.

## Code

- `lib/services/live_traffic.dart`: `LiveTrafficSettings` (the switch), `LiveTrafficFrameReader` (the radio2 marker), `parseLiveTrafficFrame`, the type names and colours, and `liveTrafficRoute` (where a packet is drawn).
- `lib/widgets/live_traffic_layer.dart`: `LiveTrafficLayer` (a `Ticker` and `CustomPainter` in the map's children, listening to `MeshCoreConnector.receivedFrames` while it's shown), `LiveTrafficButton` and `showLiveTrafficLegend`.
