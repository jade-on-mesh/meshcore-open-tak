"""LavaSR's enhancer (a Vocos backbone and spectrogram head, Apache-2.0,
Yatharth Sharma, https://github.com/ysharma3501/LavaSR) as a PyTorch module,
with its weights read from the ONNX export at
https://github.com/Topping1/LavaSR-ONNX (Apache-2.0), so it can be fine-tuned.

Also the signal processing around it, the same as the app's model graph
(scripts/models/voice_bwe_to_onnx.py): 8 kHz -> 48 kHz upsampling, STFT, mel
features, inverse STFT.
"""
import os
import sys

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

N_FFT, HOP, N_MELS, MEL_SR = 2048, 512, 80, 44100
PAD = (N_FFT - HOP) // 2
UP = 6
SR = 48000
DIM, INTER, LAYERS = 512, 1536, 8

ONNX_SRC = "https://github.com/Topping1/LavaSR-ONNX/releases/download/Alpha-v0.1"
ONNX_FILES = {
    "enhancer_backbone.onnx": "841e96d261dffdf1dc974f3d29e2cfcf1b16fd0b358749c1ace0bbfa1d4c8ddd",
    "enhancer_backbone.onnx.data": "a125a4ede7cfdd1073d906a3cadf2171a30be6a40f296ad28772e0ba258de8c5",
    "enhancer_spec_head.onnx": "f66fd164c55fd1b07e5cea5e687c71522b192f452691128fd7ae4e6b26dbc683",
    "enhancer_spec_head.onnx.data": "b855e309b027af9aa75285b97b345571b6bd695a30fde434d06c979d83885fd6",
}


# ----------------------------------------------------------------- constants
# The same arithmetic as voice_bwe_to_onnx.py, so features match the app.

def hann(n):
    return (0.5 - 0.5 * np.cos(2 * np.pi * np.arange(n) / n)).astype(np.float32)


def _hz_to_mel(f):
    f = np.asarray(f, dtype=np.float64)
    return np.where(f >= 1000.0, 15.0 + np.log(np.maximum(f, 1e-9) / 1000.0) / (np.log(6.4) / 27.0),
                    f / (200.0 / 3))


def _mel_to_hz(m):
    m = np.asarray(m, dtype=np.float64)
    return np.where(m >= 15.0, 1000.0 * np.exp((np.log(6.4) / 27.0) * (m - 15.0)), (200.0 / 3) * m)


