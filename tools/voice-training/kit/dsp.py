"""Signal processing shared by the trainers.

The Brighter voice parts mirror Wadamesh TAK's VoxBrighten
(src/ui-touch/VoxBrighten.cpp) and its reference scripts/voice/brighten_ref.py
exactly: the same RBJ biquads, levels and frames, so a model trained here sees
on the standalone what it saw in training.
"""
import math
import os
import shutil
import subprocess
import sys

import numpy as np
from scipy.signal import lfilter, resample_poly

RATE = 16000                 # Brighter voice runs at the standalone's 16 kHz
FRAME = RATE // 100          # 10 ms
SILENCE_DB = -60.0
ACTIVE_DB = -50.0            # frames trained and scored on
MAX_GAIN_DB = 40.0
BANDS = ((4000, 5000), (5000, 6000), (6000, 7000), (7000, 7900))   # added sub-bands
ANALYSIS = (300, 600, 1000, 1500, 2000, 2500, 3000, 3500, 3900)    # the net's input bands
CONTEXT = 4                  # frames the net sees: this one and the 3 before
CODEC2_MODES = {"3200": 0, "1600": 4, "1200": 5}


# ------------------------------------------------------------------ filters

def rbj(kind, f, rate=RATE, q=0.70710678):
    w0 = 2 * math.pi * f / rate
    c, s = math.cos(w0), math.sin(w0)
    al = s / (2 * q)
    if kind == "lp":
        b = [(1 - c) / 2, 1 - c, (1 - c) / 2]
    elif kind == "hp":
        b = [(1 + c) / 2, -(1 + c), (1 + c) / 2]
    else:
        b = [al, 0.0, -al]
    a = [1 + al, -2 * c, 1 - al]
    return np.array(b) / a[0], np.array(a) / a[0]


def bandpass(lo, hi, rate=RATE):
    fc = math.sqrt(lo * hi)
    return rbj("bp", fc, rate, q=fc / (hi - lo))


def run(chain, x):
    for b, a in chain:
        x = lfilter(b, a, x)
    return x


def chains(rate=RATE):
    hp = lambda f: rbj("hp", f, rate)
    lp = lambda f: rbj("lp", f, rate)
    return {
        "src": [hp(2000), hp(2000), lp(3900), lp(3900)],
        "lo": [hp(300), lp(1000)],
        "dc": [hp(100)],
        "hb": [hp(4000), hp(4000)],
        "bands": [[bandpass(lo, hi, rate)] * 2 for lo, hi in BANDS],
        "analysis": [[bandpass(lo, hi, rate)] * 2 for lo, hi in zip(ANALYSIS[:-1], ANALYSIS[1:])],
    }


def frames_db(x, n=FRAME):
    k = x.size // n
    e = (x[: k * n].reshape(k, n) ** 2).mean(1)
    return 10 * np.log10(e / 32768.0 ** 2 + 1e-12)


def soft_limit(v, knee=24000.0, ceil=32000.0):
    m = np.abs(v)
    e = np.maximum(m - knee, 0)
    r = np.where(m > knee, knee + (ceil - knee) * e / (e + (ceil - knee)), m)
    return np.sign(v) * r


# ---------------------------------------------------- the standalone's playback

def play_gain(pcm8k):
    pk = np.abs(pcm8k[: 3 * 8000]).max() if pcm8k.size else 0
    return 1.0 if pk <= 0 else float(np.clip(23000.0 / pk, 1, 6))


def play_out(pcm8k, rate=RATE):
    """VoxPlayOut: level, linear interpolation to `rate`, RBJ low-pass at
    3.6 kHz, soft limit."""
    cur = pcm8k.astype(np.float64) * play_gain(pcm8k)
    step = 8000 / rate
    t = np.arange(int(cur.size / step)) * step
    i = np.floor(t).astype(int)
    fr = t - i
    prev = np.concatenate([[0.0], cur])
    y = prev[i] + (prev[i + 1] - prev[i]) * fr
    return soft_limit(lfilter(*rbj("lp", 3600, rate), y))


