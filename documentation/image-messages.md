# Image Messages

MeshCore Open can send a highly compressed image as channel GRP_DATA packets. Unlike a GIF reference or URL preview, the compressed image bytes travel over the mesh. A compatible recipient reconstructs them locally using the image model.

## Requirements and setup

- Companion firmware version code **11 or later** (identified in the connector as v1.15.0) for the current channel-data layout.
- A native runtime with a working ONNX backend. The web build has no image codec backend.
- The image model bundle installed through App Settings → Image model, and Enable image messages turned on.
- Enough storage for the roughly 1 GB bundle and enough available memory for reconstruction, which can peak above 2 GB. Actual latency and memory usage depend on hardware.

Downloads use the configured Hugging Face model bundle, support resume, and verify file checksums. Download the model while internet is available. Once installed, encoding and reconstruction run locally; photos are not uploaded for inference. Compatible recipients need the same supported codec/model format.

## Send an image

1. Open channel chat and tap the image button beside the composer.
2. Pick a photo from your gallery.
3. Wait for encoding. Inspect the source preview and, if available, the reconstructed preview.
4. Review transmitted bytes, packet count, and estimated send duration. Estimates use the current radio settings and are unavailable if those settings are unknown.
5. Choose whether to include a recovery packet, then send. The chat shows per-packet progress.

The current build ships one quality/model setting: **ft32**, with a 512×512 codec reconstruction and metadata used to restore a supported aspect ratio. Reserved rate/resolution codes are not additional selectable quality options.

The result is a lossy, AI-reconstructed image and can differ materially from the original. It is labeled accordingly. Send confirmation describes companion acceptance of packets, not end-to-end proof that every recipient reconstructed the image.

## Receive, reconstruct, and save

Chunks are reassembled into an image entry in channel chat. A partially received stream is retained for up to 60 seconds before expiry. An optional XOR parity packet can recover **one missing data chunk**, provided the parity and other required chunks arrive; it does not guarantee delivery.

With Process images automatically enabled, complete images are queued for local reconstruction. Automatic decoding runs only while the app is in the foreground, one image at a time, with at most 3 images queued; when more arrive, the newest 3 are kept and the rest wait for a tap. Otherwise, tap an image entry to process it. Download/enable the model if prompted. A failed reconstruction can be retried; missing chunks and inference errors are different failures.

Tap a reconstructed image to inspect it. Long-press or right-click its chat bubble for Packet info, Delete, and Save (available once decoded). Deletion is local. Encoded streams and reconstructed images are persisted in application storage, capped at 200 images, 64 MB, and 30 days, plus a limit of 400 image entries (including ones waiting to be decoded and your own sent images once their data has expired). When the cap is reached, the oldest reconstructed images are evicted first and show "Image no longer stored"; they can be decoded again while their small encoded stream remains. Past 30 days the stream is removed too.

## Other image features

[GIFs and URL image previews](additional-features.md#url-image-previews) transmit references and fetch image content over the internet. They do not use this mesh image transport.

## Implementation reference

[image_chunk_transport.dart](../lib/services/image_chunk_transport.dart) defines the wire layout, capacities, metadata, and recovery algorithm. The current transport uses command 62, response 27, and data type `0xAE1C`. See the [protocol reference](ble-protocol.md#regions-and-image-data) and [fixture regeneration guide](../tools/aeic/README.md).

## Mesh photo detail (MeshCore Open TAK)

Mesh photos (AV1, formerly "VOX photos") come in three sizes. The encoder picks the resolution and quality that look best within each byte budget:

| Choice | Bytes | Packets | Air at 250 kHz SF7 | |
|---|---|---|---|---|
| Standard | 2.7 KB | 18 | ~3 s | Default |
| More detail | 5.5 KB | 36 | ~5 s | |
| Sharp | 11 KB | 71 | ~11 s | About twice the resolution |

Sharp is meant for a fast MediaMesh preset. Wadamesh radios need the build that accepts up to 96 packets per photo to show it (older builds take 64).

**On every app.** Mesh photos are sent and shown on Android, Windows, macOS and
Linux. On a computer, the photo button opens a file chooser (there is no
camera there). The encoder is libaom, built for each platform from the same
pinned source:
- Android: `libvox_av1.so` in the APK.
- Windows: `vox_av1.dll` beside the app.
- Linux: `lib/libvox_av1.so` in the bundle.
- macOS: the `vox_av1` pod, universal (arm64 + x86_64). Intel Macs encode
  more slowly, without SIMD.

The source is `third_party/vox_av1/vox_av1.c`.

**Voice messages on a computer.** Recording uses the computer's microphone:
- Windows: works as it is.
- macOS: asks for microphone permission the first time.
- Linux: needs PulseAudio's tools (`sudo apt install pulseaudio-utils`, which
  works with PipeWire too).

Voice uses Codec2, which the Windows, macOS and Linux builds include.

## Voice restorer (MeshCore Open TAK)

Codec2 sounds buzzy and robotic, and it carries speech only up to 4 kHz, so
the "s", "f" and "t" sounds and the air in a voice are missing. With the **AI
voice restorer** downloaded, Codec2 clips play with the whole voice rebuilt, at
48 kHz.

- **Turn it on.** It's fetched on Wi-Fi the first time the app opens. Or: voice
  settings (the voice diagnostics sheet) → **AI voice restorer** → **Get**
  (about 28 MB, once). Then **Restore Codec2 voice (AI)** switches it on and
  off; long-press it to delete the model.
- **What it changes.** Only playback on this device. The sound is generated by
  the model from what Codec2 carried, so it can be slightly wrong. The clip
  that's stored, served to others and forwarded is unchanged, and the record
  sheet's preview plays what radios will hear, without the restorer. Mimi clips
  are already wideband and play as they are.
- **Model.** LavaSR's bandwidth-extension enhancer (a Vocos network,
  Apache-2.0, Yatharth Sharma, from the ONNX export by Topping1/LavaSR-ONNX),
  fine-tuned on Codec2 itself with `tools/voice-training` (VCTK speech,
  CC-BY-4.0, 378,673 steps). `scripts/models/voice_bwe_to_onnx.py` wraps it
  with its signal processing (6x upsampling, STFT, mel features and the inverse
  STFT; the 4 kHz merge off) into one graph that takes 8 kHz samples and
  returns 48 kHz. It is published as the `voice-restorer-onnx-v1` release,
  checked by SHA-256.