def mel_fb(sr=MEL_SR, n_fft=N_FFT, n_mels=N_MELS, fmin=0.0, fmax=8000.0):
    freqs = np.linspace(0, sr / 2, n_fft // 2 + 1)
    pts = _mel_to_hz(np.linspace(_hz_to_mel(fmin), _hz_to_mel(fmax), n_mels + 2))
    fb = np.zeros((n_mels, freqs.size))
    for i in range(n_mels):
        lo, c, hi = pts[i], pts[i + 1], pts[i + 2]
        fb[i] = np.maximum(0, np.minimum((freqs - lo) / max(c - lo, 1e-12), (hi - freqs) / max(hi - c, 1e-12)))
    fb *= (2.0 / (pts[2:] - pts[:-2]))[:, None]
    return fb.astype(np.float32)


def resample_kernel(taps=16):
    half = taps * UP
    n = np.arange(-half, half + 1)
    h = np.sinc(n / UP) * np.kaiser(2 * half + 1, 8.0)
    h *= UP / h.sum()
    return h.astype(np.float32), half


class Frontend(nn.Module):
    """8 kHz samples -> (48 kHz samples, complex STFT, log-mel), batched [B, N]."""

    def __init__(self):
        super().__init__()
        h, self.delay = resample_kernel()
        self.register_buffer("lp", torch.from_numpy(h).view(1, 1, -1))
        self.register_buffer("win", torch.from_numpy(hann(N_FFT)))
        self.register_buffer("fb", torch.from_numpy(mel_fb()))

    def up(self, x8):
        n = x8.shape[-1]
        y = F.conv_transpose1d(x8.unsqueeze(1), self.lp, stride=UP)
        return y[:, 0, self.delay: self.delay + UP * n]

    def stft(self, x):
        xp = F.pad(x.unsqueeze(1), (PAD, PAD), mode="reflect")[:, 0]
        return torch.stft(xp, N_FFT, HOP, window=self.win, center=False, return_complex=True)  # [B, 1025, T]

    def mel(self, spec):
        return torch.log(torch.clamp(torch.matmul(self.fb, spec.abs()), min=1e-5))

    def forward(self, x8):
        x48 = self.up(x8)
        spec = self.stft(x48)
        return x48, spec, self.mel(spec)

    def istft(self, spec, n):
        fr = torch.fft.irfft(spec.transpose(1, 2), n=N_FFT) * self.win          # [B, T, N_FFT]
        B, T, _ = fr.shape
        L = (T - 1) * HOP + N_FFT
        y = F.fold(fr.transpose(1, 2), (1, L), (1, N_FFT), stride=(1, HOP))[:, 0, 0]
        env = F.fold((self.win ** 2).view(1, -1, 1).expand(1, N_FFT, T), (1, L), (1, N_FFT),
                     stride=(1, HOP))[:, 0, 0]
        y = y / torch.clamp(env, min=1e-8)
        return y[:, PAD: PAD + n]


# ---------------------------------------------------------------- the network

class ConvNeXt(nn.Module):
    def __init__(self):
        super().__init__()
        self.dwconv = nn.Conv1d(DIM, DIM, 7, padding=3, groups=DIM)
        self.norm = nn.LayerNorm(DIM, eps=1e-6)
        self.pwconv1 = nn.Linear(DIM, INTER)
        self.pwconv2 = nn.Linear(INTER, DIM)
        self.gamma = nn.Parameter(torch.ones(DIM))

    def forward(self, x):                      # [B, D, T]
        r = x
        x = self.dwconv(x).transpose(1, 2)
        x = self.pwconv2(F.gelu(self.pwconv1(self.norm(x))))
        return r + (self.gamma * x).transpose(1, 2)


class Enhancer(nn.Module):
    """mel [B, 80, T] -> complex spectrum [B, 1025, T]."""

    def __init__(self):
        super().__init__()
        self.embed = nn.Conv1d(N_MELS, DIM, 7, padding=3)
        self.norm = nn.LayerNorm(DIM, eps=1e-6)
        self.convnext = nn.ModuleList([ConvNeXt() for _ in range(LAYERS)])
        self.final_layer_norm = nn.LayerNorm(DIM, eps=1e-6)
        self.out = nn.Linear(DIM, N_FFT + 2)
        self.mag_max = 100.0

    def hidden(self, mel):
        x = self.norm(self.embed(mel).transpose(1, 2)).transpose(1, 2)
        for b in self.convnext:
            x = b(x)
        return self.final_layer_norm(x.transpose(1, 2))          # [B, T, D]

    def head(self, h):
        x = self.out(h).transpose(1, 2)
        mag, ph = x.chunk(2, dim=1)
        mag = torch.clamp(torch.exp(mag), max=self.mag_max)
        return mag * torch.cos(ph), mag * torch.sin(ph)

    def forward(self, mel):
        re, im = self.head(self.hidden(mel))
        return torch.complex(re.float(), im.float())


def fetch_onnx(dest):
    """Downloads the ONNX export (about 56 MB) into `dest`, checking SHA-256s."""
    import hashlib
    import urllib.request
    os.makedirs(dest, exist_ok=True)
    for name, sha in ONNX_FILES.items():
        p = os.path.join(dest, name)
        if os.path.exists(p) and hashlib.sha256(open(p, "rb").read()).hexdigest() == sha:
            continue
        print(f"  downloading {name}")
        urllib.request.urlretrieve(f"{ONNX_SRC}/{name}", p + ".part")
        got = hashlib.sha256(open(p + ".part", "rb").read()).hexdigest()
        if got != sha:
            os.remove(p + ".part")
            sys.exit(f"{name}: checksum mismatch ({got})")
        os.replace(p + ".part", p)
    return dest


def load_from_onnx(d):
    """Enhancer with LavaSR's weights, from the ONNX files in `d`."""
    import onnx
    from onnx import numpy_helper
    bb = onnx.load(os.path.join(d, "enhancer_backbone.onnx"))
    hd = onnx.load(os.path.join(d, "enhancer_spec_head.onnx"))
    named = {i.name: numpy_helper.to_array(i) for g in (bb, hd) for i in g.graph.initializer}
    # Linear weights were folded into anonymous MatMul constants: take them in
    # graph order (pwconv1, pwconv2 per block; the head's last).
    mats = [n.input[1] for n in bb.graph.node if n.op_type == "MatMul"]
    head_mat = [n.input[1] for n in hd.graph.node if n.op_type == "MatMul"][0]
    clip = [n for n in hd.graph.node if n.op_type == "Clip"][0].input[2]
    m = Enhancer()
    sd = {}
    for k, v in named.items():
        if k.startswith("backbone."):
            sd[k[len("backbone."):]] = torch.from_numpy(v.copy())
        elif k == "out.bias":
            sd["out.bias"] = torch.from_numpy(v.copy())
    assert len(mats) == 2 * LAYERS, len(mats)
    for i in range(LAYERS):
        sd[f"convnext.{i}.pwconv1.weight"] = torch.from_numpy(named[mats[2 * i]].T.copy())
        sd[f"convnext.{i}.pwconv2.weight"] = torch.from_numpy(named[mats[2 * i + 1]].T.copy())
    sd["out.weight"] = torch.from_numpy(named[head_mat].T.copy())
    m.load_state_dict(sd, strict=True)
    m.mag_max = float(named[clip])
    return m


def export_onnx(model, d):
    """Writes `model` as enhancer_backbone.onnx / enhancer_spec_head.onnx in
    `d`, with the input and output names of the Topping1 export, so the app's
    graph builder (scripts/models/voice_bwe_to_onnx.py) can wrap it."""
    os.makedirs(d, exist_ok=True)
    model = model.float().eval().cpu()

    class BB(nn.Module):
        def __init__(s):
            super().__init__()
            s.m = model

        def forward(s, mel):
            return s.m.hidden(mel)

    class HD(nn.Module):
        def __init__(s):
            super().__init__()
            s.m = model

        def forward(s, hidden):
            return s.m.head(hidden)

    mel = torch.zeros(1, N_MELS, 50)
    torch.onnx.export(BB(), (mel,), os.path.join(d, "enhancer_backbone.onnx"), input_names=["mel"],
                      output_names=["hidden"], dynamic_axes={"mel": {0: "batch", 2: "frames"},
                                                             "hidden": {0: "batch", 1: "frames"}},
                      opset_version=18, dynamo=False)
    h = torch.zeros(1, 50, DIM)
    torch.onnx.export(HD(), (h,), os.path.join(d, "enhancer_spec_head.onnx"), input_names=["hidden"],
                      output_names=["real", "imag"],
                      dynamic_axes={"hidden": {0: "batch", 1: "frames"}, "real": {0: "batch", 2: "frames"},
                                    "imag": {0: "batch", 2: "frames"}},
                      opset_version=18, dynamo=False)
