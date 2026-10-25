"""Downloads and prepares the speech the trainers learn from.

Brighter voice net: LibriTTS-R dev-clean and test-clean (CC-BY-4.0, about
2.4 GB, 24 kHz, 80 speakers, women and men), https://www.openslr.org/141/.
Voice restorer: VCTK 0.92 (CC-BY-4.0, about 11 GB, 48 kHz, 110 speakers,
women and men), https://datashare.ed.ac.uk/handle/10283/3443.

Every clip is run through our Codec2 (kit/bin/c2round, the app's and the
standalones' Codec2) at 1200 (most), 1600 or 3200, and the result is stored
next to the clean original, lined up in time.
"""
import glob
import hashlib
import os
import random
import sys
import tarfile
import time
import urllib.request
import zipfile
from multiprocessing import Pool

import numpy as np

from . import dsp

LIBRITTS_R = [
    ("dev_clean.tar.gz", ["https://www.openslr.org/resources/141/dev_clean.tar.gz",
                          "https://us.openslr.org/resources/141/dev_clean.tar.gz",
                          "https://openslr.trmal.net/resources/141/dev_clean.tar.gz"]),
    ("test_clean.tar.gz", ["https://www.openslr.org/resources/141/test_clean.tar.gz",
                           "https://us.openslr.org/resources/141/test_clean.tar.gz",
                           "https://openslr.trmal.net/resources/141/test_clean.tar.gz"]),
]
VCTK = ("VCTK-Corpus-0.92.zip", ["https://datashare.ed.ac.uk/bitstream/handle/10283/3443/VCTK-Corpus-0.92.zip"])

MODE_WEIGHTS = (("1200", 0.6), ("1600", 0.2), ("3200", 0.2))


def pick_mode(rng):
    r, acc = rng.random(), 0.0
    for m, w in MODE_WEIGHTS:
        acc += w
        if r < acc:
            return m
    return "1200"


# ------------------------------------------------------------------ download

def download(name, urls, dest):
    """Fetches `name` into `dest`, resuming a part-finished download."""
    os.makedirs(dest, exist_ok=True)
    path = os.path.join(dest, name)
    if os.path.exists(path):
        return path
    part = path + ".part"
    for url in urls:
        try:
            have = os.path.getsize(part) if os.path.exists(part) else 0
            req = urllib.request.Request(url, headers={"Range": f"bytes={have}-"} if have else {})
            with urllib.request.urlopen(req, timeout=60) as r:
                if have and r.status != 206:
                    have = 0           # the server ignored the range: start over
                total = have + int(r.headers.get("Content-Length", 0) or 0)
                with open(part, "ab" if have else "wb") as f:
                    done, t0, last = have, time.time(), 0.0
                    while True:
                        b = r.read(1 << 20)
                        if not b:
                            break
                        f.write(b)
                        done += len(b)
                        if time.time() - last > 1:
                            last = time.time()
                            mb = done / 1e6
                            rate = (done - have) / 1e6 / max(time.time() - t0, 1e-3)
                            pct = f"{100 * done / total:5.1f}%" if total else ""
                            print(f"\r  {name}: {mb:8.0f} MB {pct}  {rate:5.1f} MB/s", end="", flush=True)
            print()
            os.replace(part, path)
            return path
        except Exception as e:  # try the next mirror; the .part is kept
            print(f"\n  {url}: {e}")
    sys.exit(f"Couldn't download {name}. Check the connection and run this again; it resumes.")


def fetch(name, urls, root, dest):
    """Downloads and unpacks `name` into `dest` once; the archive is deleted
    after unpacking to save disk space."""
    done = os.path.join(dest, name + ".done")
    if os.path.exists(done):
        return
    archive = download(name, urls, os.path.join(root, "downloads"))
    print(f"  unpacking {name} (a few minutes)")
    os.makedirs(dest, exist_ok=True)
    if archive.endswith(".zip"):
        with zipfile.ZipFile(archive) as z:
            z.extractall(dest)
    else:
        with tarfile.open(archive) as t:
            t.extractall(dest, filter="data")
    open(done, "w").close()
    os.remove(archive)


# ------------------------------------------------- Brighter voice (16 kHz)