- **How long.** ONNX Runtime on the CPU, about 20x faster than real time on two
  cores, so a 20-second clip takes a second or so before it plays; the result
  is kept with the clip's decoded audio.
- **Where.** Android, Windows, macOS and Linux. Not on the web build.
- **It replaced the voice enhancer**, which only filled in the treble
  (`voice-bwe-onnx-v1`). Phones that had downloaded it delete it.
- **Training your own.** `tools/voice-training` is a kit for a gaming PC (on
  Windows, unzip it and double-click START.bat). It trains the restorer, and
  the tiny net Wadamesh TAK standalones can use for Brighter voice.

## Enhance (MeshCore Open TAK)

In the full-screen viewer of a Mesh photo, the sparkle button shows the photo
**enhanced** by an AI super-resolution model on the phone or computer: 4x up to
512 pixels on the long side, 2x up to 1024 (every level up to Super Sharp).
Tap it again for the photo as sent.

**Sharp and Super Sharp photos open enhanced** on their own (a photo of 50 or
more packets) once the model is on the device: the photo shows as sent with
"Enhancing… N%" while it works, then the enhanced view. Without the model they
open as sent; nothing is downloaded without asking.

- **Model.** Real-ESRGAN `realesr-general-x4v3` (BSD-3-Clause, Xintao Wang),
  about 5 MB, downloaded the first time from this repo's `upscale-onnx-v2`
  release after a prompt, and checked by SHA-256. A device that has v1 (no 2x
  output) fetches v2 on its own. `scripts/models/realesr_to_onnx.py` rebuilds
  the file from the authors' weights without PyTorch, and the **Photo enhancer
  model** workflow publishes it.
- **What it changes.** Only what the viewer shows. The stored photo, the chat
  bubble and a forwarded photo stay as received. The enhanced view is labelled
  "AI-enhanced view: details may be invented": the model sharpens edges and
  textures, and small text, faces and numbers can come out wrong.
- **How.** ONNX Runtime on the CPU, in 160-pixel tiles with 32 pixels of
  overlap, so memory stays small and the tiles join without seams. Over 512
  pixels the model's output is averaged down 2x (`output_x2`), keeping the
  result within 2048 pixels; a Super Sharp photo takes some seconds.
- **Where.** Android, Windows, macOS and Linux. Not on the web build.

## AI sketch HD (MeshCore Open TAK)

MeshCore Open TAK adds a third photo option beside Mesh photos and the ~150-byte AI sketch: **AI sketch HD**, AEIC-SE at the `ft2` rate point. A 512×512 photo becomes about 1–2 KB (8–15 packets with parity), far closer to the original than an AI sketch, at roughly half a Mesh photo's airtime.

- **Codec.** [mikecarper/AEIC](https://github.com/mikecarper/AEIC/tree/main/mobile)'s ncnn program, built for arm64 by `tool/build_aeic_hd_android.sh` and shipped in the APK. It loads one model stage at a time, so decoding peaks around 550 MB rather than the ONNX decoder's ~2.2 GB, but takes minutes rather than a second. ncnn is built with CPU-specific fast paths off so every phone computes the entropy model identically.
- **Model.** About 1.9 GB (1,052 files), downloaded from App Settings → Image messages → AI sketch HD. It is a GitHub release (`aeic-ncnn-ft2-512-v1`) built by `.github/workflows/aeic-ncnn-models.yml` from the authors' `AEIC_SE_ft2.pkl`, SD-Turbo's UNet and AdcSR's half decoder. **Check this phone** encodes the export's sample photo and requires byte-identical output to the reference codec, then decodes it and compares against the reference picture.
- **Wire.** Same image messages (channel GRP_DATA, OTP DMs). Rate code 2 in the chunk-0 metadata byte marks AI sketch HD, so receivers route it to this codec; builds without it report an unsupported format. The payload is the reference bitstream without its 12-byte size header. Partial images are now kept for 3 minutes, because an HD photo on a slow preset takes more than a minute to arrive.
- **Not on radios.** Wadamesh ignores AEIC image messages of either kind.
