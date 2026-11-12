#!/usr/bin/env bash
# Builds the AEIC HD codec program (mikecarper/AEIC's mobile/native
# `aeic_decode`, which also encodes) for a desktop build of the app, against
# ncnn, the same sources as tool/build_aeic_hd_android.sh.
#
#   tool/build_aeic_hd_desktop.sh linux   OUT_DIR   # x86_64 (or the host's arch)
#   tool/build_aeic_hd_desktop.sh macos   OUT_DIR   # universal arm64 + x86_64
#   tool/build_aeic_hd_desktop.sh windows OUT_DIR   # x86_64, in an MSYS2 MINGW64 shell
#
# Writes OUT_DIR/aeic_codec (aeic_codec.exe on Windows), a self-contained
# program the app runs with Process.start (lib/vox/aeic_hd_runner_io.dart).
#
# Every CPU-specific fast path is off, as on Android: the entropy model must
# give bit-identical numbers on the sending and the receiving device, and those
# paths (AVX/FMA/F16C on x86, ARMv8.2 fp16/dot and later on ARM) round
# differently between chips. Nothing extra ships next to the program (see the
# OpenMP note below). The app's self-test (AI sketch HD settings) checks a
# device against the reference; .github/workflows/aeic-hd-desktop.yml runs it
# on all three.
#
# Windows has no fork(): each model stage runs in-process there
# (tool/aeic_desktop/recovery_inprocess.cpp) instead of in a child.
set -euo pipefail

os=${1:?linux, macos or windows}
out=${2:?output directory}
aeic_repo=${AEIC_REPO:-https://github.com/mikecarper/AEIC}
aeic_commit=${AEIC_COMMIT:-b00795ca709354f987e868f6b9e608961ec80831}
ncnn_commit=b0f97f43f266617ff5e5096d440dbe3f9a4c35b8
here=$(cd "$(dirname "$0")" && pwd)
work=${AEIC_BUILD_DIR:-/tmp/aeic-hd-desktop}
jobs=$( (nproc || sysctl -n hw.ncpu) 2>/dev/null || echo 4)

mkdir -p "$work" "$out"
out=$(cd "$out" && pwd)
# Ninja when there is one (faster), else CMake's default generator.
gen=()
if command -v ninja >/dev/null 2>&1; then gen=(-G Ninja); fi
# ncnn's own small OpenMP runtime, so no libgomp/libomp ships with the
# program. MinGW can't build that one (it needs POSIX threads' pthread_once),
# so Windows links MinGW's libgomp statically instead. AEIC_OPENMP=off builds
# it single-threaded.
default_omp=simple
[ "$os" = windows ] && default_omp=gomp
case "${AEIC_OPENMP:-$default_omp}" in
  off) omp=(-DNCNN_OPENMP=OFF) ;;
  gomp) omp=(-DNCNN_OPENMP=ON -DNCNN_SIMPLEOMP=OFF) ;;
  *) omp=(-DNCNN_OPENMP=ON -DNCNN_SIMPLEOMP=ON) ;;
esac

fetch() { # url commit dir
  if [ ! -d "$3/.git" ]; then
    git init -q "$3"
    git -C "$3" remote add origin "$1"
  fi
  git -C "$3" fetch -q --depth 1 origin "$2"
  git -C "$3" checkout -q --detach FETCH_HEAD
  test "$(git -C "$3" rev-parse HEAD)" = "$2"
}
fetch https://github.com/Tencent/ncnn.git "$ncnn_commit" "$work/ncnn"
fetch "$aeic_repo" "$aeic_commit" "$work/aeic"

