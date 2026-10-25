"""Fine-tunes LavaSR's enhancer into a Codec2 restorer for the app.

The app's voice enhancer (lib/vox/vox_voice_enhance.dart) keeps what was
received below 4 kHz and only adds the band above it. Codec2's own artefacts
(the buzzy, robotic sound) are below 4 kHz, so this trains the same network
to rebuild the whole spectrum: in, Codec2 at 8 kHz as the app decodes it;
out, the clean 48 kHz recording.

Losses as Vocos was trained: multi-resolution mel L1, plus multi-period and
multi-resolution discriminators (hinge) with feature matching, after a
reconstruction-only warm-up.

Resumable: Ctrl+C or a crash keeps the last checkpoint; run it again to go on.
Every 1000 steps it writes listening samples to output/restorer-samples/.
"""
import glob
import os
import random
import time

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

from . import data, lavasr

SEG8 = 4000                 # 0.5 s of Codec2 per example (24,000 samples out)
BATCH = int(os.environ.get("KIT_BATCH", 8))   # as Vocos: ~200k output samples a step
WARMUP = int(os.environ.get("KIT_WARMUP", 2000))          # steps of reconstruction loss only
SAMPLE_EVERY = int(os.environ.get("KIT_SAMPLE_EVERY", 1000))


# ------------------------------------------------------------------ dataset

class Pairs(torch.utils.data.Dataset):
    def __init__(self, files, steps):
        self.files, self.steps = files, steps

    def __len__(self):
        return self.steps * BATCH

    def __getitem__(self, i):
        rng = random.Random(i * 7919 + int(time.time() * 1000) % 100000)
        while True:
            z = np.load(self.files[rng.randrange(len(self.files))])
            c8, clean = z["c8"], z["clean"]
            if c8.size > SEG8 + 1:
                break
        s = rng.randrange(0, c8.size - SEG8)
        x = c8[s: s + SEG8].astype(np.float32) / 32768
        y = clean[s * 6: (s + SEG8) * 6].astype(np.float32) / 32768
        g = rng.uniform(0.5, 1.0) / max(np.abs(x).max(), 1e-3)   # level as the app plays it, roughly
        g = min(g, 6.0)
        return torch.from_numpy(x * g), torch.from_numpy(y * g)


# ------------------------------------------------------------ discriminators

class PeriodD(nn.Module):
    def __init__(self, p):
        super().__init__()
        self.p = p
        ch = [1, 32, 128, 512, 1024, 1024]
        self.convs = nn.ModuleList([
            nn.utils.parametrizations.weight_norm(nn.Conv2d(ch[i], ch[i + 1], (5, 1), (3 if i < 4 else 1, 1), (2, 0)))
            for i in range(5)])
        self.post = nn.utils.parametrizations.weight_norm(nn.Conv2d(1024, 1, (3, 1), 1, (1, 0)))

    def forward(self, x):
        b, t = x.shape
        if t % self.p:
            x = F.pad(x, (0, self.p - t % self.p), mode="reflect")
        x = x.view(b, 1, -1, self.p)
        feats = []
        for c in self.convs:
            x = F.leaky_relu(c(x), 0.1)
            feats.append(x)
        x = self.post(x)
        feats.append(x)
        return x.flatten(1), feats


