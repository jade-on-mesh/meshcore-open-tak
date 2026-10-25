#!/usr/bin/env python3
"""Builds the voice enhancer model (lib/vox/vox_voice_enhance.dart): one ONNX
graph that takes decoded Codec2 speech at 8 kHz and returns it at 48 kHz with
the missing upper band (4-24 kHz) filled in.

The network is LavaSR's bandwidth-extension enhancer (a Vocos backbone and
spectrogram head, Apache-2.0, Yatharth Sharma, https://github.com/ysharma3501/LavaSR)
as exported to ONNX by https://github.com/Topping1/LavaSR-ONNX. This script
wraps it with the signal processing around it, written here, so the app only
moves samples in and out:

  pcm [N] 8 kHz
    -> 6x polyphase upsampling (windowed-sinc low-pass at 4 kHz)  48 kHz
    -> reflect pad, STFT (Hann 2048, hop 512)
    -> |X| -> 80 Slaney mel bands (0-8 kHz, as the model was trained) -> log
    -> backbone -> head -> complex spectrum Y
    -> merge: below 4 kHz keep X (what was received), above it take Y,
       with a smoothstep 400 Hz wide in between
    -> inverse STFT (overlap-add, window-squared normalisation)
  audio [6N] 48 kHz

N must be at least MIN_SAMPLES; the app pads shorter clips with silence.

Usage: voice_bwe_to_onnx.py MODELS_DIR OUT.onnx [--check]
MODELS_DIR holds enhancer_backbone.onnx(+.data) and enhancer_spec_head.onnx(+.data).
Large weights are stored as float16 and cast to float32 when the model loads,
which halves the download (to about 28 MB) without changing the arithmetic.
8-bit weights (15 MB) were tried and dropped: they move the added band by up to
5 dB on male speech.
--check compares the graph with a numpy version of the same steps.
"""
import argparse
import sys

import numpy as np
import onnx
from onnx import TensorProto, helper, numpy_helper

N_FFT, HOP, N_MELS, MEL_SR = 2048, 512, 80, 44100
PAD = (N_FFT - HOP) // 2
UP = 6                  # 8 kHz -> 48 kHz
SR_OUT = 48000
CUTOFF, WIDTH = 4000.0, 400.0
RESAMPLE_TAPS = 16      # input samples each output sample sees, per side
OPSET = 18
MIN_SAMPLES = 256       # shortest input (32 ms): the reflect pad needs 769 at 48 kHz


# ----------------------------------------------------------------- constants

def hann(n):
    return (0.5 - 0.5 * np.cos(2 * np.pi * np.arange(n) / n)).astype(np.float32)


def hz_to_mel(f):
    f = np.asarray(f, dtype=np.float64)
    lin = f / (200.0 / 3)
    log = 15.0 + np.log(np.maximum(f, 1e-9) / 1000.0) / (np.log(6.4) / 27.0)
    return np.where(f >= 1000.0, log, lin)


def mel_to_hz(m):
    m = np.asarray(m, dtype=np.float64)
    lin = (200.0 / 3) * m
    log = 1000.0 * np.exp((np.log(6.4) / 27.0) * (m - 15.0))
    return np.where(m >= 15.0, log, lin)


