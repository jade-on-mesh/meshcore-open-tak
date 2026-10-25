"""Reference output of Brighter voice with a trained net, for Wadamesh TAK's
host test (test/test_vox_brighten.cpp, built with the net):

  python -m kit.golden VoxBrightNet.h brighten_in.raw brighten_net_out.raw

Reads the net from the header as the firmware compiles it, runs the kit's
signal path (kit/dsp.py) on the 16 kHz input and writes the output, PCM16.
"""
import re
import sys

import numpy as np

from . import dsp


def read_header(path):
    src = open(path).read()
    arrays = {}
    for m in re.finditer(r"static const float (\w+)((?:\[\d+\])+) = \{(.*?)\};", src, re.S):
        dims = [int(d) for d in re.findall(r"\[(\d+)\]", m.group(2))]
        vals = [float(v) for v in re.findall(r"[-+0-9.eE]+(?=f)", m.group(3))]
        arrays[m.group(1)] = np.array(vals, np.float32).reshape(dims)
    return arrays


def net_targets(a, w):
    x = dsp.net_inputs(a)
    h1 = np.tanh(x @ w["kVoxBrightNetW1"].T + w["kVoxBrightNetB1"])
    h2 = np.tanh(h1 @ w["kVoxBrightNetW2"].T + w["kVoxBrightNetB2"])
    o = h2 @ w["kVoxBrightNetW3"].T + w["kVoxBrightNetB3"]
    return a["m"][:, None] + 10 * o + w["kVoxBrightNetBias"]


def main(header, src, dst):
    w = read_header(header)
    x = np.fromfile(src, "<i2").astype(np.float64)
    a = dsp.analyse(x)
    y = dsp.apply_targets(x, a, net_targets(a, w))
    np.round(y).astype("<i2").tofile(dst)
    print(f"{dst}: {y.size} samples")


if __name__ == "__main__":
    main(*sys.argv[1:4])