def analyse(x, rate=RATE):
    """Per-frame levels of played-out voice: m (2-3.9 kHz), l (300-1000 Hz),
    the 8 analysis bands, and the excitation's 4 sub-bands (signals + levels)."""
    ch = chains(rate)
    s = run(ch["src"], x)
    l = run(ch["lo"], x)
    e = run(ch["hb"], run(ch["dc"], np.abs(s)))
    bands = [run(c, e) for c in ch["bands"]]
    ana = np.stack([frames_db(run(c, x)) for c in ch["analysis"]], 1)
    return {
        "m": frames_db(s), "l": frames_db(l), "ana": ana,
        "bands": bands, "lev": np.stack([frames_db(b) for b in bands], 1),
    }


def net_inputs(a):
    """The net's input per frame: [m, l, 8 analysis levels] scaled
    (dB + 50) / 20, for this frame and the CONTEXT-1 before (zeros before the
    start, as the standalone's history starts)."""
    f = (np.c_[a["m"], a["l"], a["ana"]] + 50.0) / 20.0          # [T, 10]
    T, d = f.shape
    pad = np.vstack([np.full((CONTEXT - 1, d), (-120.0 + 50.0) / 20.0), f])
    return np.hstack([pad[CONTEXT - 1 - k: CONTEXT - 1 - k + T] for k in range(CONTEXT)]).astype(np.float32)


def rule_targets(m, l, coef):
    return np.stack([m + a + b * (m - l) + c * (l + 30) for a, b, c in coef], 1)


def apply_targets(x, a, t):
    """Brighter voice with given per-frame sub-band targets [T, 4] (dBFS),
    without the standalone's one frame of latency."""
    g = 10 ** (np.minimum(t - a["lev"], MAX_GAIN_DB) / 20)
    g[a["m"] < SILENCE_DB] = 0
    k = g.shape[0]
    prev = np.vstack([np.zeros((1, 4)), g[:-1]])
    ramp = (np.arange(1, FRAME + 1) / FRAME)[None, :, None]
    gs = (prev[:, None, :] + (g - prev)[:, None, :] * ramp).reshape(k * FRAME, 4)
    y = x[: k * FRAME].copy()
    for j in range(4):
        y += gs[:, j] * a["bands"][j][: k * FRAME]
    return soft_limit(y)


# ------------------------------------------------------------------- Codec2

def c2round_path():
    here = os.path.dirname(os.path.abspath(__file__))
    for p in (os.environ.get("C2ROUND"),
              os.path.join(here, "..", "bin", "c2round.exe"),
              os.path.join(here, "..", "bin", "c2round"),
              shutil.which("c2round")):
        if p and os.path.exists(p):
            return p
    sys.exit("c2round not found: it ships in the kit's bin folder (or set C2ROUND)")


def codec2(x8, mode="1200"):
    """Codec2 encode + decode of 8 kHz floats (-1..1); returns int16."""
    pcm = (np.clip(x8, -1, 1) * 32767).astype("<i2").tobytes()
    r = subprocess.run([c2round_path(), str(CODEC2_MODES[mode]), "-", "-"], input=pcm,
                       capture_output=True, check=True)
    return np.frombuffer(r.stdout, "<i2").copy()


def lag_of(decoded, ref, rate, max_lag):
    """How many samples `decoded` is behind `ref` (low-band correlation)."""
    lp = rbj("lp", 1500, rate)
    n = min(decoded.size, ref.size) - max_lag
    if n <= rate // 4:
        return 0
    d = lfilter(*lp, decoded[max_lag: max_lag + n].astype(np.float64))
    r = lfilter(*lp, ref[: n + max_lag].astype(np.float64))
    best = max(range(max_lag), key=lambda k: float(np.dot(d, r[max_lag - k: max_lag - k + n])))
    return best


def load(path, rate):
    import soundfile as sf
    x, sr = sf.read(path, dtype="float64", always_2d=True)
    x = x.mean(1)
    if sr != rate:
        g = math.gcd(sr, rate)
        x = resample_poly(x, rate // g, sr // g)
    return x