def mel_fb(sr=MEL_SR, n_fft=N_FFT, n_mels=N_MELS, fmin=0.0, fmax=8000.0):
    """Slaney mel filterbank [n_mels, bins], librosa's defaults."""
    freqs = np.linspace(0, sr / 2, n_fft // 2 + 1)
    pts = mel_to_hz(np.linspace(hz_to_mel(fmin), hz_to_mel(fmax), n_mels + 2))
    fb = np.zeros((n_mels, freqs.size))
    for i in range(n_mels):
        lo, c, hi = pts[i], pts[i + 1], pts[i + 2]
        up = (freqs - lo) / max(c - lo, 1e-12)
        dn = (hi - freqs) / max(hi - c, 1e-12)
        fb[i] = np.maximum(0, np.minimum(up, dn))
    fb *= (2.0 / (pts[2:] - pts[:-2]))[:, None]
    return fb.astype(np.float32)


def merge_mask():
    """0 below the received band's edge, 1 above, smoothstep in between."""
    f = np.arange(N_FFT // 2 + 1) * SR_OUT / N_FFT
    t = np.clip((f - (CUTOFF - WIDTH / 2)) / WIDTH, 0, 1)
    return (3 * t ** 2 - 2 * t ** 3).astype(np.float32)


def resample_kernel():
    """Low-pass for 6x upsampling: Kaiser-windowed sinc at the input Nyquist,
    gain 6 so the level is kept. Odd length, so the delay is whole samples."""
    half = RESAMPLE_TAPS * UP
    n = np.arange(-half, half + 1)
    h = np.sinc(n / UP) * np.kaiser(2 * half + 1, 8.0)
    h *= UP / h.sum()
    return h.astype(np.float32), half


# ----------------------------------------------------------- numpy reference

def reference(pcm, net):
    """The same steps in numpy; [net] maps mel [1,80,T] to (real, imag)."""
    h, delay = resample_kernel()
    up = np.zeros(pcm.size * UP, np.float32)
    up[::UP] = pcm
    x = np.convolve(up, h)[delay:delay + up.size].astype(np.float32)
    xp = np.pad(x, (PAD, PAD), mode="reflect")
    nfr = (xp.size - N_FFT) // HOP + 1
    idx = np.arange(N_FFT)[None] + HOP * np.arange(nfr)[:, None]
    w = hann(N_FFT)
    X = np.fft.rfft(xp[idx] * w, axis=-1)                        # [T, bins]
    mel = np.log(np.maximum(np.abs(X) @ mel_fb().T, 1e-5)).T[None].astype(np.float32)
    re, im = net(mel)
    Y = (re[0] + 1j * im[0]).T                                    # [T, bins]
    m = merge_mask()
    Z = X + (Y - X) * m
    fr = np.fft.irfft(Z, n=N_FFT, axis=-1) * w
    L = (nfr - 1) * HOP + N_FFT
    y, env = np.zeros(L), np.zeros(L)
    for i in range(nfr):
        y[i * HOP:i * HOP + N_FFT] += fr[i]
        env[i * HOP:i * HOP + N_FFT] += w * w
    return (y / np.maximum(env, 1e-8))[PAD:PAD + x.size].astype(np.float32)


# --------------------------------------------------------------------- graph

class G:
    def __init__(self):
        self.nodes, self.inits, self.n = [], [], 0

    def name(self, base):
        self.n += 1
        return f"bwe/{base}_{self.n}"

    def const(self, arr, base="c"):
        nm = self.name(base)
        self.inits.append(numpy_helper.from_array(np.asarray(arr), nm))
        return nm

    def i64(self, *v):
        return self.const(np.array(v, dtype=np.int64), "i")

    def op(self, op, ins, n_out=1, **attrs):
        outs = [self.name(op.lower()) for _ in range(n_out)]
        self.nodes.append(helper.make_node(op, ins, outs, **attrs))
        return outs[0] if n_out == 1 else outs

    def slice(self, x, start, end, axis, step=1):
        return self.op("Slice", [x, self.i64(start), self.i64(end), self.i64(axis), self.i64(step)])


def ola(g, frames4, tpad_axis=1):
    """Overlap-add of frames [1, T, 4, HOP] at hop HOP -> [1, (T+3)*HOP]."""
    total = None
    for j in range(4):
        s = g.op("Squeeze", [g.slice(frames4, j, j + 1, 2), g.i64(2)])     # [1,T,HOP]
        s = g.op("Pad", [s, g.i64(0, j, 0, 0, 3 - j, 0)])                 # [1,T+3,HOP]
        total = s if total is None else g.op("Add", [total, s])
    return g.op("Reshape", [total, g.i64(1, -1)])


def load_net(models):
    bb = onnx.load(f"{models}/enhancer_backbone.onnx")
    hd = onnx.load(f"{models}/enhancer_spec_head.onnx")
    bb = onnx.compose.add_prefix(bb, "bb/")
    hd = onnx.compose.add_prefix(hd, "hd/")
    return bb, hd


def build(models):
    bb, hd = load_net(models)
    g = G()
    # ---- 8 kHz -> 48 kHz
    h, delay = resample_kernel()
    x = g.op("Reshape", ["pcm", g.i64(1, 1, -1)])
    up = g.op("ConvTranspose", [x, g.const(h.reshape(1, 1, -1), "lp")],
              strides=[UP], kernel_shape=[h.size])                  # [1,1,(N-1)*6+K]
    n_in = g.op("Shape", ["pcm"])
    m48 = g.op("Mul", [n_in, g.i64(UP)])                              # [1] = 6N
    up = g.op("Slice", [up, g.i64(delay), g.op("Add", [m48, g.i64(delay)]), g.i64(2)])
    # ConvTranspose leaves the last (UP-1) zero-stuffed outputs out compared
    # with zero-stuffing then convolving; the slice above reads only the first
    # 6N, which ConvTranspose computes in full.
    x48 = g.op("Reshape", [up, g.i64(1, -1)])                         # [1,M]
    # ---- STFT
    xp = g.op("Pad", [x48, g.i64(0, PAD, 0, PAD)], mode="reflect")
    sig = g.op("Unsqueeze", [xp, g.i64(2)])                           # [1,L,1]
    win = g.const(hann(N_FFT), "hann")
    spec = g.op("STFT", [sig, g.i64(HOP), win, g.i64(N_FFT)], onesided=1)   # [1,T,1025,2]
    xr = g.op("Squeeze", [g.slice(spec, 0, 1, 3), g.i64(3)])           # [1,T,1025]
    xi = g.op("Squeeze", [g.slice(spec, 1, 2, 3), g.i64(3)])
    mag = g.op("Sqrt", [g.op("Add", [g.op("Mul", [xr, xr]), g.op("Mul", [xi, xi])])])
    mel = g.op("MatMul", [mag, g.const(mel_fb().T.copy(), "mel_fb")])  # [1,T,80]
    mel = g.op("Log", [g.op("Max", [mel, g.const(np.array(1e-5, np.float32))])])
    mel = g.op("Transpose", [mel], perm=[0, 2, 1])                     # [1,80,T]
    # ---- the network (backbone then head), inlined
    g.nodes.append(helper.make_node("Identity", [mel], ["bb/mel"]))
    g.nodes.extend(bb.graph.node)
    g.inits.extend(bb.graph.initializer)
    g.nodes.append(helper.make_node("Identity", ["bb/hidden"], ["hd/hidden"]))
    g.nodes.extend(hd.graph.node)
    g.inits.extend(hd.graph.initializer)
    yr = g.op("Transpose", ["hd/real"], perm=[0, 2, 1])                # [1,T,1025]
    yi = g.op("Transpose", ["hd/imag"], perm=[0, 2, 1])
    # ---- keep what was received, add the upper band
    mask = g.const(merge_mask(), "mask")
    zr = g.op("Add", [xr, g.op("Mul", [g.op("Sub", [yr, xr]), mask])])
    zi = g.op("Add", [xi, g.op("Mul", [g.op("Sub", [yi, xi]), mask])])
    # ---- inverse STFT: mirror to the full spectrum, inverse DFT, overlap-add
    half = N_FFT // 2
    fr = g.op("Concat", [zr, g.slice(zr, half - 1, 0, 2, -1)], axis=2)
    fi = g.op("Concat", [zi, g.op("Neg", [g.slice(zi, half - 1, 0, 2, -1)])], axis=2)
    full = g.op("Concat", [g.op("Unsqueeze", [fr, g.i64(3)]),
                           g.op("Unsqueeze", [fi, g.i64(3)])], axis=3)   # [1,T,2048,2]
    td = g.op("DFT", [full], axis=2, inverse=1, onesided=0)
    td = g.op("Squeeze", [g.slice(td, 0, 1, 3), g.i64(3)])             # [1,T,2048]
    frames = g.op("Mul", [td, win])
    num = ola(g, g.op("Reshape", [frames, g.i64(1, -1, 4, HOP)]))
    w2 = g.op("Expand", [g.const(hann(N_FFT) ** 2, "hann2"), g.op("Shape", [frames])])
    den = ola(g, g.op("Reshape", [w2, g.i64(1, -1, 4, HOP)]))
    y = g.op("Div", [num, g.op("Max", [den, g.const(np.array(1e-8, np.float32))])])
    y = g.op("Slice", [y, g.i64(PAD), g.op("Add", [m48, g.i64(PAD)]), g.i64(1)])
    g.nodes.append(helper.make_node("Reshape", [y, g.i64(-1)], ["audio"]))

    graph = helper.make_graph(
        g.nodes, "voice_bwe",
        [helper.make_tensor_value_info("pcm", TensorProto.FLOAT, ["n"])],
        [helper.make_tensor_value_info("audio", TensorProto.FLOAT, ["m"])],
        g.inits)
    model = helper.make_model(graph, opset_imports=[helper.make_opsetid("", OPSET)],
                              producer_name="meshcore-open-tak voice_bwe_to_onnx.py")
    model.ir_version = 8
    onnx.checker.check_model(model)
    return model


def half_weights(model, min_size=4096):
    """Stores float32 initializers of [min_size] or more values as float16,
    each read through a Cast back to float32."""
    g = model.graph
    keep, casts = [], []
    for t in g.initializer:
        a = numpy_helper.to_array(t)
        if a.dtype != np.float32 or a.size < min_size:
            keep.append(t)
            continue
        keep.append(numpy_helper.from_array(a.astype(np.float16), t.name + "/f16"))
        casts.append(helper.make_node("Cast", [t.name + "/f16"], [t.name], to=TensorProto.FLOAT))
    del g.initializer[:]
    g.initializer.extend(keep)
    nodes = casts + list(g.node)
    del g.node[:]
    g.node.extend(nodes)
    onnx.checker.check_model(model)
    return model


def check(path, models):
    import onnxruntime as ort
    sess = ort.InferenceSession(path, providers=["CPUExecutionProvider"])
    bb = ort.InferenceSession(f"{models}/enhancer_backbone.onnx", providers=["CPUExecutionProvider"])
    hd = ort.InferenceSession(f"{models}/enhancer_spec_head.onnx", providers=["CPUExecutionProvider"])

    def net(mel):
        h = bb.run(None, {"mel": mel})[0]
        return hd.run(None, {"hidden": h})

    rng = np.random.default_rng(1)
    worst = 99.0
    for n in (MIN_SAMPLES, 8000, 12345):
        t = np.arange(n) / 8000.0
        pcm = (0.3 * np.sin(2 * np.pi * 220 * t) * (1 + np.sin(2 * np.pi * 3 * t))
               + 0.05 * rng.standard_normal(n)).astype(np.float32)
        y = sess.run(None, {"pcm": pcm})[0]
        assert y.shape == (UP * n,), (n, y.shape)
        ref = reference(pcm, net)
        snr = 10 * np.log10(np.sum(ref ** 2) / max(np.sum((y - ref) ** 2), 1e-20))
        worst = min(worst, snr)
        print(f"  {n} samples: {snr:.1f} dB against the numpy reference")
    return worst


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("models")
    ap.add_argument("out")
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    model = build(a.models)
    onnx.save(half_weights(model), a.out)
    if a.check:
        snr = check(a.out, a.models)
        if snr < 40.0:
            sys.exit(f"the model differs from the reference: {snr:.1f} dB < 40 dB")
        print("ok")
