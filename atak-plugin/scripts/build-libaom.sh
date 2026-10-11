#!/usr/bin/env bash
# Builds libaom (AV1, BSD-2-Clause) for Android so direct-radio mode can
# send and show photos. Same source and options as the app's CI; output goes
# to third_party/aom-android/<ABI>, where both the app and the plugin look.
#
#   ANDROID_NDK_HOME=/path/to/ndk scripts/build-libaom.sh [arm64-v8a armeabi-v7a]
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
ndk="${ANDROID_NDK_HOME:-${ANDROID_NDK_LATEST_HOME:-}}"
[ -d "$ndk" ] || { echo "Set ANDROID_NDK_HOME" >&2; exit 1; }
abis=("${@:-arm64-v8a}")
tmp="$(mktemp -d)"
curl -sSL -o "$tmp/aom.tgz" "https://raw.githubusercontent.com/jade-on-mesh/meshcore-open-tak/deps-cache/aom-v3.12.1.tar.gz"
echo "76558ad5918820d66fa78460d9957e5bbf7cf9eef1a5421b5ba5e616f200d76e  $tmp/aom.tgz" | sha256sum -c
tar xzf "$tmp/aom.tgz" -C "$tmp"
for abi in "${abis[@]}"; do
  cmake -S "$tmp/aom" -B "$tmp/build-$abi" \
    -DCMAKE_TOOLCHAIN_FILE="$ndk/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI="$abi" -DANDROID_PLATFORM=android-21 \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DENABLE_DOCS=0 -DENABLE_EXAMPLES=0 -DENABLE_TESTS=0 -DENABLE_TESTDATA=0 \
    -DENABLE_TOOLS=0 -DCONFIG_AV1_HIGHBITDEPTH=0 -DCONFIG_WEBM_IO=0
  cmake --build "$tmp/build-$abi" -j"$(nproc 2>/dev/null || sysctl -n hw.ncpu)" --target aom
  out="$repo/third_party/aom-android/$abi"
  mkdir -p "$out/lib" "$out/include/aom"
  cp "$tmp/build-$abi/libaom.a" "$out/lib/"
  cp "$tmp/aom/aom/"*.h "$out/include/aom/"
  echo "libaom for $abi -> $out"
done
rm -rf "$tmp"
