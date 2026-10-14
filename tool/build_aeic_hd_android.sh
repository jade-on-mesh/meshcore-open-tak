#!/usr/bin/env bash
# Builds the AEIC HD codec program (mikecarper/AEIC's mobile/native
# `aeic_decode`, which also encodes) for arm64-v8a, against ncnn.
#
#   tool/build_aeic_hd_android.sh NDK_DIR OUT_DIR
#
# Writes OUT_DIR/libaeic_codec_exec.so. It is an executable, not a library:
# it is named lib*.so and shipped in jniLibs only so Android installs it,
# executable, into the app's nativeLibraryDir (useLegacyPackaging = true),
# which is the one place an app may run a program from. The app starts it
# with Process.start (lib/vox/aeic_hd_service.dart).
#
# ncnn is built with every CPU-specific fast path off (ARMv8.2 fp16/dot,
# bf16, i8mm, SVE): the entropy model must give bit-identical numbers on the
# sending and the receiving phone, and those paths differ between chips. This
# matches mikecarper's own mobile/native/build_android.sh.
set -euo pipefail

ndk=${1:?NDK directory}
out=${2:?output directory}
aeic_repo=${AEIC_REPO:-https://github.com/mikecarper/AEIC}
aeic_commit=${AEIC_COMMIT:-b00795ca709354f987e868f6b9e608961ec80831}
ncnn_commit=b0f97f43f266617ff5e5096d440dbe3f9a4c35b8
work=${AEIC_BUILD_DIR:-/tmp/aeic-hd-build}
abi=arm64-v8a
jobs=$(nproc 2>/dev/null || echo 4)

mkdir -p "$work" "$out"
toolchain="$ndk/build/cmake/android.toolchain.cmake"
test -f "$toolchain" || { echo "no NDK toolchain at $toolchain" >&2; exit 1; }

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

cmake -S "$work/ncnn" -B "$work/ncnn-$abi" \
  -DCMAKE_TOOLCHAIN_FILE="$toolchain" -DANDROID_ABI=$abi \
  -DANDROID_PLATFORM=android-21 -DANDROID_STL=c++_static \
  -DCMAKE_BUILD_TYPE=Release -DNCNN_VERSION=20261013 \
  -DNCNN_VULKAN=OFF -DNCNN_SHARED_LIB=OFF -DNCNN_BUILD_TOOLS=OFF \
  -DNCNN_BUILD_EXAMPLES=OFF -DNCNN_BUILD_BENCHMARK=OFF -DNCNN_BUILD_TESTS=OFF \
  -DNCNN_ARM82=OFF -DNCNN_ARM82DOT=OFF -DNCNN_ARM82FP16FML=OFF \
  -DNCNN_ARM84BF16=OFF -DNCNN_ARM84I8MM=OFF \
  -DNCNN_ARM86SVE=OFF -DNCNN_ARM86SVE2=OFF \
  -DCMAKE_INSTALL_PREFIX="$work/ncnn-install-$abi" >/dev/null
cmake --build "$work/ncnn-$abi" -j "$jobs" >/dev/null
cmake --install "$work/ncnn-$abi" >/dev/null

cmake -S "$work/aeic/mobile/native" -B "$work/codec-$abi" \
  -DCMAKE_TOOLCHAIN_FILE="$toolchain" -DANDROID_ABI=$abi \
  -DANDROID_PLATFORM=android-21 -DANDROID_STL=c++_static \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF \
  -Dncnn_DIR="$work/ncnn-install-$abi/lib/cmake/ncnn" >/dev/null
cmake --build "$work/codec-$abi" -j "$jobs"

cp "$work/codec-$abi/aeic_decode" "$out/libaeic_codec_exec.so"
"$ndk/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip" --strip-unneeded "$out/libaeic_codec_exec.so"
ls -la "$out/libaeic_codec_exec.so"
sha256sum "$out/libaeic_codec_exec.so"