ncnn_common=(
  -DCMAKE_BUILD_TYPE=Release -DNCNN_VERSION=20261013
  -DNCNN_VULKAN=OFF -DNCNN_SHARED_LIB=OFF -DNCNN_BUILD_TOOLS=OFF
  -DNCNN_BUILD_EXAMPLES=OFF -DNCNN_BUILD_BENCHMARK=OFF -DNCNN_BUILD_TESTS=OFF
  -DNCNN_RUNTIME_CPU=OFF
  # x86: SSE2 only (the x86_64 baseline).
  -DNCNN_SSE2=ON -DNCNN_AVX=OFF -DNCNN_XOP=OFF -DNCNN_FMA=OFF -DNCNN_F16C=OFF
  -DNCNN_AVX2=OFF -DNCNN_AVXVNNI=OFF -DNCNN_AVXVNNIINT8=OFF -DNCNN_AVXVNNIINT16=OFF
  -DNCNN_AVXNECONVERT=OFF -DNCNN_AVX512=OFF -DNCNN_AVX512VNNI=OFF
  -DNCNN_AVX512BF16=OFF -DNCNN_AVX512FP16=OFF
  # ARM: plain ARMv8 NEON, as on Android.
  -DNCNN_ARM82=OFF -DNCNN_ARM82DOT=OFF -DNCNN_ARM82FP16FML=OFF
  -DNCNN_ARM84BF16=OFF -DNCNN_ARM84I8MM=OFF -DNCNN_ARM86SVE=OFF -DNCNN_ARM86SVE2=OFF
)

# Runs a build step quietly; on failure shows the end of its output.
quiet() { # log-name command...
  local log="$work/$1.log"
  shift
  if ! "$@" > "$log" 2>&1; then
    echo "::error::$(basename "$log" .log) failed; the end of its output:" >&2
    tail -60 "$log" >&2
    exit 1
  fi
}

# One architecture: ncnn, then the program. $1 = a name for the build
# directories, the rest = extra CMake arguments for both.
build_one() {
  local tag=$1
  shift
  quiet "ncnn-configure-$tag" cmake -S "$work/ncnn" -B "$work/ncnn-$tag" ${gen[@]+"${gen[@]}"} \
    "${ncnn_common[@]}" "${omp[@]}" "$@" -DCMAKE_INSTALL_PREFIX="$work/ncnn-install-$tag"
  quiet "ncnn-build-$tag" cmake --build "$work/ncnn-$tag" -j "$jobs"
  quiet "ncnn-install-$tag" cmake --install "$work/ncnn-$tag"

  local src="$work/aeic/mobile/native"
  local extra=()
  if [ "$os" = windows ]; then
    # A copy of the sources with the in-process stage runner and no POSIX
    # resource header, built static so no MinGW DLLs ship with it.
    rm -rf "$work/aeic-win" && cp -r "$src" "$work/aeic-win" && src="$work/aeic-win"
    cp "$here/aeic_desktop/recovery_inprocess.cpp" "$src/recovery.cpp"
    test "$(grep -c '^#include <sys/resource.h>$' "$src/main.cpp")" = 1
    sed -i 's|^#include <sys/resource.h>$|#ifndef _WIN32\n#include <sys/resource.h>\n#endif|' "$src/main.cpp"
    # The GUI subsystem: the app starts it with its output piped, and a
    # console program would flash a console window each time.
    extra=(-DZLIB_USE_STATIC_LIBS=ON
      "-DCMAKE_EXE_LINKER_FLAGS=-static -static-libgcc -static-libstdc++ -Wl,--subsystem,windows")
  fi
  quiet "codec-configure-$tag" cmake -S "$src" -B "$work/codec-$tag" ${gen[@]+"${gen[@]}"} \
    -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF \
    -Dncnn_DIR="$work/ncnn-install-$tag/lib/cmake/ncnn" ${extra[@]+"${extra[@]}"} "$@"
  quiet "codec-build-$tag" cmake --build "$work/codec-$tag" -j "$jobs"
}

case "$os" in
  linux)
    build_one linux
    cp "$work/codec-linux/aeic_decode" "$out/aeic_codec"
    strip --strip-unneeded "$out/aeic_codec"
    ;;
  macos)
    build_one mac-arm64 -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=10.15
    build_one mac-x86_64 -DCMAKE_OSX_ARCHITECTURES=x86_64 -DCMAKE_OSX_DEPLOYMENT_TARGET=10.15
    lipo -create "$work/codec-mac-arm64/aeic_decode" "$work/codec-mac-x86_64/aeic_decode" \
      -output "$out/aeic_codec"
    strip -x "$out/aeic_codec"
    lipo -info "$out/aeic_codec"
    ;;
  windows)
    build_one windows
    cp "$work/codec-windows/aeic_decode.exe" "$out/aeic_codec.exe"
    strip --strip-unneeded "$out/aeic_codec.exe"
    ;;
  *)
    echo "unknown OS $os (linux, macos or windows)" >&2
    exit 1
    ;;
esac
ls -la "$out"
