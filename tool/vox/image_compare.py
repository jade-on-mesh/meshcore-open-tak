#!/usr/bin/env python3
"""MeshCore Open VOX - image codec comparison at a fixed byte budget.

Every codec gets the same budget as a full-length voice message (~2.75 KB).
For each codec and test photo we try a range of sizes, pick the best quality
that fits, scale the result back to the original size (as the phone would
display it) and score it against the original.

Only accuracy-first codecs: classic codecs plus learned codecs trained on
MSE, which blur when starved rather than invent detail.

usage: image_compare.py OUT_DIR [BUDGET_BYTES]
"""

import io
import json
import math
import os
import subprocess
import sys
import tempfile
import time
import urllib.request

import numpy as np
from PIL import Image

OUT = sys.argv[1]
BUDGET = int(sys.argv[2]) if len(sys.argv) > 2 else 2750
LONG_SIDES = [256, 320, 384, 448, 512, 576, 640, 768]

# Kodak PhotoCD test set (released for unrestricted use).
KODAK = {
    "kodim15": "Face",
    "kodim23": "Parrots",
    "kodim21": "Lighthouse",
    "kodim08": "Houses (fine detail)",
    "kodim05": "Motorbikes",
    "kodim13": "Mountain stream",
    "kodim14": "Rafting",
    "kodim20": "Airplane",
}

os.makedirs(OUT, exist_ok=True)
TMP = tempfile.mkdtemp()


def log(*a):
    print(*a, flush=True)


def load_images():
    imgs = {}
    extra = os.environ.get("EXTRA_IMAGES_DIR")
    for name in KODAK:
        url = f"http://r0k.us/graphics/kodak/kodak/{name}.png"
        data = urllib.request.urlopen(url, timeout=60).read()
        imgs[name] = Image.open(io.BytesIO(data)).convert("RGB")
    if extra and os.path.isdir(extra):
        for f in sorted(os.listdir(extra)):
            try:
                im = Image.open(os.path.join(extra, f)).convert("RGB")
            except Exception:
                continue
            im.thumbnail((768, 768), Image.LANCZOS)
            name = os.path.splitext(f)[0]
            imgs[name] = im
            KODAK[name] = name
    return imgs


def resize_long(im, long_side):
    w, h = im.size
    s = long_side / max(w, h)
    if s >= 1:
        return im.copy()
    return im.resize((max(8, round(w * s)), max(8, round(h * s))), Image.LANCZOS)


# ----------------------------------------------------------------- metrics

import torch  # noqa: E402
from pytorch_msssim import ms_ssim  # noqa: E402


def to_t(im):
    a = np.asarray(im, dtype=np.float32) / 255.0
    return torch.from_numpy(a).permute(2, 0, 1).unsqueeze(0)


def psnr_y(a, b):
    def y(im):
        x = np.asarray(im, dtype=np.float64)
        return 0.299 * x[..., 0] + 0.587 * x[..., 1] + 0.114 * x[..., 2]

    mse = np.mean((y(a) - y(b)) ** 2)
    return 99.0 if mse == 0 else 10 * math.log10(255 ** 2 / mse)


def score(orig, dec):
    dec = dec.resize(orig.size, Image.LANCZOS) if dec.size != orig.size else dec
    with torch.no_grad():
        m = ms_ssim(to_t(orig), to_t(dec), data_range=1.0).item()
    return dec, psnr_y(orig, dec), m


# ------------------------------------------------------------ classic codecs


def bisect_quality(lo, hi, enc, integer=True):
    """Largest quality in [lo, hi] whose encoding fits BUDGET (enc -> bytes)."""
    best = None
    a, b = lo, hi
    for _ in range(12):
        if integer and a > b:
            break
        q = (a + b) // 2 if integer else (a + b) / 2
        data = enc(q)
        if data is not None and len(data) <= BUDGET:
            best = (q, data)
            a = q + 1 if integer else q
        else:
            b = q - 1 if integer else q
        if not integer and b - a < 0.02:
            break
    return best


