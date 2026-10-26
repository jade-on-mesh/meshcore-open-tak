"""The small voice restorer for Wadamesh TAK standalones (T-Deck, T-Display P4).

A Vocos-style network like the app's restorer, about 30x smaller, so a
standalone can run it in plain C (src/ui-touch/VoxRestoreSmall.cpp):

  Codec2 at 8 kHz -> STFT (256, hop 64) -> 32 log-mel bands (0-4 kHz)
  -> conv embed -> ConvNeXt blocks -> linear head -> log-magnitude and phase
  -> inverse STFT (512, hop 128) -> 16 kHz, the standalones' speaker rate.

Both STFTs step 8 ms, so one network frame in is one frame out. Everything
here is in three forms that must agree:
  Small         the PyTorch model the kit trains (train_small.py);
  Reference     numpy, reading the exported file, the spec the firmware's C++
                follows (and what writes its host-test fixture);
  the firmware  VoxRestoreSmall.cpp, checked against Reference.

The file (vox-restorer-small.bin), little-endian:
  0   "VRS1"
  4   u32  header bytes (64)
  8   u16  in_sr, out_sr, in_nfft, in_hop, out_nfft, out_hop, n_mels, dim,
           inter, layers, kernel
  30  u16  0
  32  f32  log_mag_max (the head's log-magnitude is clipped to it)
  36  u32  number of float16 weights
  40  u32  FNV-1a of the weight bytes
  44  zeros to 64
  64  float16 weights, in this order:
        mel filterbank [n_mels][in_nfft/2+1]
        embed weight [dim][n_mels][kernel], bias [dim]
        norm weight [dim], bias [dim]
        each layer: dwconv weight [dim][kernel], bias [dim]; norm weight [dim],
          bias [dim]; pwconv1 weight [inter][dim], bias [inter]; pwconv2 weight
          [dim][inter], bias [dim]; gamma [dim]
        final norm weight [dim], bias [dim]
        out weight [out_nfft+2][dim], bias [out_nfft+2]
          (rows 0..out_nfft/2: log-magnitude; the rest: phase)
"""
import os
import struct

import numpy as np

IN_SR, OUT_SR = 8000, 16000
IN_NFFT, IN_HOP = 256, 64
OUT_NFFT, OUT_HOP = 512, 128
N_MELS = 32
KERNEL = 7
LOG_MAG_MAX = 5.0
MAGIC = b"VRS1"
HEADER = 64


def dims():
    """dim, inter, layers: KIT_SMALL_DIM / KIT_SMALL_LAYERS to try other sizes."""
    d = int(os.environ.get("KIT_SMALL_DIM", 128))
    return d, 3 * d, int(os.environ.get("KIT_SMALL_LAYERS", 4))


def hann(n):
    return (0.5 - 0.5 * np.cos(2 * np.pi * np.arange(n) / n)).astype(np.float32)


def _hz_to_mel(f):
    f = np.asarray(f, dtype=np.float64)
    return np.where(f >= 1000.0, 15.0 + np.log(np.maximum(f, 1e-9) / 1000.0) / (np.log(6.4) / 27.0),
                    f / (200.0 / 3))


def _mel_to_hz(m):
    m = np.asarray(m, dtype=np.float64)
    return np.where(m >= 15.0, 1000.0 * np.exp((np.log(6.4) / 27.0) * (m - 15.0)), (200.0 / 3) * m)