class ResD(nn.Module):
    def __init__(self, n_fft):
        super().__init__()
        self.n_fft = n_fft
        self.register_buffer("win", torch.hann_window(n_fft))
        wn = nn.utils.parametrizations.weight_norm
        self.convs = nn.ModuleList([
            wn(nn.Conv2d(1, 32, (3, 9), padding=(1, 4))),
            wn(nn.Conv2d(32, 32, (3, 9), (1, 2), (1, 4))),
            wn(nn.Conv2d(32, 32, (3, 9), (1, 2), (1, 4))),
            wn(nn.Conv2d(32, 32, (3, 9), (1, 2), (1, 4))),
            wn(nn.Conv2d(32, 32, (3, 3), padding=(1, 1))),
        ])
        self.post = wn(nn.Conv2d(32, 1, (3, 3), padding=(1, 1)))

    def forward(self, x):
        s = torch.stft(x, self.n_fft, self.n_fft // 4, window=self.win, return_complex=True).abs()
        x = s.transpose(1, 2).unsqueeze(1)      # [B, 1, T, F]
        feats = []
        for c in self.convs:
            x = F.leaky_relu(c(x), 0.1)
            feats.append(x)
        x = self.post(x)
        feats.append(x)
        return x.flatten(1), feats


class Disc(nn.Module):
    def __init__(self):
        super().__init__()
        self.ds = nn.ModuleList([PeriodD(p) for p in (2, 3, 5, 7, 11)] + [ResD(n) for n in (512, 1024, 2048)])

    def forward(self, x):
        return [d(x) for d in self.ds]


# ------------------------------------------------------------------- losses

class MelLoss(nn.Module):
    """L1 of log-mel spectrograms at three resolutions, 0-24 kHz."""

    def __init__(self):
        super().__init__()
        self.res = []
        for i, n in enumerate((512, 1024, 2048)):
            fb = lavasr.mel_fb(sr=48000, n_fft=n, n_mels=64 if n == 512 else 128, fmax=24000.0)
            self.register_buffer(f"fb{i}", torch.from_numpy(fb))
            self.register_buffer(f"w{i}", torch.hann_window(n))
            self.res.append(n)

    def forward(self, y, t):
        loss = 0
        for i, n in enumerate(self.res):
            fb, w = getattr(self, f"fb{i}"), getattr(self, f"w{i}")
            f = lambda x: torch.log(torch.clamp(fb @ torch.stft(x, n, n // 4, window=w, return_complex=True).abs(), min=1e-5))
            loss = loss + F.l1_loss(f(y), f(t))
        return loss / len(self.res)


def d_loss(real, fake):
    return sum(torch.mean(F.relu(1 - r[0])) + torch.mean(F.relu(1 + f[0])) for r, f in zip(real, fake))


def g_loss(fake):
    return sum(torch.mean(F.relu(1 - f[0])) for f in fake)


def fm_loss(real, fake):
    return sum(F.l1_loss(ff, rf.detach()) for r, f in zip(real, fake) for rf, ff in zip(r[1], f[1]))


# -------------------------------------------------------------------- train

def restore(front, gen, x8):
    _, _, mel = front(x8)
    return front.istft(gen(mel), x8.shape[-1] * lavasr.UP)


def write_samples(front, gen, val, out, step, device):
    import soundfile as sf
    d = os.path.join(out, f"step{step:07d}")
    os.makedirs(d, exist_ok=True)
    gen.eval()
    with torch.no_grad():
        for i, f in enumerate(val):
            z = np.load(f)
            x = torch.from_numpy(z["c8"][: 8000 * 6].astype(np.float32) / 32768)[None].to(device)
            g = 0.8 / max(float(x.abs().max()), 1e-3)
            y = restore(front, gen, x * g)[0].float().cpu().numpy() / g
            name = os.path.basename(f)[:-4]
            if step == 0 or not os.path.exists(os.path.join(out, f"{name}-clean.wav")):
                sf.write(os.path.join(out, f"{name}-clean.wav"), z["clean"][: 48000 * 6] / 32768, 48000)
                sf.write(os.path.join(out, f"{name}-codec2.wav"), z["c8"][: 8000 * 6] / 32768, 8000)
            sf.write(os.path.join(d, f"{name}-restored.wav"), np.clip(y, -1, 1), 48000)
    gen.train()


def main(root, out, workers, hours=8.0, max_steps=None, quick=False):
    pairs = data.prepare_restorer(root, workers) if not quick else os.path.join(root, "restorer", "pairs")
    files = sorted(glob.glob(os.path.join(pairs, "*.npz")))
    if len(files) < 4:
        raise SystemExit("Not enough prepared clips")
    # Hold out two speakers, one woman and one man when VCTK says who is who.
    info = data.speaker_info(root)
    spk = sorted({os.path.basename(f).split("_")[0] for f in files})
    held = [s for s in spk if info.get(s) == "F"][:1] + [s for s in spk if info.get(s) == "M"][:1] or spk[:1]
    val = [f for f in files if os.path.basename(f).split("_")[0] in held][:4]
    train = [f for f in files if os.path.basename(f).split("_")[0] not in held]
    device = "cuda" if torch.cuda.is_available() else "cpu"
    run_dir = os.path.join(root, "restorer", "run")
    os.makedirs(run_dir, exist_ok=True)
    ckpt = os.path.join(run_dir, "last.pt")

    front = lavasr.Frontend().to(device)
    gen = lavasr.load_from_onnx(lavasr.fetch_onnx(os.path.join(root, "lavasr-onnx"))).to(device)
    disc = Disc().to(device)
    mel_loss = MelLoss().to(device)
    opt_g = torch.optim.AdamW(gen.parameters(), lr=5e-5, betas=(0.8, 0.9))
    opt_d = torch.optim.AdamW(disc.parameters(), lr=2e-4, betas=(0.8, 0.9))
    step = 0
    if os.path.exists(ckpt):
        st = torch.load(ckpt, map_location=device)
        gen.load_state_dict(st["gen"]); disc.load_state_dict(st["disc"])
        opt_g.load_state_dict(st["opt_g"]); opt_d.load_state_dict(st["opt_d"])
        step = st["step"]
        print(f"  resuming at step {step}")
    total = max_steps or 10 ** 9
    loader = torch.utils.data.DataLoader(Pairs(train, total - step), batch_size=BATCH, num_workers=workers,
                                         persistent_workers=workers > 0, drop_last=True)
    samples = os.path.join(out, "restorer-samples")
    if step == 0:
        write_samples(front, gen, val, samples, 0, device)
    amp = dict(device_type="cuda", dtype=torch.bfloat16) if device == "cuda" else dict(device_type="cpu", enabled=False)
    t_end = time.time() + hours * 3600
    t0, last_print = time.time(), 0

    def save():
        torch.save({"gen": gen.state_dict(), "disc": disc.state_dict(), "opt_g": opt_g.state_dict(),
                    "opt_d": opt_d.state_dict(), "step": step}, ckpt + ".tmp")
        os.replace(ckpt + ".tmp", ckpt)

    try:
        for x8, y in loader:
            x8, y = x8.to(device), y.to(device)
            with torch.autocast(**amp):
                y_hat = restore(front, gen, x8)
            y_hat = y_hat.float()
            adv = step >= WARMUP
            if adv:
                with torch.autocast(**amp):
                    ld = d_loss(disc(y), disc(y_hat.detach()))
                opt_d.zero_grad(set_to_none=True)
                ld.float().backward()
                opt_d.step()
            lm = mel_loss(y_hat, y)
            lg = lm * 45
            if adv:
                with torch.autocast(**amp):
                    real, fake = disc(y), disc(y_hat)
                    lg = lg + g_loss(fake) + 2 * fm_loss(real, fake)
            opt_g.zero_grad(set_to_none=True)
            lg.float().backward()
            torch.nn.utils.clip_grad_norm_(gen.parameters(), 1000)
            opt_g.step()
            step += 1
            if time.time() - last_print > 10:
                last_print = time.time()
                rate = step / max(time.time() - t0, 1)
                left = (t_end - time.time()) / 3600
                print(f"\r  step {step}  mel {float(lm):.3f}  {'GAN on' if adv else 'warm-up'}  "
                      f"{rate:.1f} steps/s  {left:4.1f} h left", end="", flush=True)
            if step % SAMPLE_EVERY == 0:
                save()
                write_samples(front, gen, val, samples, step, device)
            if time.time() > t_end or step >= total:
                break
    except KeyboardInterrupt:
        print("\n  stopped; saving")
    save()
    print(f"\n  checkpoint at step {step}: {ckpt}")
    return ckpt


def export(root, out, graph_dir):
    """The latest checkpoint as the app's model file (one graph, 8 kHz in, 48 kHz out)."""
    import hashlib
    import sys
    ckpt = os.path.join(root, "restorer", "run", "last.pt")
    if not os.path.exists(ckpt):
        raise SystemExit("No restorer checkpoint yet: train it first")
    gen = lavasr.Enhancer()
    st = torch.load(ckpt, map_location="cpu")
    gen.load_state_dict(st["gen"])
    gen.mag_max = lavasr.load_from_onnx(os.path.join(root, "lavasr-onnx")).mag_max
    tmp = os.path.join(root, "restorer", "onnx")
    lavasr.export_onnx(gen, tmp)
    sys.path.insert(0, graph_dir)
    import voice_bwe_to_onnx as V   # the app's graph builder (scripts/models/)
    model = V.build(tmp, merge=False)
    os.makedirs(out, exist_ok=True)
    dst = os.path.join(out, "codec2-restorer-8k-48k.onnx")
    import onnx
    onnx.save(V.half_weights(model), dst)
    sha = hashlib.sha256(open(dst, "rb").read()).hexdigest()
    open(os.path.join(out, "restorer-report.txt"), "w").write(
        f"codec2-restorer-8k-48k.onnx\nsteps: {st['step']}\nbytes: {os.path.getsize(dst)}\nsha256: {sha}\n")
    print(f"  wrote {dst}\n  sha256 {sha}")