def pil_codec(fmt, **opts):
    def encode(im):
        def enc(q):
            buf = io.BytesIO()
            im.save(buf, fmt, quality=int(q), **opts)
            return buf.getvalue()

        best = bisect_quality(1, 95, enc)
        if best is None:
            return None
        q, data = best
        return data, Image.open(io.BytesIO(data)).convert("RGB"), f"q{q}"

    return encode


def run(cmd):
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def jxl_encode(im):
    src = os.path.join(TMP, "in.png")
    im.save(src)
    out = os.path.join(TMP, "o.jxl")

    def enc(d):
        # Larger distance = smaller file; bisect on -distance via negation.
        run(["cjxl", src, out, "-e", "9", "-d", f"{-d:.3f}"])
        return open(out, "rb").read()

    best = bisect_quality(-25.0, -0.5, enc, integer=False)
    if best is None:
        return None
    d, data = best
    open(out, "wb").write(data)
    png = os.path.join(TMP, "o_jxl.png")
    run(["djxl", out, png])
    return data, Image.open(png).convert("RGB"), f"d{-d:.2f}"


def mdat_payload(data):
    i = data.find(b"mdat")
    if i < 4:
        return len(data)
    return int.from_bytes(data[i - 4:i], "big") - 8


def avif_encode(stripped):
    def encode(im):
        src = os.path.join(TMP, "in.png")
        im.save(src)
        out = os.path.join(TMP, "o.avif")

        def enc(q):
            run([
                "avifenc", "-s", "0", "-y", "420", "-q", str(q),
                "-a", "tune=ssim", "--ignore-exif", "--ignore-xmp", src, out,
            ])
            data = open(out, "rb").read()
            if stripped:
                # Only the AV1 payload + a few bytes of our own header goes on
                # air; the receiver rebuilds the AVIF container.
                return b"\0" * (mdat_payload(data) + 6)
            return data

        best = bisect_quality(0, 100, enc)
        if best is None:
            return None
        q, sized = best
        enc(q)
        png = os.path.join(TMP, "o_avif.png")
        run(["avifdec", out, png])
        return sized, Image.open(png).convert("RGB"), f"q{q}"

    return encode


# ------------------------------------------------------------ learned codecs

import compressai  # noqa: E402
from compressai.zoo import cheng2020_anchor, mbt2018_mean  # noqa: E402

torch.set_num_threads(os.cpu_count() or 2)
_models = {}


def get_model(kind, q):
    key = (kind, q)
    if key not in _models:
        fn = {"mbt": mbt2018_mean, "cheng": cheng2020_anchor}[kind]
        _models[key] = fn(quality=q, metric="mse", pretrained=True).eval()
    return _models[key]


def pad64(x):
    h, w = x.shape[2:]
    H, W = (h + 63) // 64 * 64, (w + 63) // 64 * 64
    return torch.nn.functional.pad(x, (0, W - w, 0, H - h), mode="replicate"), h, w


def learned_encode(kind, qualities):
    timings = []

    def encode_at(im, q):
        net = get_model(kind, q)
        x, h, w = pad64(to_t(im))
        with torch.no_grad():
            t0 = time.time()
            out = net.compress(x)
            t1 = time.time()
            rec = net.decompress(out["strings"], out["shape"])["x_hat"]
            t2 = time.time()
        timings.append((im.size, t1 - t0, t2 - t1))
        nbytes = sum(len(s[0]) for s in out["strings"]) + 4  # + w,h header
        rec = rec[:, :, :h, :w].clamp(0, 1)[0].permute(1, 2, 0).numpy()
        return nbytes, Image.fromarray((rec * 255 + 0.5).astype(np.uint8))

    def est_bytes(im, q):
        net = get_model(kind, q)
        x, _, _ = pad64(to_t(im))
        with torch.no_grad():
            lk = net(x)["likelihoods"]
        bits = sum((-torch.log2(v.clamp_min(1e-9))).sum().item() for v in lk.values())
        return bits / 8 + 12

    def encode(orig):
        candidates = []
        for q in qualities:
            fit = None
            for ls in LONG_SIDES:
                im = resize_long(orig, ls)
                if est_bytes(im, q) <= BUDGET:
                    fit = ls
                else:
                    break
            if fit is None:
                continue
            # Verify with the real coder; step down if the estimate was short.
            idx = LONG_SIDES.index(fit)
            while idx >= 0:
                im = resize_long(orig, LONG_SIDES[idx])
                n, rec = encode_at(im, q)
                if n <= BUDGET:
                    candidates.append((n, rec, im.size, f"q{q}"))
                    break
                idx -= 1
        return candidates

    encode.timings = timings
    return encode