def mel_fb():
    """32 bands over 0-4 kHz, as lavasr.mel_fb makes them (numpy only, so the
    reference runs without PyTorch)."""
    freqs = np.linspace(0, IN_SR / 2, IN_NFFT // 2 + 1)
    pts = _mel_to_hz(np.linspace(_hz_to_mel(0.0), _hz_to_mel(IN_SR / 2), N_MELS + 2))
    fb = np.zeros((N_MELS, freqs.size))
    for i in range(N_MELS):
        lo, c, hi = pts[i], pts[i + 1], pts[i + 2]
        fb[i] = np.maximum(0, np.minimum((freqs - lo) / max(c - lo, 1e-12), (hi - freqs) / max(hi - c, 1e-12)))
    fb *= (2.0 / (pts[2:] - pts[:-2]))[:, None]
    return fb.astype(np.float32)


def frames_for(n8):
    """Network frames for n8 input samples (padded up to whole hops)."""
    return (n8 + IN_HOP - 1) // IN_HOP


# ------------------------------------------------------------------ PyTorch

def torch_model(dim=None, inter=None, layers=None):
    import torch
    import torch.nn as nn
    import torch.nn.functional as F

    if dim is None:
        dim, inter, layers = dims()

    class Block(nn.Module):
        def __init__(self):
            super().__init__()
            self.dwconv = nn.Conv1d(dim, dim, KERNEL, padding=KERNEL // 2, groups=dim)
            self.norm = nn.LayerNorm(dim, eps=1e-6)
            self.pwconv1 = nn.Linear(dim, inter)
            self.pwconv2 = nn.Linear(inter, dim)
            self.gamma = nn.Parameter(torch.full((dim,), 1.0 / layers))

        def forward(self, x):                       # [B, D, T]
            r = x
            x = self.dwconv(x).transpose(1, 2)
            x = self.pwconv2(F.gelu(self.pwconv1(self.norm(x))))
            return r + (self.gamma * x).transpose(1, 2)

    class Small(nn.Module):
        """8 kHz samples [B, N] -> 16 kHz [B, 2N]."""

        def __init__(self):
            super().__init__()
            self.dim, self.inter, self.layers = dim, inter, layers
            self.register_buffer("fb", torch.from_numpy(mel_fb()))
            self.register_buffer("win_in", torch.from_numpy(hann(IN_NFFT)))
            self.register_buffer("win_out", torch.from_numpy(hann(OUT_NFFT)))
            self.embed = nn.Conv1d(N_MELS, dim, KERNEL, padding=KERNEL // 2)
            self.norm = nn.LayerNorm(dim, eps=1e-6)
            self.blocks = nn.ModuleList([Block() for _ in range(layers)])
            self.final_norm = nn.LayerNorm(dim, eps=1e-6)
            self.out = nn.Linear(dim, OUT_NFFT + 2)

        def mel(self, x8):
            p = (IN_NFFT - IN_HOP) // 2
            xp = F.pad(x8.unsqueeze(1), (p, p), mode="reflect")[:, 0]
            s = torch.stft(xp, IN_NFFT, IN_HOP, window=self.win_in, center=False, return_complex=True)
            return torch.log(torch.clamp(self.fb @ s.abs(), min=1e-5))       # [B, n_mels, T]

        def spec(self, mel):
            x = self.norm(self.embed(mel).transpose(1, 2)).transpose(1, 2)
            for b in self.blocks:
                x = b(x)
            h = self.out(self.final_norm(x.transpose(1, 2))).transpose(1, 2)  # [B, out_nfft+2, T]
            lm, ph = h.chunk(2, dim=1)
            mag = torch.exp(torch.clamp(lm, max=LOG_MAG_MAX))
            return torch.complex(mag * torch.cos(ph), mag * torch.sin(ph))

        def istft(self, spec, n):
            fr = torch.fft.irfft(spec.transpose(1, 2), n=OUT_NFFT) * self.win_out
            B, T, _ = fr.shape
            L = (T - 1) * OUT_HOP + OUT_NFFT
            y = F.fold(fr.transpose(1, 2), (1, L), (1, OUT_NFFT), stride=(1, OUT_HOP))[:, 0, 0]
            env = F.fold((self.win_out ** 2).view(1, -1, 1).expand(1, OUT_NFFT, T), (1, L), (1, OUT_NFFT),
                         stride=(1, OUT_HOP))[:, 0, 0]
            y = y / torch.clamp(env, min=1e-8)
            p = (OUT_NFFT - OUT_HOP) // 2
            return y[:, p: p + n]

        def forward(self, x8):
            n = x8.shape[-1]
            pad = -n % IN_HOP                   # whole hops, zeros after, as the reference
            if pad:
                x8 = F.pad(x8, (0, pad))
            return self.istft(self.spec(self.mel(x8)), 2 * x8.shape[-1])[:, : 2 * n]

    return Small()


def weights_in_order(m):
    """The model's arrays in the file's order (numpy, float32)."""
    g = lambda t: t.detach().float().cpu().numpy()
    out = [mel_fb(), g(m.embed.weight), g(m.embed.bias), g(m.norm.weight), g(m.norm.bias)]
    for b in m.blocks:
        out += [g(b.dwconv.weight)[:, 0, :], g(b.dwconv.bias), g(b.norm.weight), g(b.norm.bias),
                g(b.pwconv1.weight), g(b.pwconv1.bias), g(b.pwconv2.weight), g(b.pwconv2.bias), g(b.gamma)]
    out += [g(m.final_norm.weight), g(m.final_norm.bias), g(m.out.weight), g(m.out.bias)]
    return out


def fnv1a(b):
    h = 0x811C9DC5
    for x in b:
        h = ((h ^ x) * 0x01000193) & 0xFFFFFFFF
    return h


def write_file(path, arrays, dim, inter, layers):
    w = np.concatenate([a.reshape(-1) for a in arrays]).astype("<f2")
    blob = w.tobytes()
    hdr = MAGIC + struct.pack("<I11HH", HEADER, IN_SR, OUT_SR, IN_NFFT, IN_HOP, OUT_NFFT, OUT_HOP, N_MELS, dim,
                              inter, layers, KERNEL, 0)
    hdr += struct.pack("<fII", LOG_MAG_MAX, w.size, fnv1a(blob))
    hdr += b"\0" * (HEADER - len(hdr))
    with open(path + ".tmp", "wb") as f:
        f.write(hdr + blob)
    os.replace(path + ".tmp", path)


def load_into_torch(m, path):
    """Copies the file's (float16-rounded) weights into model `m`."""
    import torch
    ref = Reference(path)
    with torch.no_grad():
        m.embed.weight.copy_(torch.from_numpy(ref.embed_w)); m.embed.bias.copy_(torch.from_numpy(ref.embed_b))
        m.norm.weight.copy_(torch.from_numpy(ref.norm_w)); m.norm.bias.copy_(torch.from_numpy(ref.norm_b))
        for b, L in zip(m.blocks, ref.blocks):
            b.dwconv.weight.copy_(torch.from_numpy(L["dw_w"][:, None, :])); b.dwconv.bias.copy_(torch.from_numpy(L["dw_b"]))
            b.norm.weight.copy_(torch.from_numpy(L["ln_w"])); b.norm.bias.copy_(torch.from_numpy(L["ln_b"]))
            b.pwconv1.weight.copy_(torch.from_numpy(L["w1"])); b.pwconv1.bias.copy_(torch.from_numpy(L["b1"]))
            b.pwconv2.weight.copy_(torch.from_numpy(L["w2"])); b.pwconv2.bias.copy_(torch.from_numpy(L["b2"]))
            b.gamma.copy_(torch.from_numpy(L["gamma"]))
        m.final_norm.weight.copy_(torch.from_numpy(ref.fln_w)); m.final_norm.bias.copy_(torch.from_numpy(ref.fln_b))
        m.out.weight.copy_(torch.from_numpy(ref.out_w)); m.out.bias.copy_(torch.from_numpy(ref.out_b))
        m.fb.copy_(torch.from_numpy(ref.fb))
    return m


# ---------------------------------------------------------- numpy reference

def _gelu(x):
    from scipy.special import erf
    return 0.5 * x * (1 + erf(x / np.sqrt(2)))


def _ln(x, w, b):
    mu = x.mean(-1, keepdims=True)
    v = ((x - mu) ** 2).mean(-1, keepdims=True)
    return (x - mu) / np.sqrt(v + 1e-6) * w + b


def _conv_t(x, w, b):
    """x [T, C_in] zero-padded conv over time with w [C_out, C_in, K] -> [T, C_out]."""
    T = x.shape[0]
    k = w.shape[2]
    xp = np.concatenate([np.zeros((k // 2, x.shape[1])), x, np.zeros((k // 2, x.shape[1]))])
    y = np.tile(b, (T, 1)).astype(np.float64)
    for j in range(k):
        y += xp[j: j + T] @ w[:, :, j].T
    return y


class Reference:
    """The exported file, run in numpy (float64) exactly as the firmware runs it."""

    def __init__(self, path):
        raw = open(path, "rb").read()
        if raw[:4] != MAGIC:
            raise ValueError("not a small restorer file")
        h = struct.unpack("<I11HH", raw[4:32])
        hb, self.in_sr, self.out_sr, in_nfft, in_hop, out_nfft, out_hop, n_mels, dim, inter, layers, k, _ = h
        assert (in_nfft, in_hop, out_nfft, out_hop, k) == (IN_NFFT, IN_HOP, OUT_NFFT, OUT_HOP, KERNEL)
        self.log_mag_max, n, chk = struct.unpack("<fII", raw[32:44])
        blob = raw[hb: hb + 2 * n]
        if len(blob) != 2 * n or fnv1a(blob) != chk:
            raise ValueError("small restorer file is damaged")
        w = np.frombuffer(blob, "<f2").astype(np.float32)
        pos = 0

        def take(*shape):
            nonlocal pos
            c = int(np.prod(shape))
            a = w[pos: pos + c].reshape(shape)
            pos += c
            return a.copy()

        nb = in_nfft // 2 + 1
        self.dim, self.inter, self.layers, self.n_mels = dim, inter, layers, n_mels
        self.fb = take(n_mels, nb)
        self.embed_w, self.embed_b = take(dim, n_mels, k), take(dim)
        self.norm_w, self.norm_b = take(dim), take(dim)
        self.blocks = []
        for _ in range(layers):
            self.blocks.append(dict(dw_w=take(dim, k), dw_b=take(dim), ln_w=take(dim), ln_b=take(dim),
                                    w1=take(inter, dim), b1=take(inter), w2=take(dim, inter), b2=take(dim),
                                    gamma=take(dim)))
        self.fln_w, self.fln_b = take(dim), take(dim)
        self.out_w, self.out_b = take(out_nfft + 2, dim), take(out_nfft + 2)
        assert pos == w.size

    def params(self):
        n = self.embed_w.size + self.embed_b.size + 2 * self.dim + 2 * self.dim + self.out_w.size + self.out_b.size
        return n + sum(sum(a.size for a in L.values()) for L in self.blocks)

    def macs_per_second(self):
        per = self.n_mels * self.dim * KERNEL + self.layers * (self.dim * KERNEL + 2 * self.dim * self.inter) \
            + self.dim * (OUT_NFFT + 2)
        return per * IN_SR // IN_HOP

    def run(self, x8):
        """8 kHz float samples (any length) -> 16 kHz float samples (twice as many)."""
        x8 = np.asarray(x8, np.float64)
        n = x8.size
        npad = -(-n // IN_HOP) * IN_HOP
        x = np.concatenate([x8, np.zeros(npad - n)])
        p = (IN_NFFT - IN_HOP) // 2
        xp = np.pad(x, p, mode="reflect")
        T = (xp.size - IN_NFFT) // IN_HOP + 1
        win = hann(IN_NFFT).astype(np.float64)
        fr = np.stack([xp[t * IN_HOP: t * IN_HOP + IN_NFFT] * win for t in range(T)])
        mag = np.abs(np.fft.rfft(fr, axis=1))                          # [T, 129]
        mel = np.log(np.maximum(mag @ self.fb.T.astype(np.float64), 1e-5))  # [T, n_mels]
        h = _ln(_conv_t(mel, self.embed_w, self.embed_b), self.norm_w, self.norm_b)
        for L in self.blocks:
            d = _conv_t(h, L["dw_w"][:, None, :] * np.eye(self.dim)[:, :, None], L["dw_b"])
            y = _gelu(_ln(d, L["ln_w"], L["ln_b"]) @ L["w1"].T + L["b1"]) @ L["w2"].T + L["b2"]
            h = h + L["gamma"] * y
        o = _ln(h, self.fln_w, self.fln_b) @ self.out_w.T + self.out_b       # [T, out_nfft+2]
        nb = OUT_NFFT // 2 + 1
        m = np.exp(np.minimum(o[:, :nb], self.log_mag_max))
        spec = m * np.exp(1j * o[:, nb:])
        frames = np.fft.irfft(spec, n=OUT_NFFT, axis=1) * hann(OUT_NFFT)
        L = (T - 1) * OUT_HOP + OUT_NFFT
        y = np.zeros(L)
        env = np.zeros(L)
        w2 = hann(OUT_NFFT).astype(np.float64) ** 2
        for t in range(T):
            y[t * OUT_HOP: t * OUT_HOP + OUT_NFFT] += frames[t]
            env[t * OUT_HOP: t * OUT_HOP + OUT_NFFT] += w2
        y /= np.maximum(env, 1e-8)
        q = (OUT_NFFT - OUT_HOP) // 2
        return y[q: q + 2 * n]
