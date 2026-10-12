# MeshCore ATAK plugin

Puts an ATAK team on a [MeshCore](https://meshcore.co.uk) LoRa mesh, the way
the [Meshtastic ATAK plugin](https://meshtastic.org/docs/software/integrations/integrations-atak-plugin/)
does for Meshtastic. It speaks the same team format as MeshCore Open TAK, so
ATAK users and MeshCore Open TAK users see each other.

| From ATAK | On the mesh |
|---|---|
| Your position (PLI), callsign, team colour, role, battery | Team position beacon, smart-beaconed (often when moving, rarely when still) |
| GeoChat **All Chat Rooms** | Text on the team channel (readable in any MeshCore app) |
| GeoChat to a mesh contact | MeshCore direct message |
| Spot markers, waypoints, 2525 units, SPIs you *send* | Compact point (`0x43`), CoT type, icon and colour kept |
| Lines, polygons, rectangles, circles, routes you *send* | Compact shape (`0x47`), delta-encoded; simplified to fit one packet |
| 911 / In Contact / Ring the Bell / Geo-fence alerts | Team alert (repeated), SOS flag on your beacon until cancelled |
| Anything else you send (casevac/9-line, ranges…) | Whole CoT, compressed and chunked (`0x58`), up to 6 packets by default |
| Photos (pane), photo on a marker | AV1 still, VI1 envelope, fetched on demand |
| Push-to-talk (pane) | Mimi (~1.1 kb/s) or Codec2 1200 clip, VM1/VE3 envelope, fetched on demand |
| Small files (pane, ≤ ~4 KB compressed) | Chunked transfer; data packages, KML and GPX are imported on arrival |

Everything from the mesh appears in ATAK as ordinary CoT: teammates as
friendly units you can chat with, MeshCore Open TAK pins and SALUTE reports,
shared shapes and routes, alerts, chat in GeoChat.

A mesh icon sits in the map's bottom-right corner: **green** ready, **amber**
connecting or missing a team channel, **red** link error, **grey** off. Tap it
(or the MeshCore toolbar button) for the pane.

## Two ways to reach the radio

**App mode (recommended).** Install [MeshCore Open TAK](../README.md) on the
same phone, connect it to your radio and turn on team mode with a private team
channel. The plugin binds to the app's bridge service (only ATAK is allowed
to), so the app keeps the BLE/USB connection, beacons your position with your
ATAK callsign, and does all voice and photo encoding (Mimi, Codec2, AV1). The
bridge can be turned off in the app: Team → TAK interop → *ATAK plugin on this
phone*.

**Direct mode.** No app needed: the plugin talks the MeshCore companion
protocol itself, over Bluetooth (Nordic UART) or USB serial (CDC-ACM, CP210x,
CH34x). Pick the radio in the pane, then pick a *private* team channel (public
and #hashtag channels would broadcast positions to strangers). Codec2 voice is
built in; Mimi needs its model (≈223 MB, downloaded from this repo's
`mimi-onnx-v1` release when you long-press the Mimi line in the pane); photos
need libaom built in (see below).

**Auto** (the default) uses the app when it's installed, else the USB or
Bluetooth radio you picked.

Radios need companion firmware 1.15 or newer (channel data, ver code 11).

## Building

ATAK only loads plugins built against its version. This project targets
**ATAK-CIV 5.8.0** (its sources are checked against the 5.8.0.5 SDK from
tak.gov, which can't be committed here). Install the matching ATAK on the phone: the
SDK's `atak.apk` is one.

1. Unpack the SDK and the Gradle wrapper. Pass the SDK `.zip` or the
   unpacked `ATAK-CIV-5.8.0.5-SDK` folder (if you have it as a `.7z`,
   extract that with 7-Zip first):

   ```bash
   cd atak-plugin
   scripts/setup-sdk.sh ~/Downloads/ATAK-CIV-5.8.0.5-SDK.zip
   ```

   This copies the SDK (minus its 400 MB `atak.apk`) to `sdk/atak-civ` and
   writes `local.properties`: set `sdk.dir` to your Android SDK if it says
   `/path/to/Android/sdk`. Debug builds are signed with the SDK's
   development key, which ATAK accepts.
2. Optional, for direct-mode photos: build libaom for Android once
   (`ANDROID_NDK_HOME=<sdk>/ndk/29.0.14206865 scripts/build-libaom.sh arm64-v8a armeabi-v7a`).
   Without it the plugin builds fine; direct mode just can't encode or show
   photos (app mode still can).
3. Build and install:

   ```bash
   ./gradlew assembleCivDebug
   adb install -r app/build/outputs/apk/civ/debug/ATAK-Plugin-MeshCore-*.apk
   ```

   Then in ATAK: Settings → Tool Preferences → Plugins (or the Plugins tool),
   load *MeshCore*.

Options: `-PwithMimi=false` leaves out ONNX Runtime (smaller APK; no Mimi in
direct mode).

Toolchain (the 5.8 template's): JDK 17, Android Gradle plugin 8.13, Gradle
8.14.3 (the wrapper downloads it), compileSdk 36, plus NDK 29.0.14206865 and
CMake 3.22.1 for the codecs. Android Studio's SDK Manager installs these.

**Building on GitHub instead.** The `ATAK plugin` workflow's *Plugin APK*
job builds and tests the APK (with libaom for direct-mode photos) and uploads
it as an artifact. Because this repo is public and the SDK may not be
redistributed, it runs only when the repo has an `ATAK_SDK_URL` secret: put
the SDK `.zip` somewhere private (for example a release asset in a private
repo, using its API asset URL) and, if that needs auth, add an
`ATAK_SDK_TOKEN` secret that can read it. Without the secret the job is
skipped.

**Other ATAK versions.** Run `setup-sdk.sh` with that version's SDK (it
handles the 4.x and 5.x layouts and warns on a mismatch), set `ATAK_VERSION`
in `app/build.gradle`, and follow that SDK's `samples/plugintemplate` for
Gradle and Android plugin versions. ATAK 4.x needs the older 4.x entry point
(`transapps` Lifecycle/ToolDescriptor in `plugin.xml`), which this branch no
longer carries; see the git history before the 5.8 port.

## Using it

1. Pick the link (Auto/App/Bluetooth/USB) and, in direct mode, the radio and
   the team channel.
2. Your position goes out on its own. *Share my position* and the *My status*
   buttons (OK, Busy, Need help, Returning, Resting) are in the pane.
3. Chat in GeoChat as usual. All Chat Rooms ↔ the team channel; a direct chat
   with a mesh contact goes as a MeshCore DM (they must be in the radio's
   contacts).
4. To share a marker, shape or route, use ATAK's normal **Send** on it. Only
   items you send are shared.
5. Voice: hold *Hold to talk* in the pane. *To…* picks the team channel or a
   contact. Received clips show in the pane and (for DMs) play as they arrive.
6. Photos: *Send photo…* picks a recent photo; *Photo on a map item…* then
   asks you to tap the marker and shares the marker with the photo attached
   (it lands in that marker's attachments on other ATAKs once fetched).

Airtime is precious: positions are smart-beaconed, photos and clips are only
pulled by people who open them, and big CoT is refused rather than flooding
the mesh. The log in the pane shows what went out.

## How it fits together

```
ATAK ──PreSendProcessor──▶ MeshTakEngine ──▶ MeshRadio ──┬─ AppRadio ── Messenger ──▶ MeshCore Open TAK (TakBridgeService → Dart)
  ▲                         │    ▲              │           └─ DirectRadio ── BleTransport / UsbTransport ──▶ radio
  └── internal dispatch ◀───┘    └── MediaBackend: AppMedia (app codecs) / LocalMedia (Codec2, AV1, Mimi + VE3 fetch/serve)
```

- `core/`: pure Java, unit-tested on the JDK: companion frames, the team wire
  format (shared with `lib/team/team_wire.dart` and `team_wire_atak.dart`, with
  byte-for-byte test vectors on both sides), voice envelopes, CoT conversion.
- `radio/`: the two link types and the bridge protocol.
- `media/`: voice and photos; `LocalMedia` is a port of the app's VE3
  fetch/serve so either side can fetch the other's clips.
- `tak/AtakBridge`: PreSendProcessor in, `CotMapComponent` internal dispatch
  out. Mesh items use the same uids as the app's TAK gateway (`VOX-<key4>`,
  `VOX-M-…`, `VOX-C-…`, `VOX-G-…`), so running both never duplicates.

Tests: `./gradlew testCivDebugUnitTest`, or without the SDK, the
`ATAK plugin` GitHub workflow (compiles and runs the core tests with plain
`javac`).

## Limitations

- Built against ATAK-CIV 5.8.0; other ATAK versions need a rebuild with their
  SDK.
- Direct-mode raw-data voice/photo transfers need 1-byte path hashes (a
  firmware limit); clips still arrive over the team channel otherwise.
- Shapes with many vertices are simplified to fit one packet (a toast says so).
- Mesh contacts can only be messaged if they're in the radio's contact list.
- One radio, one team channel at a time.
