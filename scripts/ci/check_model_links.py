#!/usr/bin/env python3
"""Checks that every model the app downloads is really there.

The photo enhancer shipped pointing at a release (upscale-onnx-v2) that had not
been published, and every phone got "HTTP 404". This reads the model links out
of the app's source and checks each one before a build reaches a phone:

  * this repo's GitHub releases (enhancer, voice restorer, Mimi, the AEIC HD
    pack): the release exists and has the asset, at the size the app expects
    when it states one; the AEIC pack's manifest.json lists archives that are
    there at their sizes;
  * Hugging Face links (translation, AEIC-SE): they aren't gone (a 5xx or a
    timeout is reported but doesn't fail: it's someone else's outage).

Nothing is downloaded but the AEIC manifest (a few KB). GitHub is asked through
its API with GITHUB_TOKEN when set. Exits 1 listing every link that fails, and
also when it finds fewer links than it should (a refactor it no longer reads).

Usage: python3 scripts/ci/check_model_links.py [repo root]
"""
import json
import os
import re
import sys
import urllib.error
import urllib.request

ROOT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "..", "..")
REPO = "jade-on-mesh/meshcore-open-tak"
RELEASE_URL = re.compile(
    r"https://github\.com/jade-on-mesh/meshcore-open-tak/releases/download/'\s*'([A-Za-z0-9._-]+|\$\w+)/"
)

# At least this many of each, or the reader has gone stale.
MIN_RELEASE_ASSETS = 5   # enhancer, voice restorer, Mimi encoder + decoder, AEIC pack
MIN_HF_LINKS = 5


def read(path):
    with open(os.path.join(ROOT, path), encoding="utf-8") as f:
        return f.read()


def dart_files():
    for d, _, files in os.walk(os.path.join(ROOT, "lib")):
        for n in files:
            if n.endswith(".dart"):
                p = os.path.join(d, n)
                yield os.path.relpath(p, ROOT), read(os.path.relpath(p, ROOT))


def ints(s):
    return int(s.replace("_", ""))


def release_assets():
    """(tag, asset name, expected bytes or None, where) for every release model."""
    out = []
    up = read("lib/vox/vox_upscale.dart")
    m_name = re.search(r"class VoxUpscaleModel\s*\{.*?static const name = '([^']+)'", up, re.S)
    m_bytes = re.search(r"class VoxUpscaleModel\s*\{.*?static const bytes = ([0-9_]+)", up, re.S)
    m_tag = re.search(r"releases/download/'\s*'([A-Za-z0-9._-]+)/\$name'", up)
    if m_name and m_bytes and m_tag:
        out.append((m_tag.group(1), m_name.group(1), ints(m_bytes.group(1)), "VoxUpscaleModel"))

    ve = read("lib/vox/vox_voice_enhance.dart")
    for m in re.finditer(
        r"VoxVoiceModelSpec\(\s*name:\s*'([^']+)',\s*sha256Hex:\s*'[0-9a-f]+',\s*bytes:\s*([0-9_]+),\s*tag:\s*'([^']+)'",
        ve,
    ):
        out.append((m.group(3), m.group(1), ints(m.group(2)), "VoxVoiceModelSpec"))

    mi = read("lib/vox/mimi.dart")
    m_tag = re.search(r"releases/download/'\s*'([A-Za-z0-9._-]+)/\$name'", mi)
    for m in re.finditer(r"VoxMimiFile\(\s*'([^']+)',\s*'[0-9a-f]+',\s*([0-9_]+),?\s*\)", mi):
        if m_tag:
            out.append((m_tag.group(1), m.group(1), ints(m.group(2)), "VoxMimiFile"))

    ae = read("lib/vox/aeic_hd_service.dart")
    m = re.search(r"kAeicHdPackTag\s*=\s*'([^']+)'", ae)
    if m:
        out.append((m.group(1), "manifest.json", None, "kAeicHdPackTag"))
    return out