# --------------------------------------------------------------------- main

CLASSIC = {
    "JPEG": pil_codec("JPEG", optimize=True, progressive=True, subsampling=2),
    "WebP": pil_codec("WEBP", method=6),
    "JPEG XL": jxl_encode,
    "AVIF": avif_encode(stripped=False),
    "AVIF (container stripped)": avif_encode(stripped=True),
}
LEARNED = {
    "Neural: Hyperprior (mbt2018-mean)": learned_encode("mbt", [1, 2, 3]),
    "Neural: Cheng2020 (anchor)": learned_encode("cheng", [1, 2, 3]),
}


def main():
    imgs = load_images()
    results = {"budget": BUDGET, "images": {}, "codecs": list(CLASSIC) + list(LEARNED)}
    for name, orig in imgs.items():
        log(f"== {name} {orig.size}")
        d = os.path.join(OUT, name)
        os.makedirs(d, exist_ok=True)
        orig.save(os.path.join(d, "original.png"))
        res = {"title": KODAK[name], "size": orig.size, "codecs": {}}
        for cname, enc in list(CLASSIC.items()) + list(LEARNED.items()):
            best = None
            for ls in LONG_SIDES if cname in CLASSIC else [None]:
                try:
                    if cname in CLASSIC:
                        im = resize_long(orig, ls)
                        r = enc(im)
                        cands = [] if r is None else [(len(r[0]), r[1], im.size, r[2])]
                    else:
                        cands = enc(orig)
                except Exception as e:  # keep going; record the failure
                    log(f"  {cname} @{ls}: {e}")
                    continue
                for n, dec, size, setting in cands:
                    up, p, m = score(orig, dec)
                    if best is None or m > best["ms_ssim"]:
                        best = dict(bytes=n, coded_size=size, setting=setting,
                                    psnr=round(p, 2), ms_ssim=round(m, 4), img=up)
            if best is None:
                log(f"  {cname}: nothing fits")
                continue
            slug = "".join(c if c.isalnum() else "_" for c in cname).strip("_").lower()
            best["img"].save(os.path.join(d, f"{slug}.png"))
            best["file"] = f"{name}/{slug}.png"
            del best["img"]
            res["codecs"][cname] = best
            log(f"  {cname:36s} {best['bytes']:5d} B  {best['coded_size']}  "
                f"{best['setting']:6s} PSNR {best['psnr']:5.2f}  MS-SSIM {best['ms_ssim']:.4f}")
        results["images"][name] = res
        json.dump(results, open(os.path.join(OUT, "results.json"), "w"), indent=1)

    # Rough speed and size of the learned codecs on this CPU.
    info = {}
    for cname, enc in LEARNED.items():
        t = enc.timings
        if t:
            info[cname] = {
                "mean_encode_s": round(sum(x[1] for x in t) / len(t), 2),
                "mean_decode_s": round(sum(x[2] for x in t) / len(t), 2),
            }
    for kind, q in _models:
        params = sum(p.numel() for p in _models[(kind, q)].parameters())
        info[f"{kind} q{q} params"] = params
    info["compressai"] = compressai.__version__
    results["learned_info"] = info
    json.dump(results, open(os.path.join(OUT, "results.json"), "w"), indent=1)
    log(json.dumps(info, indent=1))

    # Averages.
    log("== averages")
    for cname in results["codecs"]:
        rows = [r["codecs"][cname] for r in results["images"].values() if cname in r["codecs"]]
        if rows:
            log(f"  {cname:36s} PSNR {np.mean([r['psnr'] for r in rows]):5.2f}  "
                f"MS-SSIM {np.mean([r['ms_ssim'] for r in rows]):.4f}  "
                f"bytes {np.mean([r['bytes'] for r in rows]):.0f}")


if __name__ == "__main__":
    main()
