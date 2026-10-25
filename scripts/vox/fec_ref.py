#!/usr/bin/env python3
"""Reference for VOX forward error correction (lib/vox/vox_fec.dart, and
Wadamesh TAK's src/ui-touch/VoxFec.h): parity packets sent with a clip so a
listener rebuilds a few lost packets itself, with no request.

Wire: a parity packet is an ordinary VE3 voice packet
    [0x56][psid:4][info][lastLen][parity: P bytes]
- psid = the clip's session id XOR 0xFEC0FEC0. Apps and standalones without
  FEC see an unknown clip and drop it; radios route it as voice (radio2).
- info = block * 8 + j: parity j (0..7) of block `block`. Block b covers
  packets [20b, 20b + 20) of the clip, the last one shorter.
- lastLen = the length of the clip's last packet (the only short one).
- P = the clip's full packet length; every data packet is zero-padded to P.
Parity j of a block with data d_0..d_k-1 is sum_i c(j, i) * d_i over
GF(256) (polynomial 0x11d), c(j, i) = 1 / ((0x80 | j) ^ i): a Cauchy
matrix, so any e lost packets of a block come back from any e of its parity.

Usage: fec_ref.py vectors OUT.txt   (the shared test vectors)
"""
import sys

BLOCK = 20
SID_XOR = 0xFEC0FEC0
EXP = [0] * 512
LOG = [0] * 256
x = 1
for i in range(255):
    EXP[i] = x
    LOG[x] = i
    x <<= 1
    if x & 0x100:
        x ^= 0x11D
for i in range(255, 512):
    EXP[i] = EXP[i - 255]


def mul(a, b):
    return 0 if a == 0 or b == 0 else EXP[LOG[a] + LOG[b]]


def inv(a):
    return EXP[255 - LOG[a]]


def coef(j, i):
    return inv((0x80 | j) ^ i)


def parity_count(k, image):
    """Parity packets for a block of k data packets."""
    if k <= 1:
        return 0
    if image:
        return 2 if k >= 6 else 1
    return 3 if k >= 8 else 2 if k >= 4 else 1


def encode(sid, packets, image):
    """Parity packet payloads for a clip, block by block."""
    n = len(packets)
    if n < 2:
        return []
    P = max(len(p) for p in packets)
    last_len = len(packets[-1])
    psid = (sid ^ SID_XOR).to_bytes(4, "big")
    out = []
    for b in range((n + BLOCK - 1) // BLOCK):
        data = [p + bytes(P - len(p)) for p in packets[b * BLOCK:(b + 1) * BLOCK]]
        for j in range(parity_count(len(data), image)):
            par = bytearray(P)
            for i, d in enumerate(data):
                c = coef(j, i)
                for t in range(P):
                    par[t] ^= mul(c, d[t])
            out.append(bytes([0x56]) + psid + bytes([b * 8 + j, last_len]) + bytes(par))
    return out


def solve(A, rhs):
    """Gauss-Jordan over GF(256): A x = rhs, rhs rows are byte vectors."""
    e = len(A)
    A = [row[:] for row in A]
    R = [bytearray(r) for r in rhs]
    for c in range(e):
        p = next(r for r in range(c, e) if A[r][c])
        A[c], A[p] = A[p], A[c]
        R[c], R[p] = R[p], R[c]
        iv = inv(A[c][c])
        A[c] = [mul(v, iv) for v in A[c]]
        R[c] = bytearray(mul(v, iv) for v in R[c])
        for r in range(e):
            if r != c and A[r][c]:
                f = A[r][c]
                A[r] = [a ^ mul(f, v) for a, v in zip(A[r], A[c])]
                R[r] = bytearray(a ^ mul(f, v) for a, v in zip(R[r], R[c]))
    return [bytes(r) for r in R]


def rebuild(total, present, parity):
    """present: {index: bytes}; parity: {info: payload after the info byte,
    i.e. [lastLen][P bytes]}. Returns {index: bytes} rebuilt."""
    out = {}
    for b in range((total + BLOCK - 1) // BLOCK):
        lo, hi = b * BLOCK, min(total, (b + 1) * BLOCK)
        miss = [i for i in range(lo, hi) if i not in present]
        pars = sorted((info & 7, v) for info, v in parity.items() if info >> 3 == b)
        if not miss or len(pars) < len(miss):
            continue
        P = len(pars[0][1]) - 1
        last_len = pars[0][1][0]
        use = pars[:len(miss)]
        rhs = []
        for j, v in use:
            r = bytearray(v[1:])
            for i in range(lo, hi):
                if i in present:
                    d = present[i] + bytes(P - len(present[i]))
                    c = coef(j, i - lo)
                    for t in range(P):
                        r[t] ^= mul(c, d[t])
            rhs.append(r)
        A = [[coef(j, i - lo) for i in miss] for j, _ in use]
        for i, d in zip(miss, solve(A, rhs)):
            out[i] = d[:last_len] if i == total - 1 else d
    return out


def lcg_bytes(seed, n):
    out = bytearray()
    s = seed
    for _ in range(n):
        s = (s * 1103515245 + 12345) & 0x7FFFFFFF
        out.append((s >> 16) & 0xFF)
    return bytes(out)


def test_clip(n, P, last, seed):
    return [lcg_bytes(seed + i, P if i < n - 1 else last) for i in range(n)]


CASES = [  # (sid, packets, packet size, last packet size, image)
    (0x12345678, 11, 156, 60, False),
    (0x0BADF00D, 3, 156, 156, False),
    (0xCAFEBABE, 47, 156, 17, True),
]

if __name__ == "__main__":
    if sys.argv[1] == "vectors":
        lines = ["# VOX FEC test vectors (scripts/vox/fec_ref.py vectors). Data packet i of a case is",
                 "# lcg_bytes(seed + i, size): s = (s * 1103515245 + 12345) & 0x7fffffff, byte = (s >> 16) & 0xff,",
                 "# seed = the case's sid. One line per parity packet: case number, then the payload in hex."]
        for c, (sid, n, P, last, image) in enumerate(CASES):
            pk = test_clip(n, P, last, sid)
            lines.append(f"case {c} sid {sid:08x} packets {n} size {P} last {last} image {int(image)}")
            for p in encode(sid, pk, image):
                lines.append(f"{c} {p.hex()}")
        open(sys.argv[2], "w").write("\n".join(lines) + "\n")
    # Self-check: every pattern of up to the parity count lost per block comes back.
    import itertools
    import random
    rng = random.Random(1)
    for sid, n, P, last, image in CASES:
        pk = test_clip(n, P, last, sid)
        par = encode(sid, pk, image)
        pmap = {p[5]: p[6:] for p in par}
        for trial in range(200):
            lost = set()
            for b in range((n + BLOCK - 1) // BLOCK):
                lo, hi = b * BLOCK, min(n, (b + 1) * BLOCK)
                m = parity_count(hi - lo, image)
                lost |= set(rng.sample(range(lo, hi), rng.randint(0, m)))
            present = {i: p for i, p in enumerate(pk) if i not in lost}
            got = rebuild(n, present, pmap)
            assert set(got) == lost, (sid, sorted(lost), sorted(got))
            assert all(got[i] == pk[i] for i in lost)
    print("fec_ref: self-check ok")
