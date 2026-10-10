"""Encode the Codec2 test voices with Mimi and LPCNet for a listening test.

Run by .github/workflows/vox-codec-samples.yml. Inputs are 8 kHz 16-bit raw
files from third_party/codec2/raw; outputs go to the directory in argv[1].
"""
import math
import os
import subprocess
import sys

import numpy as np
import soundfile as sf
import torch
import torchaudio.functional as AF
from transformers import MimiModel

OUT = sys.argv[1]
LPCNET = sys.argv[2]  # path to the built lpcnet_demo
SRC = "third_party/codec2/raw"
os.makedirs(OUT, exist_ok=True)
report = []


def load8k(name):
    pcm = np.fromfile(os.path.join(SRC, name + ".raw"), dtype="<i2")
    return torch.from_numpy(pcm.astype(np.float32) / 32768.0)


model = MimiModel.from_pretrained("kyutai/mimi").eval()
sr_mimi = model.config.sampling_rate  # 24 kHz

for voice in ["hts1a", "kristoff"]:
    x8 = load8k(voice)
    secs = len(x8) / 8000
    sf.write(f"{OUT}/{voice}_original.wav", x8.numpy(), 8000)

    # --- Mimi: 12.5 frames/s, 11 bits per codebook per frame
    x24 = AF.resample(x8, 8000, sr_mimi)
    for nq in (8, 16):
        with torch.no_grad():
            enc = model.encode(x24.view(1, 1, -1), num_quantizers=nq)
            y = model.decode(enc.audio_codes).audio_values[0, 0]
        frames = enc.audio_codes.shape[-1]
        bits = frames * nq * 11
        name = f"{voice}_mimi_{nq}q.wav"
        sf.write(f"{OUT}/{name}", y.numpy(), sr_mimi)
        report.append(
            f"{name}: {bits / secs:.0f} bps, {math.ceil(bits / 8)} bytes "
            f"for {secs:.1f}s"
        )

    # --- LPCNet 1.6 kb/s codec: 16 kHz raw in/out
    if not os.path.exists(LPCNET):
        report.append(f"{voice}: LPCNet not built, see lpcnet-build.log")
        continue
    x16 = AF.resample(x8, 8000, 16000)
    pcm16 = (x16.clamp(-1, 1) * 32767).numpy().astype("<i2")
    raw_in = f"/tmp/{voice}_16k.raw"
    pcm16.tofile(raw_in)
    subprocess.run([LPCNET, "-encode", raw_in, f"/tmp/{voice}.lpc"], check=True)
    subprocess.run(
        [LPCNET, "-decode", f"/tmp/{voice}.lpc", f"/tmp/{voice}_dec.raw"],
        check=True,
    )
    nbytes = os.path.getsize(f"/tmp/{voice}.lpc")
    dec = np.fromfile(f"/tmp/{voice}_dec.raw", dtype="<i2")
    name = f"{voice}_lpcnet_1600.wav"
    sf.write(f"{OUT}/{name}", dec.astype(np.float32) / 32768.0, 16000)
    report.append(f"{name}: {nbytes * 8 / secs:.0f} bps, {nbytes} bytes for {secs:.1f}s")

with open(f"{OUT}/report.txt", "w") as f:
    f.write("\n".join(report) + "\n")
print("\n".join(report))