def _bright_one(args):
    path, seed = args
    rng = random.Random(seed)
    w = dsp.load(path, dsp.RATE)
    if w.size < dsp.RATE // 2 or np.abs(w).max() <= 0:
        return None
    w = w / np.abs(w).max() * rng.uniform(0.3, 0.95)
    from scipy.signal import resample_poly
    c8 = dsp.codec2(resample_poly(w, 1, 2), pick_mode(rng))
    y = dsp.play_out(c8)
    ref = w * 32767 * dsp.play_gain(c8)
    lag = dsp.lag_of(y, ref, dsp.RATE, 800)
    ref = np.concatenate([np.zeros(lag), ref])[: y.size]
    a = dsp.analyse(y)
    ch = dsp.chains()
    true = np.stack([dsp.frames_db(dsp.run(c, ref)) for c in ch["bands"]], 1)
    k = min(a["m"].size, true.shape[0])
    return {
        "x": dsp.net_inputs(a)[:k],
        "m": a["m"][:k].astype(np.float32),
        "l": a["l"][:k].astype(np.float32),
        "y": (true[:k] - a["m"][:k, None]).astype(np.float32),
    }


def prepare_bright(root, workers):
    """LibriTTS-R -> per-speaker feature files in root/bright/feat/."""
    src = os.path.join(root, "librittsr")
    if not os.environ.get("KIT_OFFLINE"):   # (tests put clips there themselves)
        for name, urls in LIBRITTS_R:
            fetch(name, urls, root, src)
    out = os.path.join(root, "bright", "feat")
    os.makedirs(out, exist_ok=True)
    wavs = sorted(glob.glob(os.path.join(src, "**", "*.wav"), recursive=True))
    if not wavs:
        sys.exit("No LibriTTS-R audio found after unpacking")
    by_spk = {}
    for p in wavs:
        by_spk.setdefault(os.path.basename(p).split("_")[0], []).append(p)
    todo = [s for s in sorted(by_spk) if not os.path.exists(os.path.join(out, f"{s}.npz"))]
    print(f"  {len(wavs)} clips from {len(by_spk)} speakers; {len(todo)} speakers left to prepare")
    with Pool(max(1, workers)) as pool:
        for i, s in enumerate(todo):
            files = by_spk[s]
            seeds = [int(hashlib.md5(p.encode()).hexdigest()[:8], 16) for p in files]
            rows = [r for r in pool.map(_bright_one, list(zip(files, seeds))) if r]
            if rows:
                np.savez(os.path.join(out, f"{s}.npz"), **{k: np.concatenate([r[k] for r in rows]) for k in rows[0]})
            print(f"\r  prepared {i + 1}/{len(todo)} speakers", end="", flush=True)
    print()
    return out


# ---------------------------------------------------- Voice restorer (48 kHz)

def _restorer_one(args):
    path, out, seed = args
    dst = os.path.join(out, os.path.basename(path).rsplit(".", 1)[0] + ".npz")
    if os.path.exists(dst):
        return dst
    rng = random.Random(seed)
    w = dsp.load(path, 48000)
    if w.size < 48000 or np.abs(w).max() <= 0:
        return None
    w = w / np.abs(w).max() * rng.uniform(0.3, 0.95)
    from scipy.signal import resample_poly
    w8 = resample_poly(w, 1, 6)
    c8 = dsp.codec2(w8, pick_mode(rng))
    lag = dsp.lag_of(c8, (w8 * 32767), 8000, 400)
    # clean[t] lines up with c8[t + lag]: drop lag samples from c8's start.
    c8 = c8[lag:]
    n8 = min(c8.size, w.size // 6)
    np.savez(dst, c8=c8[:n8].astype(np.int16), clean=np.round(np.clip(w[: n8 * 6], -1, 1) * 32767).astype(np.int16))
    return dst


def prepare_restorer(root, workers):
    src = os.path.join(root, "vctk")
    if not os.environ.get("KIT_OFFLINE"):
        fetch(*VCTK, root, src)
    flacs = sorted(glob.glob(os.path.join(src, "**", "*_mic1.flac"), recursive=True))
    if not flacs:
        sys.exit("No VCTK audio (wav48_silence_trimmed/*_mic1.flac) found after unpacking")
    out = os.path.join(root, "restorer", "pairs")
    os.makedirs(out, exist_ok=True)
    jobs = [(p, out, int(hashlib.md5(p.encode()).hexdigest()[:8], 16)) for p in flacs]
    done = 0
    with Pool(max(1, workers)) as pool:
        for _ in pool.imap_unordered(_restorer_one, jobs, chunksize=16):
            done += 1
            if done % 200 == 0 or done == len(jobs):
                print(f"\r  prepared {done}/{len(jobs)} clips", end="", flush=True)
    print()
    return out


def speaker_info(root):
    """VCTK speaker -> 'F' / 'M' (for balanced validation and demos)."""
    info = {}
    for p in glob.glob(os.path.join(root, "vctk", "**", "speaker-info.txt"), recursive=True):
        for line in open(p, encoding="utf-8", errors="replace"):
            f = line.split()
            if len(f) >= 3 and f[0].startswith("p") and f[2] in ("F", "M"):
                info[f[0]] = f[2]
    return info
