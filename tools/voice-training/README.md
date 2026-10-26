# Voice training kit

Trains three models on your own GPU, for better Codec2 voice:

| | For | What it learns | Data | Time on an RTX 5080 |
|---|---|---|---|---|
| **1. Brighter voice net** | Wadamesh TAK standalones | How loud the missing 4–8 kHz band should be, from the decoded voice. Replaces Brighter voice's fixed 12-number rule with a tiny network (2,500 weights, 10 KB of flash). | LibriTTS-R dev-clean and test-clean, 2.4 GB | About 30 minutes, mostly preparing data |
| **2. Voice restorer** | MeshCore Open TAK | Rebuilding the whole voice from Codec2, buzzy, robotic sound and missing treble alike. Fine-tuned from LavaSR's enhancer. | VCTK, 11 GB, 48 kHz | About 1 hour to prepare, then 8 hours or more of training (you can stop and continue) |
| **3. Small restorer** | Wadamesh TAK standalones (T-Display P4, T-Deck) | The same job at 16 kHz, in a network about 30 times smaller (0.5 million weights, a 1 MB file on the SD card) that a standalone can run. Learns from the voice restorer when it's been trained. An experiment: how it sounds, and how fast each standalone runs it, is what we find out. | The voice restorer's (prepared once for both) | About 2 hours (you can stop and continue) |

Both datasets have women and men in about equal numbers.

## Windows 11 (plug and play)

1. Get the kit: **Actions → Voice training kit**, open the latest run, and download **voice-training-kit** under Artifacts.
2. Unzip it to a folder on a drive with about 50 GB free.
3. Double-click **START.bat**.

The first start sets up its own Python and PyTorch for CUDA 12.8, about 3 GB. That's what RTX 50-series cards need. Everything stays in the kit's folder. After that, START.bat shows a menu:

- **1: Brighter voice net.** Downloads the speech, prepares it and trains. Writes to `output\`:
  - `VoxBrightNet.h`;
  - `bright-report.txt`, which compares the net with the rule on speakers it never heard;
  - `bright-demo\`, clips of each voice four ways: original, Codec2, rule and net.

  Send me `VoxBrightNet.h` and the report, and I'll add the net to the firmware.
- **2: Voice restorer.** Asks how many hours to train this time (8 by default).
  - **Samples:** every 1,000 steps it writes clips to `output\restorer-samples\stepNNNNNNN\`. Compare them with the `-codec2` and `-clean` files next to them; the clips are held-out voices, one woman and one man.
  - **Stopping:** Ctrl+C stops and saves. Choosing 2 again continues from there.
  - **At the end:** it writes `output\codec2-restorer-8k-48k.onnx` and its SHA-256 to `restorer-report.txt`.
- **3: Export.** Writes the restorer from the last checkpoint, without more training.
- **4: Small restorer.** Asks how many hours to train this time (2 by default). Train the voice restorer (2) first if you can: the small one then learns to sound like it.
  - **Samples:** `output\small-restorer-samples\stepNNNNNNN\`, at 16 kHz, next to `-codec2` and `-clean`.
  - **Stopping:** Ctrl+C stops and saves. Choosing 4 again continues from there.
  - **At the end:** it writes `output\vox-restorer-small.bin` and `small-restorer-report.txt`. Copy the `.bin` to the standalone's SD card as `/models/vox-restorer-small.bin`, then turn on **Settings > Sound > AI voice restorer**.
  - **Other sizes:** set `KIT_SMALL_DIM` (128) and `KIT_SMALL_LAYERS` (4) before a new run (delete `small-restorer\run` in the data folder first).
- **5: Export the small restorer** from its last checkpoint.
- **6: Check.** Tests the GPU and Codec2.

If a download or a step fails, run START.bat again. Downloads resume and finished work is kept.

## By hand (any OS)

You need Python 3.12, PyTorch with CUDA, `pip install -r requirements.txt`, and a `c2round` binary. To build `c2round`, compile `c2round.c` against Wadamesh TAK's `lib/codec2`, using the command at the top of the file, and set `C2ROUND` to its path. Then run:

```
python -m kit.run check
python -m kit.run bright   --data D:\voice-data
python -m kit.run restorer --data D:\voice-data --hours 8
python -m kit.run export   --data D:\voice-data
python -m kit.run small    --data D:\voice-data --hours 2
python -m kit.run small-export --data D:\voice-data
```

## What's inside

- `kit/dsp.py`: Brighter voice's signal path, exactly as the firmware runs it: the same filters, levels and 10 ms frames as `VoxBrighten`.
- `kit/data.py`: downloads the datasets and runs every clip through our Codec2. Most clips go at 1200, the rest at 1600 or 3200. Each decoded clip is lined up in time with its original.
- `kit/train_bright.py`: the net, a 40-32-32-4 MLP, trained for MSE in dB on speech frames. Like the rule, its levels are then raised halfway towards real speech's average energy.
- `kit/lavasr.py`: LavaSR's enhancer in PyTorch, with the weights read from the [Topping1/LavaSR-ONNX](https://github.com/Topping1/LavaSR-ONNX) export (checked by SHA-256). It also has the app's front end: 6x upsampling, STFT, mel features and inverse STFT. It matches the app's graph to 62 dB.
- `kit/train_restorer.py`: fine-tuning as Vocos was trained.
  - **Losses:** multi-resolution mel L1, with multi-period and multi-resolution discriminators added after a 2,000-step warm-up.
  - **Format:** bf16 on the GPU.
  - **Export:** goes through the app's own graph builder, `voice_bwe_to_onnx.py`, with the 4 kHz merge off.
- `kit/small.py`: the small restorer, three ways that must agree: the PyTorch model, its file format (`vox-restorer-small.bin`, float16), and a numpy reference that runs the file exactly as the firmware's `VoxRestoreSmall.cpp` does.
  - **Shape:** Codec2 at 8 kHz, an STFT (256, hop 64) and 32 log-mel bands, a 7-wide conv into 128 channels, 4 ConvNeXt blocks, and a head giving log-magnitude and phase for an inverse STFT (512, hop 128) at 16 kHz.
  - **Cost:** about 60 million multiply-adds per second of voice.
- `kit/train_small.py`: trains it like the restorer (mel L1, then the same discriminators against the clean recording), with the voice restorer's output, brought to 16 kHz, as the mel target when there is one. The export checks the file, run by the numpy reference, against PyTorch.

## Licences

- **Datasets:** LibriTTS-R and VCTK are CC-BY-4.0.
- **Model:** LavaSR and its ONNX export are Apache-2.0.
- **Codec2:** LGPL-2.1.

A trained model credits these where it's published, as the app's current models do.
