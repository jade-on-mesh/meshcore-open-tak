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
import transformers.masking_utils as masking_utils
from transformers import MimiModel

# Mimi never packs several sequences into one batch row. The packed-sequence
# check uses aten::diff, which the ONNX exporter cannot translate.
masking_utils.find_packed_sequence_indices = lambda position_ids: None

OUT = sys.argv[1]
os.makedirs(OUT, exist_ok=True)
NQ = 8
report = []


def log(s):
    print(s, flush=True)
    report.append(s)


model = MimiModel.from_pretrained("kyutai/mimi", attn_implementation="eager").eval()
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


# Fixed-length export: tracing bakes sequence lengths into the attention
# masks, so dynamic shapes would be silently wrong. Mimi is causal, so a clip
# padded with silence to MAX_S and trimmed afterwards must give the same
# result; this is checked below.
MAX_S = 20
MAX_T = MAX_S * SR
MAX_F = int(MAX_S * model.config.frame_rate)


def pad_audio(a):
    return torch.nn.functional.pad(a, (0, MAX_T - a.shape[-1]))


def pad_codes(c):
    return torch.nn.functional.pad(c, (0, MAX_F - c.shape[-1]))


x = load("kristoff")
with torch.no_grad():
    ref_codes = Enc(model)(x)
    ref_audio = Dec(model)(ref_codes)
    padded_codes = Enc(model)(pad_audio(x))[..., : ref_codes.shape[-1]]
    padded_audio = Dec(model)(pad_codes(ref_codes))[..., : ref_audio.shape[-1]]
log(f"reference: {x.shape[-1] / SR:.1f}s -> codes {tuple(ref_codes.shape)}")
log(f"causality: codes match after padding "
    f"{float((padded_codes == ref_codes).float().mean()) * 100:.1f}%")

paths = {k: f"{OUT}/mimi_{k}.onnx" for k in ("encoder", "decoder")}
t0 = time.time()
torch.onnx.export(
    Enc(model), (pad_audio(x),), paths["encoder"], opset_version=17,
    input_names=["audio"], output_names=["codes"], dynamo=False,
)
torch.onnx.export(
    Dec(model), (pad_codes(ref_codes),), paths["decoder"], opset_version=17,
    input_names=["codes"], output_names=["audio"], dynamo=False,
)
log(f"export took {time.time() - t0:.0f}s")

import onnx  # noqa: E402
from onnx import TensorProto, helper, numpy_helper  # noqa: E402


def weights_to_fp16(m, min_elems=4096):
    g = m.graph
    keep, casts = [], []
    for init in g.initializer:
        if init.data_type == TensorProto.FLOAT and np.prod(init.dims) >= min_elems:
            arr = numpy_helper.to_array(init).astype(np.float16)
            half = numpy_helper.from_array(arr, init.name + "__fp16")
            keep.append(half)
            casts.append(helper.make_node(
                "Cast", [half.name], [init.name], to=TensorProto.FLOAT,
                name=init.name + "__cast"))
        else:
            keep.append(init)
    del g.initializer[:]
    g.initializer.extend(keep)
    for n in reversed(casts):
        g.node.insert(0, n)
    return m

VARIANTS = ["", "_int8mm", "_fp16"]
for k in ("encoder", "decoder"):
    # 8-bit weights for the transformer MatMuls only (per channel); the
    # convolutions and the quantizer codebook search stay fp32.
    q = paths[k].replace(".onnx", "_int8mm.onnx")
    quantize_dynamic(
        paths[k], q, weight_type=QuantType.QInt8, per_channel=True,
        op_types_to_quantize=["MatMul"],
    )
    paths[k + "_int8mm"] = q
    # fp16 *storage* only: large fp32 weight tables are stored as fp16 and
    # cast back to fp32 by a Cast node, which ORT constant-folds at load.
    # All arithmetic stays fp32; only the weights are rounded to fp16.
    h = paths[k].replace(".onnx", "_fp16.onnx")
    onnx.save(weights_to_fp16(onnx.load(paths[k])), h)
    paths[k + "_fp16"] = h
for k, p in paths.items():
    log(f"{os.path.basename(p)}: {os.path.getsize(p) / 1e6:.1f} MB")


def snr(ref, test):
    n = min(ref.shape[-1], test.shape[-1])
    r, t = ref.reshape(-1)[:n], test.reshape(-1)[:n]
    return 10 * np.log10(np.sum(r**2) / (np.sum((r - t) ** 2) + 1e-12))


log(f"causality: decoder SNR after padding "
    f"{snr(ref_audio.numpy(), padded_audio.numpy()):.1f} dB")

F = ref_codes.shape[-1]
T = ref_audio.shape[-1]
for tag in VARIANTS:
    for threads in (1,):
        so = ort.SessionOptions()
        so.intra_op_num_threads = threads
        try:
            enc = ort.InferenceSession(paths["encoder" + tag], so)
            dec = ort.InferenceSession(paths["decoder" + tag], so)
        except Exception as e:  # keep going with other variants
            log(f"onnx{tag}: could not load: {e}")
            continue
        t = time.time()
        codes = enc.run(None, {"audio": pad_audio(x).numpy()})[0][..., :F]
        te = time.time() - t
        t = time.time()
        audio = dec.run(None, {"codes": pad_codes(ref_codes).numpy()})[0][..., :T]
        td = time.time() - t
        match = float(np.mean(codes == ref_codes.numpy())) * 100
        log(f"onnx{tag or '_fp32'} threads={threads}: encode {te:.2f}s, "
            f"decode {td:.2f}s (always {MAX_S}s of work); codes match {match:.1f}%; "
            f"decoder SNR vs PyTorch {snr(ref_audio.numpy(), audio):.1f} dB")

    # Full ONNX round trip on both voices, to listen to
    try:
        enc = ort.InferenceSession(paths["encoder" + tag])
        dec = ort.InferenceSession(paths["decoder" + tag])
    except Exception:
        continue
    for voice in ("hts1a", "kristoff"):
        xv = load(voice)
        nf = int(np.ceil(xv.shape[-1] / SR * model.config.frame_rate))
        codes = enc.run(None, {"audio": pad_audio(xv).numpy()})[0][..., :nf]
        audio = dec.run(
            None, {"codes": pad_codes(torch.from_numpy(codes)).numpy()}
        )[0][..., : xv.shape[-1]]
        name = f"{voice}_ort{tag or '_fp32'}.wav"
        sf.write(f"{OUT}/{name}", audio.reshape(-1), SR)
        bits = codes.shape[-1] * NQ * 11
        log(f"{name}: {codes.shape[-1]} frames, {bits // 8} bytes on air")

with open(f"{OUT}/report.txt", "w") as f:
    f.write("\n".join(report) + "\n")
