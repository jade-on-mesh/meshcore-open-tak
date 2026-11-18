#!/usr/bin/env bash
# MeshCore Open TAK - puts the ONNX Runtime that flutter_onnxruntime's desktop
# build wants where its CMake looks first, so the build doesn't depend on the
# plugin's own unchecked download (a failed download there only shows up as
# "ONNX Runtime extraction directory doesn't exist").
#
#   tool/fetch_onnxruntime.sh windows build/windows/x64/plugins/flutter_onnxruntime/onnxruntime
#   tool/fetch_onnxruntime.sh linux   build/linux/x64/release/plugins/flutter_onnxruntime/onnxruntime
#
# The version is the one the locked plugin asks for. It tries Microsoft's
# GitHub release, with retries, then the same build from NuGet
# (Microsoft.ML.OnnxRuntime), laid out the way the release archive is.
set -euo pipefail

plat=$1
dest=$2
case "$plat" in
  windows) name_os=win; rid=win-x64 ;;
  linux) name_os=linux; rid=linux-x64 ;;
  *) echo "usage: $0 windows|linux <dest>" >&2; exit 2 ;;
esac

cache=${PUB_CACHE:-$HOME/.pub-cache}
if command -v cygpath >/dev/null 2>&1; then cache=$(cygpath -u "$cache"); fi
pv=$(awk '/^  flutter_onnxruntime:/{f=1} f && /version:/{gsub(/"/, "", $2); print $2; exit}' pubspec.lock)
cmake_file="$cache/hosted/pub.dev/flutter_onnxruntime-$pv/$plat/CMakeLists.txt"
v=$(sed -n 's/.*set(ONNXRUNTIME_VERSION "\([0-9.]*\)").*/\1/p' "$cmake_file" | head -1)
if [ -z "$v" ]; then
  echo "::error::No ONNX Runtime version in $cmake_file" >&2
  exit 1
fi
name="onnxruntime-$name_os-x64-$v"
out="$dest/$name"
if [ -f "$out/include/onnxruntime_cxx_api.h" ]; then
  echo "ONNX Runtime $v already at $out"
  exit 0
fi
mkdir -p "$dest"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

get() { curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 --connect-timeout 30 -o "$2" "$1"; }

ext=$([ "$plat" = windows ] && echo zip || echo tgz)
url="https://github.com/microsoft/onnxruntime/releases/download/v$v/$name.$ext"
echo "Fetching $url"
if get "$url" "$tmp/ort.$ext" && (cd "$dest" && cmake -E tar xf "$tmp/ort.$ext") &&
  [ -f "$out/include/onnxruntime_cxx_api.h" ]; then
  echo "ONNX Runtime $v from GitHub"
  exit 0
fi

echo "::warning::ONNX Runtime $v not available from GitHub ($url); using NuGet"
nupkg="https://api.nuget.org/v3-flatcontainer/microsoft.ml.onnxruntime/$v/microsoft.ml.onnxruntime.$v.nupkg"
get "$nupkg" "$tmp/ort.nupkg"
mkdir -p "$tmp/n"
(cd "$tmp/n" && cmake -E tar xf ../ort.nupkg)
rm -rf "$out"
mkdir -p "$out/include" "$out/lib"
cp -R "$tmp/n/build/native/include/." "$out/include/"
cp -R "$tmp/n/runtimes/$rid/native/." "$out/lib/"
if [ "$plat" = linux ] && [ ! -e "$out/lib/libonnxruntime.so" ]; then
  so=$(ls "$out/lib"/libonnxruntime.so.* | head -1)
  ln -s "$(basename "$so")" "$out/lib/libonnxruntime.so"
fi
ls -la "$out/include" "$out/lib"
[ -f "$out/include/onnxruntime_cxx_api.h" ] || { echo "::error::NuGet package has no C++ headers" >&2; exit 1; }
echo "ONNX Runtime $v from NuGet"
