"""Trains the small voice restorer for standalones (kit/small.py), and exports it.

It learns from the same Codec2 and VCTK pairs as the app's restorer. When that
restorer has been trained (option 2), it is the teacher: the small one learns
to sound like the big one's output, brought down to 16 kHz, which is easier to
copy than the clean recording. The discriminators still compare it with the
clean recording, so it learns to sound like real speech. With no restorer
trained yet, it learns from the clean recording alone.

Resumable like the restorer: Ctrl+C keeps the last checkpoint; run it again to
go on. Every 1000 steps it writes listening samples to
output/small-restorer-samples/. The export (vox-restorer-small.bin) goes on a
standalone's SD card (see the report it writes).
"""
import glob
import hashlib
import os
import random
import time

import numpy as np
import torch
import torch.nn.functional as F

from . import data, lavasr, small
from .train_restorer import Disc, d_loss, fm_loss, g_loss

SEG8 = 4096                 # about 0.5 s of Codec2 per example (a whole number of hops)
BATCH = int(os.environ.get("KIT_SMALL_BATCH", 16))
WARMUP = int(os.environ.get("KIT_WARMUP", 2000))
SAMPLE_EVERY = int(os.environ.get("KIT_SAMPLE_EVERY", 1000))
LR = float(os.environ.get("KIT_SMALL_LR", 3e-4))


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
        g = min(rng.uniform(0.5, 1.0) / max(np.abs(x).max(), 1e-3), 6.0)   # levelled as standalones play it
        return torch.from_numpy(x * g), torch.from_numpy(y * g)


class Down3(torch.nn.Module):
    """48 kHz -> 16 kHz: a linear-phase low-pass (7.6 kHz), every third sample."""

    def __init__(self):
        super().__init__()
        from scipy.signal import firwin
        h = firwin(97, 7600, fs=48000, window=("kaiser", 8.0)).astype(np.float32)
        self.register_buffer("h", torch.from_numpy(h).view(1, 1, -1))

    def forward(self, x):
        p = (self.h.shape[-1] - 1) // 2
        return F.conv1d(F.pad(x.unsqueeze(1), (p, p)), self.h, stride=3)[:, 0]


