"""Entry point: python -m kit.run {check|bright|restorer|export|small|small-export} [options].
START.bat runs this through the menu; the options are for running it by hand."""
import argparse
import os
import sys
import time

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def check():
    import torch
    print(f"  Python {sys.version.split()[0]}, PyTorch {torch.__version__}")
    if torch.cuda.is_available():
        p = torch.cuda.get_device_properties(0)
        print(f"  GPU: {p.name}, {p.total_memory / 2**30:.0f} GB, compute {p.major}.{p.minor}")
        x = torch.randn(1024, 1024, device="cuda")
        torch.cuda.synchronize()
        print(f"  GPU test: ok ({float((x @ x).sum()):.1f})")
    else:
        print("  No CUDA GPU found: training would run on the CPU (very slow for the restorer).")
    from . import dsp
    import numpy as np
    t = np.arange(8000) / 8000
    y = dsp.codec2(0.3 * np.sin(2 * np.pi * 300 * t), "1200")
    print(f"  Codec2: ok ({y.size} samples back)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("what", choices=["check", "bright", "restorer", "export", "small", "small-export"])
    ap.add_argument("--data", default=os.path.join(HERE, "data"), help="downloads and prepared data (needs ~40 GB for the restorer)")
    ap.add_argument("--out", default=os.path.join(HERE, "output"))
    ap.add_argument("--workers", type=int, default=max(1, min(8, (os.cpu_count() or 2) - 1)))
    ap.add_argument("--hours", type=float, default=None,
                    help="restorer / small: how long to train this run (8 h / 2 h)")
    ap.add_argument("--steps", type=int, default=None, help="restorer: stop at this many steps in all")
    ap.add_argument("--epochs", type=int, default=40, help="Brighter voice net: passes over the data")
    a = ap.parse_args()
    t = time.time()
    if a.what == "check":
        check()
    elif a.what == "bright":
        from . import train_bright
        train_bright.main(a.data, a.out, a.workers, epochs=a.epochs)
    elif a.what == "restorer":
        from . import train_restorer
        train_restorer.main(a.data, a.out, a.workers, hours=a.hours or 8.0, max_steps=a.steps)
        train_restorer.export(a.data, a.out, graph_dir())
    elif a.what == "small":
        from . import train_small
        train_small.main(a.data, a.out, a.workers, hours=a.hours or 2.0, max_steps=a.steps)
        train_small.export(a.data, a.out)
    elif a.what == "small-export":
        from . import train_small
        train_small.export(a.data, a.out)
    else:
        from . import train_restorer
        train_restorer.export(a.data, a.out, graph_dir())
    print(f"  done in {(time.time() - t) / 60:.1f} min")


def graph_dir():
    """voice_bwe_to_onnx.py: next to the kit in the zip, or in the app repo."""
    for d in (os.path.join(HERE, "kit"), os.path.join(HERE, "..", "..", "scripts", "models")):
        if os.path.exists(os.path.join(d, "voice_bwe_to_onnx.py")):
            return d
    sys.exit("voice_bwe_to_onnx.py is missing from the kit")


if __name__ == "__main__":
    main()
