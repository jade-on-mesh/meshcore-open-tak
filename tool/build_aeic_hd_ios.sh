#!/usr/bin/env bash
# Builds AI sketch HD's codec for iPhone: mikecarper/AEIC's mobile/native
# program and ncnn, the same sources and settings as
# tool/build_aeic_hd_android.sh and tool/build_aeic_hd_desktop.sh, as one
# static library the app links (third_party/aeic_hd/aeic_hd.podspec).
#
#   tool/build_aeic_hd_ios.sh OUT_DIR      # on a Mac with Xcode
#
# Writes OUT_DIR/lib/libaeic_hd.a (arm64, iOS 16.4). iOS can't start
# programs, so the program runs inside the app: third_party/aeic_hd/
# aeic_hd_ios.cpp includes its main.cpp with `main` renamed and adds
# aeic_hd_run, which lib/vox/aeic_hd_runner_io.dart calls over FFI.
#
# With AEIC_HD_HOST_DRIVER=1 it also builds OUT_DIR/aeic_hd_host: the same
# library for this Mac (arm64) inside a small program that behaves like the
# codec program (third_party/aeic_hd/host_driver.cpp), so CI can self-test the
# in-app code path with tool/aeic_desktop/self_test.py.
#
# Every CPU-specific fast path is off (plain ARMv8 NEON, as on Android and
# the desktop builds): the entropy model must give bit-identical numbers on
# the sending and the receiving device. ncnn's own small OpenMP runtime gives
# it threads, as on macOS.
set -euo pipefail

out=${1:?output directory}
aeic_repo=${AEIC_REPO:-https://github.com/mikecarper/AEIC}
aeic_commit=${AEIC_COMMIT:-b00795ca709354f987e868f6b9e608961ec80831}
ncnn_commit=b0f97f43f266617ff5e5096d440dbe3f9a4c35b8
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
work=${AEIC_BUILD_DIR:-/tmp/aeic-hd-ios}
jobs=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)

mkdir -p "$work" "$out/lib"
out=$(cd "$out" && pwd)

quiet() { # log-name command...
  local log="$work/$1.log"
  shift
  if ! "$@" > "$log" 2>&1; then
    echo "::error::$(basename "$log" .log) failed; the end of its output:" >&2
    tail -60 "$log" >&2
    exit 1
  fi
}

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

# A copy of the program's sources: the in-process stage runner (no fork() in
# an app), the cancel hook at the top of each model stage, the wrapper, and a
# CMake file that makes a library of it all.
src="$work/aeic-ios"
rm -rf "$src" && cp -r "$work/aeic/mobile/native" "$src"
cp "$here/aeic_desktop/recovery_inprocess.cpp" "$src/recovery.cpp"
test "$(grep -c '^void execute(const Args& args, const Stage& stage, Slots& slots) {$' "$src/main.cpp")" = 1
sed -i '' 's/^void execute(const Args& args, const Stage& stage, Slots& slots) {$/& AEIC_STAGE_HOOK();/' "$src/main.cpp"
grep -q 'Slots& slots) { AEIC_STAGE_HOOK();$' "$src/main.cpp"
cp "$root/third_party/aeic_hd/aeic_hd_ios.cpp" "$root/third_party/aeic_hd/host_driver.cpp" "$src/"
cat > "$src/CMakeLists.txt" <<'CMAKE'
cmake_minimum_required(VERSION 3.10)
project(aeic_hd_ios LANGUAGES C CXX)
set(CMAKE_CXX_STANDARD 14)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
find_package(ncnn REQUIRED CONFIG)
add_library(aeic_hd STATIC aeic_hd_ios.cpp png_writer.cpp mat_diagnostics.cpp
  tiled_attention.cpp entropy.cpp rans/rans.cpp recovery.cpp)
target_include_directories(aeic_hd PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(aeic_hd PUBLIC ncnn)
# ncnn exports -fno-exceptions; the program validates files with exceptions.
target_compile_options(aeic_hd PRIVATE -fexceptions)
if(AEIC_HD_HOST_DRIVER)
  find_package(ZLIB REQUIRED)
  add_executable(aeic_hd_host host_driver.cpp)
  target_link_libraries(aeic_hd_host PRIVATE aeic_hd ZLIB::ZLIB)
endif()
CMAKE

# One platform: ncnn, then the library. $1 = a tag, the rest = CMake args.
build_one() {
  local tag=$1
  shift
  quiet "ncnn-configure-$tag" cmake -S "$work/ncnn" -B "$work/ncnn-$tag" "$@" \
    -DCMAKE_BUILD_TYPE=Release -DNCNN_VERSION=20261013 -DNCNN_VULKAN=OFF \
    -DNCNN_SHARED_LIB=OFF -DNCNN_BUILD_TOOLS=OFF -DNCNN_BUILD_EXAMPLES=OFF \
    -DNCNN_BUILD_BENCHMARK=OFF -DNCNN_BUILD_TESTS=OFF -DNCNN_RUNTIME_CPU=OFF \
    -DNCNN_OPENMP=ON -DNCNN_SIMPLEOMP=ON \
    -DNCNN_ARM82=OFF -DNCNN_ARM82DOT=OFF -DNCNN_ARM82FP16FML=OFF \
    -DNCNN_ARM84BF16=OFF -DNCNN_ARM84I8MM=OFF -DNCNN_ARM86SVE=OFF -DNCNN_ARM86SVE2=OFF \
    -DCMAKE_INSTALL_PREFIX="$work/ncnn-install-$tag"
  quiet "ncnn-build-$tag" cmake --build "$work/ncnn-$tag" -j "$jobs"
  quiet "ncnn-install-$tag" cmake --install "$work/ncnn-$tag"
  quiet "codec-configure-$tag" cmake -S "$src" -B "$work/codec-$tag" "$@" \
    -DCMAKE_BUILD_TYPE=Release -Dncnn_DIR="$work/ncnn-install-$tag/lib/cmake/ncnn"
  quiet "codec-build-$tag" cmake --build "$work/codec-$tag" -j "$jobs"
}

build_one ios -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=16.4
# One archive with ncnn inside, so the pod vendors a single library.
libtool -static -o "$out/lib/libaeic_hd.a" "$work/codec-ios/libaeic_hd.a" \
  "$work/ncnn-install-ios/lib/libncnn.a"
lipo -info "$out/lib/libaeic_hd.a"
syms=$(nm -gU "$out/lib/libaeic_hd.a" 2>/dev/null || true)
for s in aeic_hd_run aeic_hd_available aeic_hd_cancel aeic_hd_total_memory; do
  grep -q " _$s\$" <<<"$syms" || { echo "::error::$s is not in libaeic_hd.a" >&2; exit 1; }
done

if [ "${AEIC_HD_HOST_DRIVER:-}" = 1 ]; then
  build_one host -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0 \
    -DAEIC_HD_HOST_DRIVER=ON
  cp "$work/codec-host/aeic_hd_host" "$out/aeic_hd_host"
fi
ls -la "$out" "$out/lib"