class MelLoss16(torch.nn.Module):
    """L1 of log-mel spectrograms at three resolutions, 0-8 kHz."""

    def __init__(self):
        super().__init__()
        self.res = (256, 512, 1024)
        for i, n in enumerate(self.res):
            fb = lavasr.mel_fb(sr=16000, n_fft=n, n_mels=(40, 64, 80)[i], fmax=8000.0)
            self.register_buffer(f"fb{i}", torch.from_numpy(fb))
            self.register_buffer(f"w{i}", torch.hann_window(n))

    def forward(self, y, t):
        loss = 0
        for i, n in enumerate(self.res):
            fb, w = getattr(self, f"fb{i}"), getattr(self, f"w{i}")
            f = lambda x: torch.log(torch.clamp(fb @ torch.stft(x, n, n // 4, window=w, return_complex=True).abs(), min=1e-5))
            loss = loss + F.l1_loss(f(y), f(t))
        return loss / len(self.res)


def run_dir(root):
    d = os.path.join(root, "small-restorer", "run")
    os.makedirs(d, exist_ok=True)
    return d


def load_teacher(root, device):
    """The app's restorer (option 2), when it has been trained; else None."""
    ckpt = os.path.join(root, "restorer", "run", "last.pt")
    if not os.path.exists(ckpt):
        return None
    gen = lavasr.Enhancer()
    gen.load_state_dict(torch.load(ckpt, map_location="cpu")["gen"])
    onnx_dir = os.path.join(root, "lavasr-onnx")
    if os.path.exists(os.path.join(onnx_dir, "enhancer_spec_head.onnx")):
        gen.mag_max = lavasr.load_from_onnx(onnx_dir).mag_max
    gen = gen.to(device).eval()
    for p in gen.parameters():
        p.requires_grad_(False)
    return lavasr.Frontend().to(device), gen


def write_samples(model, val, out, step, device):
    import soundfile as sf
    d = os.path.join(out, f"step{step:07d}")
    os.makedirs(d, exist_ok=True)
    model.eval()
    with torch.no_grad():
        for f in val:
            z = np.load(f)
            n = (min(z["c8"].size, 8000 * 6) // small.IN_HOP) * small.IN_HOP
            x = torch.from_numpy(z["c8"][:n].astype(np.float32) / 32768)[None].to(device)
            g = 0.8 / max(float(x.abs().max()), 1e-3)
            y = model(x * g)[0].float().cpu().numpy() / g
            name = os.path.basename(f)[:-4]
            if not os.path.exists(os.path.join(out, f"{name}-codec2.wav")):
                from scipy.signal import resample_poly
                sf.write(os.path.join(out, f"{name}-clean.wav"), resample_poly(z["clean"][: n * 6] / 32768, 1, 3), 16000)
                sf.write(os.path.join(out, f"{name}-codec2.wav"), z["c8"][:n] / 32768, 8000)
            sf.write(os.path.join(d, f"{name}-small.wav"), np.clip(y, -1, 1), 16000)
    model.train()


def main(root, out, workers, hours=2.0, max_steps=None):
    pairs = data.prepare_restorer(root, workers)
    files = sorted(glob.glob(os.path.join(pairs, "*.npz")))
    if len(files) < 4:
        raise SystemExit("Not enough prepared clips")
    info = data.speaker_info(root)
    spk = sorted({os.path.basename(f).split("_")[0] for f in files})
    held = [s for s in spk if info.get(s) == "F"][:1] + [s for s in spk if info.get(s) == "M"][:1] or spk[:1]
    val = [f for f in files if os.path.basename(f).split("_")[0] in held][:4]
    train = [f for f in files if os.path.basename(f).split("_")[0] not in held]
    device = "cuda" if torch.cuda.is_available() else "cpu"
    ckpt = os.path.join(run_dir(root), "last.pt")

    dim, inter, layers = small.dims()
    step = 0
    st = torch.load(ckpt, map_location=device) if os.path.exists(ckpt) else None
    if st:
        dim, inter, layers = st["dims"]     # a run keeps the size it started with
    model = small.torch_model(dim, inter, layers).to(device)
    disc = Disc().to(device)
    down = Down3().to(device)
    mel_loss = MelLoss16().to(device)
    opt_g = torch.optim.AdamW(model.parameters(), lr=LR, betas=(0.8, 0.99))
    opt_d = torch.optim.AdamW(disc.parameters(), lr=2e-4, betas=(0.8, 0.99))
    if st:
        model.load_state_dict(st["model"]); disc.load_state_dict(st["disc"])
        opt_g.load_state_dict(st["opt_g"]); opt_d.load_state_dict(st["opt_d"])
        step = st["step"]
        print(f"  resuming at step {step}")
    n_params = sum(p.numel() for p in model.parameters())
    print(f"  small restorer: dim {dim}, {layers} layers, {n_params / 1e6:.2f} M weights")
    teacher = load_teacher(root, device)
    print("  teacher: the app's restorer" if teacher else
          "  no restorer trained yet (option 2): learning from the clean recordings alone")

    total = max_steps or 10 ** 9
    loader = torch.utils.data.DataLoader(Pairs(train, total - step), batch_size=BATCH, num_workers=workers,
                                         persistent_workers=workers > 0, drop_last=True)
    samples = os.path.join(out, "small-restorer-samples")
    if step == 0:
        write_samples(model, val, samples, 0, device)
    amp = dict(device_type="cuda", dtype=torch.bfloat16) if device == "cuda" else dict(device_type="cpu", enabled=False)
    t_end = time.time() + hours * 3600
    t0, last_print = time.time(), 0

    def save():
        torch.save({"model": model.state_dict(), "disc": disc.state_dict(), "opt_g": opt_g.state_dict(),
                    "opt_d": opt_d.state_dict(), "step": step, "dims": (dim, inter, layers)}, ckpt + ".tmp")
        os.replace(ckpt + ".tmp", ckpt)

    try:
        for x8, y48 in loader:
            x8, y48 = x8.to(device), y48.to(device)
            with torch.no_grad():
                clean = down(y48)
                if teacher:
                    front, gen = teacher
                    with torch.autocast(**amp):
                        _, _, mel = front(x8)
                        t48 = front.istft(gen(mel), x8.shape[-1] * lavasr.UP)
                    target = down(t48.float())
                else:
                    target = clean
            with torch.autocast(**amp):
                y_hat = model(x8)
            y_hat = y_hat.float()
            adv = step >= WARMUP
            if adv:
                with torch.autocast(**amp):
                    ld = d_loss(disc(clean), disc(y_hat.detach()))
                opt_d.zero_grad(set_to_none=True)
                ld.float().backward()
                opt_d.step()
            lm = mel_loss(y_hat, target)
            lg = lm * 45
            if adv:
                with torch.autocast(**amp):
                    real, fake = disc(clean), disc(y_hat)
                    lg = lg + g_loss(fake) + 2 * fm_loss(real, fake)
            opt_g.zero_grad(set_to_none=True)
            lg.float().backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), 1000)
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
                write_samples(model, val, samples, step, device)
            if time.time() > t_end or step >= total:
                break
    except KeyboardInterrupt:
        print("\n  stopped; saving")
    save()
    print(f"\n  checkpoint at step {step}: {ckpt}")
    return ckpt


def export(root, out):
    """The latest checkpoint as vox-restorer-small.bin, checked against the
    numpy reference the firmware follows."""
    ckpt = os.path.join(run_dir(root), "last.pt")
    if not os.path.exists(ckpt):
        raise SystemExit("No small restorer checkpoint yet: train it first")
    st = torch.load(ckpt, map_location="cpu")
    dim, inter, layers = st["dims"]
    model = small.torch_model(dim, inter, layers)
    model.load_state_dict(st["model"])
    os.makedirs(out, exist_ok=True)
    dst = os.path.join(out, "vox-restorer-small.bin")
    export_model(model, dst)
    ref = small.Reference(dst)
    sha = hashlib.sha256(open(dst, "rb").read()).hexdigest()
    mmacs = ref.macs_per_second() / 1e6
    open(os.path.join(out, "small-restorer-report.txt"), "w").write(
        f"vox-restorer-small.bin\nsteps: {st['step']}\ndim: {dim}\nlayers: {layers}\n"
        f"weights: {ref.params()}\nbytes: {os.path.getsize(dst)}\nsha256: {sha}\n"
        f"compute: {mmacs:.0f} million multiply-adds per second of voice\n"
        "Copy it to the standalone's SD card as /models/vox-restorer-small.bin, then turn on\n"
        "Settings > Sound > AI voice restorer.\n")
    print(f"  wrote {dst} ({os.path.getsize(dst) // 1024} KB)\n  sha256 {sha}")


def export_model(model, dst):
    """Writes `model` to `dst` and checks the file, run by the numpy
    reference, against PyTorch with the same (float16-rounded) weights."""
    model = model.float().eval().cpu()
    small.write_file(dst, small.weights_in_order(model), model.dim, model.inter, model.layers)
    check = small.load_into_torch(small.torch_model(model.dim, model.inter, model.layers), dst).eval()
    ref = small.Reference(dst)
    rng = np.random.default_rng(7)
    t = np.arange(4000) / 8000
    x = (0.3 * np.sin(2 * np.pi * 220 * t) * (1 + np.sin(2 * np.pi * 3 * t)) + 0.02 * rng.normal(size=t.size))
    with torch.no_grad():
        y_t = check(torch.from_numpy(x.astype(np.float32))[None])[0].double().numpy()
    y_r = ref.run(x)
    err = np.abs(y_t - y_r).max() / max(np.abs(y_r).max(), 1e-6)
    if err > 1e-3:
        raise SystemExit(f"export check failed: PyTorch and the reference differ by {err:.2e}")
    print(f"  export check: PyTorch and the reference agree ({err:.1e})")
