#!/usr/bin/env python3
"""The app's AI sketch HD self-test (AeicHdRunner.selfTest), for CI.

    self_test.py PROGRAM [PACK_DIR]

Downloads the model pack the app uses (kAeicHdPackTag) into PACK_DIR unless it
is already there, then checks PROGRAM against the reference codec:

  * encoding the pack's sample photo must give exactly the reference's bytes
    (anything else and photos sent from this build could decode wrongly on
    another device), and
  * decoding the reference stream must give the reference picture to within
    35 dB PSNR, as the app requires.

Standard library only, so it runs on every CI runner. PROGRAM may be a
command with arguments ("arch -x86_64 path"), split on spaces.
"""

import array
import hashlib
import json
import math
import os
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.request

TAG = 'aeic-ncnn-ft2-512-v1'   # lib/vox/aeic_hd_service.dart kAeicHdPackTag
BASE = f'https://github.com/jade-on-mesh/meshcore-open-tak/releases/download/{TAG}/'
SIDE = 512


def fetch_pack(pack):
    if os.path.exists(os.path.join(pack, '.complete')):
        return
    os.makedirs(pack, exist_ok=True)
    with urllib.request.urlopen(BASE + 'manifest.json') as r:
        manifest = json.load(r)
    for a in manifest['archives']:
        tar = os.path.join(pack, a['asset'])
        print('downloading', a['asset'], a['size'], 'bytes', flush=True)
        h = hashlib.sha256()
        with urllib.request.urlopen(BASE + a['asset']) as r, open(tar, 'wb') as f:
            while True:
                chunk = r.read(1 << 20)
                if not chunk:
                    break
                h.update(chunk)
                f.write(chunk)
        if h.hexdigest() != a['sha256']:
            sys.exit(f'{a["asset"]}: SHA-256 mismatch')
        with tarfile.open(tar) as t:
            for m in t.getmembers():
                if m.isfile():
                    m.name = os.path.basename(m.name)   # one flat folder, as the app lays it out
                    t.extract(m, pack)
        os.remove(tar)
    for f in manifest['files']:
        p = os.path.join(pack, f['path'].split('/')[-1])
        if not os.path.exists(p) or os.path.getsize(p) != f['size']:
            sys.exit(f'model file {p} missing or wrong size')
    open(os.path.join(pack, '.complete'), 'w').write(manifest.get('checkpoint_sha256', 'ok'))


def run(program, args, done):
    start = time.time()
    r = subprocess.run(program + args, capture_output=True, text=True)
    tail = (r.stdout + r.stderr).strip().splitlines()[-6:]
    ok = r.returncode == 0 and any(l.startswith(done) for l in r.stdout.splitlines())
    print(f'{done if ok else "FAILED"} in {time.time() - start:.0f} s', flush=True)
    if not ok:
        print('\n'.join(tail))
        sys.exit(f'codec exited {r.returncode}')


def psnr(ppm_path, ref_path):
    n = SIDE * SIDE
    rgb = open(ppm_path, 'rb').read()[-n * 3:]
    ref = array.array('f')
    ref.frombytes(open(ref_path, 'rb').read())
    if sys.byteorder != 'little':
        ref.byteswap()
    se = 0.0
    for c in range(3):
        base = c * n
        for i in range(n):
            v = (ref[base + i] + 1) * 127.5
            d = rgb[i * 3 + c] - round(min(255.0, max(0.0, v)))
            se += d * d
    mse = se / (n * 3)
    return 99.0 if mse == 0 else 10 * math.log10(255 * 255 / mse)


def main():
    program = sys.argv[1].split(' ')
    pack = os.path.abspath(sys.argv[2] if len(sys.argv) > 2 else 'aeic-pack')
    fetch_pack(pack)
    threads = str(min(8, os.cpu_count() or 1))
    with tempfile.TemporaryDirectory() as work:
        encoded = os.path.join(work, 'test.aeic')
        run(program, ['--encode', '--model-dir', pack, '--input', os.path.join(pack, 'input.ppm'),
                      '--bitstream-output', encoded, '--threads', threads], 'ENCODE_COMPLETE')
        want = open(os.path.join(pack, 'sample.aeic'), 'rb').read()
        got = open(encoded, 'rb').read()
        if want != got:
            sys.exit(f'encode differs from the reference ({len(got)} vs {len(want)} bytes)')
        print('encode: identical to the reference')
        decoded = os.path.join(work, 'test.ppm')
        run(program, ['--model-dir', pack, '--bitstream', os.path.join(pack, 'sample.aeic'),
                      '--output', decoded, '--threads', threads], 'DECODE_COMPLETE')
        p = psnr(decoded, os.path.join(pack, 'reference_rgb.f32'))
        print(f'decode: {p:.1f} dB from the reference')
        if p < 35:
            sys.exit('decode too far from the reference (under 35 dB)')
    print('AI sketch HD self-test passed')


if __name__ == '__main__':
    main()
