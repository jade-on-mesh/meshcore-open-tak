"""Feasibility spike: export Mimi (8 codebooks, ~1.1 kb/s) to ONNX for VOX.

Writes to argv[1]:
  mimi_encoder.onnx / mimi_decoder.onnx            fp32
  mimi_encoder_int8.onnx / mimi_decoder_int8.onnx  dynamic int8 weights
  *_ort*.wav     the test voices decoded through the ONNX files
  report.txt     sizes, parity vs PyTorch, CPU timings
"""
import os
import sys
import time

import numpy as np
import onnxruntime as ort
import soundfile as sf
import torch
import torchaudio.functional as AF
from onnxruntime.quantization import QuantType, quantize_dynamic
from transformers import MimiModel

OUT = sys.argv[1]
os.makedirs(OUT, exist_ok=True)
NQ = 8
report = []


def log(s):
    print(s, flush=True)
    report.append(s)


model = MimiModel.from_pretrained("kyutai/mimi").eval()
SR = model.config.sampling_rate
log(f"sampling_rate={SR} frame_rate={model.config.frame_rate} "
    f"codebook_size={model.config.codebook_size} params="
    f"{sum(p.numel() for p in model.parameters()) / 1e6:.1f}M")


class Enc(torch.nn.Module):
    def __init__(self, m):
        super().__init__()
        self.m = m

    def forward(self, audio):  # [1, 1, T] float32 at 24 kHz
        return self.m.encode(audio, num_quantizers=NQ).audio_codes  # [1, NQ, F]


class Dec(torch.nn.Module):
    def __init__(self, m):
        super().__init__()
        self.m = m

    def forward(self, codes):  # [1, NQ, F] int64
        return self.m.decode(codes).audio_values  # [1, 1, T]


def load(voice):
    pcm = np.fromfile(f"third_party/codec2/raw/{voice}.raw", dtype="<i2")
    x = torch.from_numpy(pcm.astype(np.float32) / 32768.0)
    return AF.resample(x, 8000, SR).view(1, 1, -1)


x = load("kristoff")
with torch.no_grad():
    ref_codes = Enc(model)(x)
    ref_audio = Dec(model)(ref_codes)
log(f"reference: {x.shape[-1] / SR:.1f}s -> codes {tuple(ref_codes.shape)}")

paths = {k: f"{OUT}/mimi_{k}.onnx" for k in ("encoder", "decoder")}
t0 = time.time()
torch.onnx.export(
    Enc(model), (x,), paths["encoder"], opset_version=17,
    input_names=["audio"], output_names=["codes"],
    dynamic_axes={"audio": {2: "samples"}, "codes": {2: "frames"}},
    dynamo=False,
)
torch.onnx.export(
    Dec(model), (ref_codes,), paths["decoder"], opset_version=17,
    input_names=["codes"], output_names=["audio"],
    dynamic_axes={"codes": {2: "frames"}, "audio": {2: "samples"}},
    dynamo=False,
)
log(f"export took {time.time() - t0:.0f}s")

for k in ("encoder", "decoder"):
    q = paths[k].replace(".onnx", "_int8.onnx")
    quantize_dynamic(paths[k], q, weight_type=QuantType.QInt8)
    paths[k + "_int8"] = q
for k, p in paths.items():
    log(f"{os.path.basename(p)}: {os.path.getsize(p) / 1e6:.1f} MB")


def snr(ref, test):
    n = min(ref.shape[-1], test.shape[-1])
    r, t = ref.reshape(-1)[:n], test.reshape(-1)[:n]
    return 10 * np.log10(np.sum(r**2) / (np.sum((r - t) ** 2) + 1e-12))


for tag in ("", "_int8"):
    for threads in (1, 4):
        so = ort.SessionOptions()
        so.intra_op_num_threads = threads
        enc = ort.InferenceSession(paths["encoder" + tag], so)
        dec = ort.InferenceSession(paths["decoder" + tag], so)
        t = time.time()
        codes = enc.run(None, {"audio": x.numpy()})[0]
        te = time.time() - t
        t = time.time()
        audio = dec.run(None, {"codes": ref_codes.numpy()})[0]
        td = time.time() - t
        match = float(np.mean(codes == ref_codes.numpy())) * 100
        log(f"onnx{tag or '_fp32'} threads={threads}: encode {te:.2f}s, "
            f"decode {td:.2f}s for 5.0s audio; codes match {match:.1f}%; "
            f"decoder SNR vs PyTorch {snr(ref_audio.numpy(), audio):.1f} dB")

    # Full ONNX round trip on both voices, to listen to
    enc = ort.InferenceSession(paths["encoder" + tag])
    dec = ort.InferenceSession(paths["decoder" + tag])
    for voice in ("hts1a", "kristoff"):
        xv = load(voice)
        codes = enc.run(None, {"audio": xv.numpy()})[0]
        audio = dec.run(None, {"codes": codes})[0]
        name = f"{voice}_ort{tag or '_fp32'}.wav"
        sf.write(f"{OUT}/{name}", audio.reshape(-1), SR)
        bits = codes.shape[-1] * NQ * 11
        log(f"{name}: {codes.shape[-1]} frames, {bits // 8} bytes on air")

with open(f"{OUT}/report.txt", "w") as f:
    f.write("\n".join(report) + "\n")
