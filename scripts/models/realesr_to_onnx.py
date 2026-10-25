#!/usr/bin/env python3
"""Builds the photo enhancer model (lib/vox/vox_upscale.dart).

Real-ESRGAN realesr-general-x4v3 (SRVGGNetCompact, BSD-3-Clause, Xintao Wang)
.pth -> ONNX, without PyTorch: the checkpoint's pickle is read with numpy, the
graph is written with onnx.helper, and the result is checked against a numpy
reference forward pass.

Usage: python3 realesr_to_onnx.py realesr-general-x4v3.pth realesr-general-x4v3.onnx
(the .pth from https://github.com/xinntao/Real-ESRGAN/releases/tag/v0.2.5.0;
needs numpy, onnx and onnxruntime). The output's SHA-256 must match
VoxUpscaleModel.sha256Hex.

Graph: input "input" float32 [1,3,H,W] in 0..1 RGB, output "output" [1,3,4H,4W].
"""
import pickle
import sys
import zipfile

import numpy as np
import onnx
from onnx import TensorProto, helper, numpy_helper


def load_pth(path):
    z = zipfile.ZipFile(path)
    prefix = z.namelist()[0].split("/")[0]

    class Storage:
        def __init__(self, key, dtype):
            self.key, self.dtype = key, dtype

    def rebuild(storage, offset, size, stride, *_):
        raw = z.read(f"{prefix}/data/{storage.key}")
        arr = np.frombuffer(raw, dtype=storage.dtype)
        if not size:
            return arr[offset:offset + 1].reshape(())
        return np.lib.stride_tricks.as_strided(
            arr[offset:], shape=tuple(size), strides=tuple(s * arr.itemsize for s in stride)).copy()

    dtypes = {"FloatStorage": np.float32, "HalfStorage": np.float16, "LongStorage": np.int64}

    class U(pickle.Unpickler):
        def find_class(self, mod, name):
            if name == "_rebuild_tensor_v2":
                return rebuild
            if name in dtypes:
                return dtypes[name]
            if mod == "collections" and name == "OrderedDict":
                import collections
                return collections.OrderedDict
            raise pickle.UnpicklingError(f"{mod}.{name}")

        def persistent_load(self, pid):
            _, dtype, key, *_ = pid
            return Storage(key, dtype)

    sd = U(z.open(f"{prefix}/data.pkl")).load()
    for k in ("params_ema", "params"):
        if isinstance(sd, dict) and k in sd:
            sd = sd[k]
    return {k: v.astype(np.float32) for k, v in sd.items()}


def build(sd, opset=13):
    nodes, inits = [], []
    idx = sorted({int(k.split(".")[1]) for k in sd if k.startswith("body.")})
    cur = "input"
    convs = 0
    for i in idx:
        w = sd[f"body.{i}.weight"]
        name = f"body_{i}"
        if w.ndim == 4:   # conv
            b = sd[f"body.{i}.bias"]
            inits += [numpy_helper.from_array(w, name + "_w"), numpy_helper.from_array(b, name + "_b")]
            nodes.append(helper.make_node("Conv", [cur, name + "_w", name + "_b"], [name], pads=[1, 1, 1, 1],
                                          kernel_shape=[3, 3]))
            convs += 1
        else:             # PReLU, one slope per channel
            inits.append(numpy_helper.from_array(w.reshape(-1, 1, 1), name + "_s"))
            nodes.append(helper.make_node("PRelu", [cur, name + "_s"], [name]))
        cur = name
    nodes.append(helper.make_node("DepthToSpace", [cur], ["up"], blocksize=4, mode="CRD"))
    inits.append(numpy_helper.from_array(np.array([1, 1, 4, 4], np.float32), "scales"))
    nodes.append(helper.make_node("Resize", ["input", "", "scales"], ["base"], mode="nearest",
                                  coordinate_transformation_mode="asymmetric", nearest_mode="floor"))
    nodes.append(helper.make_node("Add", ["up", "base"], ["output"]))
    g = helper.make_graph(nodes, "realesr_general_x4v3", [
        helper.make_tensor_value_info("input", TensorProto.FLOAT, [1, 3, "h", "w"])], [
        helper.make_tensor_value_info("output", TensorProto.FLOAT, [1, 3, "h4", "w4"])], inits)
    m = helper.make_model(g, opset_imports=[helper.make_opsetid("", opset)], producer_name="meshcore-open-tak")
    m.ir_version = 8
    m.doc_string = ("Real-ESRGAN realesr-general-x4v3 (SRVGGNetCompact), BSD-3-Clause, "
                    "Copyright (c) 2021 Xintao Wang. https://github.com/xinntao/Real-ESRGAN")
    onnx.checker.check_model(m)
    return m, convs


def reference(sd, x):
    """numpy forward pass of SRVGGNetCompact, for checking the graph."""
    idx = sorted({int(k.split(".")[1]) for k in sd if k.startswith("body.")})
    h = x
    for i in idx:
        w = sd[f"body.{i}.weight"]
        if w.ndim == 4:
            b = sd[f"body.{i}.bias"]
            p = np.pad(h, ((0, 0), (0, 0), (1, 1), (1, 1)))
            n, c, H, W = h.shape
            cols = np.stack([p[:, :, dy:dy + H, dx:dx + W] for dy in range(3) for dx in range(3)], axis=2)
            h = np.einsum("nckhw,ock->nohw", cols, w.reshape(w.shape[0], w.shape[1], 9)) + b[None, :, None, None]
        else:
            s = w.reshape(1, -1, 1, 1)
            h = np.where(h >= 0, h, h * s)
    n, c, H, W = h.shape
    r = 4
    up = h.reshape(n, c // (r * r), r, r, H, W).transpose(0, 1, 4, 2, 5, 3).reshape(n, c // (r * r), H * r, W * r)
    base = x.repeat(4, axis=2).repeat(4, axis=3)
    return up + base


def main():
    src, dst = sys.argv[1], sys.argv[2]
    sd = load_pth(src)
    m, convs = build(sd)
    onnx.save(m, dst)
    import onnxruntime as ort
    rng = np.random.default_rng(1)
    x = rng.random((1, 3, 12, 17), dtype=np.float32)
    got = ort.InferenceSession(dst, providers=["CPUExecutionProvider"]).run(None, {"input": x})[0]
    want = reference(sd, x)
    err = float(np.abs(got - want).max())
    print(f"{convs} convs, output {got.shape}, max |onnx - numpy| = {err:.2e}")
    assert got.shape == (1, 3, 48, 68) and err < 1e-3


if __name__ == "__main__":
    main()
