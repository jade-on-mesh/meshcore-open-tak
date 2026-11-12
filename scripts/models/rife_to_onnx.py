"""RIFE 4.9 (IFNet, arch 4.7) to ONNX for video messages' Smooth motion
(lib/vox/vox_interp.dart).

RIFE: Practical-RIFE, MIT, Copyright (c) 2021 hzwer,
https://github.com/hzwer/Practical-RIFE. The IFNet below follows its arch 4.7
(used by 4.7 to 4.9) as written in ComfyUI-Frame-Interpolation's rife_arch.py
(MIT, Fannovel16), without the training and ensemble paths.

    python3 rife_to_onnx.py rife49.pth out.onnx

The weights load with torch.load(weights_only=True): tensors only, no pickled
code. The graph: inputs "img0", "img1" float32 [1,3,H,W] RGB 0..1 (H and W
multiples of 64, padded by the caller) and "timestep" [1,1,1,1]; output
"frame" [1,3,H,W], the frame at that time between them. Fixed scales
[8,4,2,1] (the small frames video messages carry). Needs PyTorch, onnx and
onnxruntime; checks the ONNX output against PyTorch's.
"""

import sys

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F


def conv(cin, cout, k=3, s=1, p=1):
    return nn.Sequential(nn.Conv2d(cin, cout, k, s, p, bias=True), nn.LeakyReLU(0.2, True))


class ResConv(nn.Module):
    def __init__(self, c):
        super().__init__()
        self.conv = nn.Conv2d(c, c, 3, 1, 1)
        self.beta = nn.Parameter(torch.ones((1, c, 1, 1)))
        self.relu = nn.LeakyReLU(0.2, True)

    def forward(self, x):
        return self.relu(self.conv(x) * self.beta + x)


def warp(x, flow):
    n, _, h, w = flow.shape
    gx = torch.linspace(-1.0, 1.0, w).view(1, 1, 1, w).expand(n, 1, h, w)
    gy = torch.linspace(-1.0, 1.0, h).view(1, 1, h, 1).expand(n, 1, h, w)
    grid = torch.cat([gx, gy], 1)
    f = torch.cat(
        [
            flow[:, 0:1] / ((x.shape[3] - 1.0) / 2.0),
            flow[:, 1:2] / ((x.shape[2] - 1.0) / 2.0),
        ],
        1,
    )
    g = (grid + f).permute(0, 2, 3, 1)
    return F.grid_sample(x, g, mode="bilinear", padding_mode="border", align_corners=True)


class IFBlock(nn.Module):
    def __init__(self, cin, c):
        super().__init__()
        self.conv0 = nn.Sequential(conv(cin, c // 2, 3, 2, 1), conv(c // 2, c, 3, 2, 1))
        self.convblock = nn.Sequential(*[ResConv(c) for _ in range(8)])
        self.lastconv = nn.Sequential(nn.ConvTranspose2d(c, 4 * 6, 4, 2, 1), nn.PixelShuffle(2))

    def forward(self, x, flow, scale):
        x = F.interpolate(x, scale_factor=1.0 / scale, mode="bilinear", align_corners=False)
        if flow is not None:
            flow = (
                F.interpolate(flow, scale_factor=1.0 / scale, mode="bilinear", align_corners=False)
                / scale
            )
            x = torch.cat((x, flow), 1)
        tmp = self.lastconv(self.convblock(self.conv0(x)))
        tmp = F.interpolate(tmp, scale_factor=scale, mode="bilinear", align_corners=False)
        return tmp[:, :4] * scale, tmp[:, 4:5]


class IFNet(nn.Module):
    scales = (8, 4, 2, 1)

    def __init__(self):
        super().__init__()
        self.block0 = IFBlock(7 + 8, c=192)
        self.block1 = IFBlock(8 + 4 + 8, c=128)
        self.block2 = IFBlock(8 + 4 + 8, c=96)
        self.block3 = IFBlock(8 + 4 + 8, c=64)
        self.encode = nn.Sequential(nn.Conv2d(3, 16, 3, 2, 1), nn.ConvTranspose2d(16, 4, 4, 2, 1))

    def forward(self, img0, img1, timestep):
        t = timestep.expand(-1, 1, img0.shape[2], img0.shape[3])
        f0 = self.encode(img0)
        f1 = self.encode(img1)
        blocks = [self.block0, self.block1, self.block2, self.block3]
        flow, mask = blocks[0](torch.cat((img0, img1, f0, f1, t), 1), None, self.scales[0])
        w0 = warp(img0, flow[:, :2])
        w1 = warp(img1, flow[:, 2:4])
        for i in range(1, 4):
            fd, m0 = blocks[i](
                torch.cat((w0, w1, warp(f0, flow[:, :2]), warp(f1, flow[:, 2:4]), t, mask), 1),
                flow,
                self.scales[i],
            )
            flow = flow + fd
            mask = m0
            w0 = warp(img0, flow[:, :2])
            w1 = warp(img1, flow[:, 2:4])
        m = torch.sigmoid(mask)
        return (w0 * m + w1 * (1 - m)).clamp(0, 1)


def main(src, dst):
    net = IFNet().eval()
    sd = torch.load(src, map_location="cpu", weights_only=True)
    sd = {
        k.replace("module.", ""): v
        for k, v in sd.items()
        if "teacher" not in k and "caltime" not in k
    }
    net.load_state_dict(sd, strict=True)
    a = torch.rand(1, 3, 128, 192)
    b = torch.rand(1, 3, 128, 192)
    t = torch.full((1, 1, 1, 1), 0.5)
    with torch.no_grad():
        torch.onnx.export(
            net,
            (a, b, t),
            dst,
            input_names=["img0", "img1", "timestep"],
            output_names=["frame"],
            dynamic_axes={
                "img0": {2: "h", 3: "w"},
                "img1": {2: "h", 3: "w"},
                "frame": {2: "h", 3: "w"},
            },
            opset_version=17,
            dynamo=False,
        )
    import onnxruntime as ort

    s = ort.InferenceSession(dst, providers=["CPUExecutionProvider"])
    a = torch.rand(1, 3, 192, 256)
    b = torch.roll(a, 3, dims=3)
    with torch.no_grad():
        want = net(a, b, t).numpy()
    got = s.run(None, {"img0": a.numpy(), "img1": b.numpy(), "timestep": t.numpy()})[0]
    err = float(np.abs(want - got).max())
    print(f"max |onnx - torch| = {err:.2e}")
    if err > 1e-3:
        sys.exit("ONNX output differs from PyTorch")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