def hf_links():
    links = set()
    for _, src in dart_files():
        for m in re.finditer(r"'(https://huggingface\.co/[^']+/resolve/[^']+)'", src):
            links.add(m.group(1))
    return sorted(links)


def gh_get(path):
    req = urllib.request.Request("https://api.github.com/" + path)
    req.add_header("Accept", "application/vnd.github+json")
    tok = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if tok:
        req.add_header("Authorization", "Bearer " + tok)
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read())


def gh_asset_bytes(asset_id):
    req = urllib.request.Request(f"https://api.github.com/repos/{REPO}/releases/assets/{asset_id}")
    req.add_header("Accept", "application/octet-stream")
    tok = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if tok:
        req.add_header("Authorization", "Bearer " + tok)
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read()


def answers(url):
    for method in ("HEAD", "GET"):
        req = urllib.request.Request(url, method=method)
        req.add_header("User-Agent", "meshcore-open-tak-ci")
        if method == "GET":
            req.add_header("Range", "bytes=0-0")
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                return r.status < 400, r.status
        except urllib.error.HTTPError as e:
            if method == "HEAD" and e.code in (403, 405):
                continue
            return False, e.code
        except Exception as e:  # noqa: BLE001 - report anything
            return False, str(e)
    return False, "no answer"


def main():
    failures = []
    assets = release_assets()
    links = hf_links()
    print(f"{len(assets)} release model(s), {len(links)} Hugging Face link(s)")
    if len(assets) < MIN_RELEASE_ASSETS:
        failures.append(f"only {len(assets)} release models found in the source (expected {MIN_RELEASE_ASSETS}+): update this script")
    if len(links) < MIN_HF_LINKS:
        failures.append(f"only {len(links)} Hugging Face links found (expected {MIN_HF_LINKS}+): update this script")

    releases = {}
    for tag, name, want, where in assets:
        if tag not in releases:
            try:
                releases[tag] = gh_get(f"repos/{REPO}/releases/tags/{tag}")
            except urllib.error.HTTPError as e:
                releases[tag] = None
                failures.append(f"{where}: release {tag} is missing (HTTP {e.code}): publish it before shipping")
        rel = releases[tag]
        if rel is None:
            continue
        got = {a["name"]: a for a in rel.get("assets", [])}
        a = got.get(name)
        if a is None:
            failures.append(f"{where}: release {tag} has no {name}")
            continue
        if a.get("state") != "uploaded":
            failures.append(f"{where}: {tag}/{name} isn't fully uploaded ({a.get('state')})")
        if want is not None and a["size"] != want:
            failures.append(f"{where}: {tag}/{name} is {a['size']} bytes, the app expects {want}")
        print(f"  ok  {tag}/{name} ({a['size']} bytes)")
        if name == "manifest.json":
            try:
                man = json.loads(gh_asset_bytes(a["id"]))
                for arc in man.get("archives", []):
                    b = got.get(arc["asset"])
                    if b is None:
                        failures.append(f"{where}: {tag} manifest lists {arc['asset']}, which isn't in the release")
                    elif b["size"] != int(arc["size"]):
                        failures.append(f"{where}: {tag}/{arc['asset']} is {b['size']} bytes, the manifest says {arc['size']}")
                    else:
                        print(f"  ok  {tag}/{arc['asset']} ({b['size']} bytes)")
            except Exception as e:  # noqa: BLE001
                failures.append(f"{where}: {tag}/manifest.json unreadable: {e}")

    # Someone else's site: gone (404/410/401/403) fails the check; down for a
    # moment (5xx, a timeout) is only reported, so it doesn't hold up a build.
    for url in links:
        ok, code = answers(url)
        if ok:
            print(f"  ok  {url} ({code})")
        elif isinstance(code, int) and code in (401, 403, 404, 410):
            failures.append(f"{url}: HTTP {code}")
        else:
            print(f"  ??  {url}: {code} (not counted: may be a passing outage)")

    if failures:
        print("\nModel links that would fail on a phone:")
        for f in failures:
            print("  - " + f)
        return 1
    print("All model links answer.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
