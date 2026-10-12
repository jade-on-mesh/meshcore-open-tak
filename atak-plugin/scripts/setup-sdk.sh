#!/usr/bin/env bash
# One-time setup for building the MeshCore ATAK plugin.
#
#   scripts/setup-sdk.sh /path/to/ATAK-CIV-5.8.0.5-SDK.zip
#   scripts/setup-sdk.sh /path/to/ATAK-CIV-5.8.0.5-SDK      (already unpacked)
#
# The ATAK-CIV SDK comes from tak.gov and can't live in this repo. This puts
# it in atak-plugin/sdk/atak-civ, copies the Gradle wrapper jar from the
# SDK's plugin template (Git LFS keeps .jar files out of this repo), and
# points local.properties at it. A .7z download: extract the .zip inside it
# first. Works with the 5.x layout (samples/) and the 4.x one
# (plugin-examples/).
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
src="${1:?usage: setup-sdk.sh /path/to/ATAK-CIV-SDK.zip (or unpacked folder)}"
dest="$here/sdk/atak-civ"

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp:?}"' EXIT
if [ -d "$src" ]; then
  root="$src"
else
  case "$src" in
    *.zip) unzip -q -o "$src" -d "$tmp" ;;
    *.7z|*.7z.001|*_7z.001)
      echo "Extract the .7z with 7-Zip first, then pass the .zip (or folder) inside it." >&2
      exit 1 ;;
    *) echo "Expected a .zip or a folder: $src" >&2; exit 1 ;;
  esac
  root="$tmp"
fi

# The folder that holds main.jar is the SDK root, whatever it is named.
jar="$(find "$root" -maxdepth 3 -name main.jar -path '*' | head -n 1)"
[ -n "$jar" ] || { echo "No main.jar found in $src: is this the ATAK SDK?" >&2; exit 1; }
sdkroot="$(dirname "$jar")"
mkdir -p "$here/sdk"
if [ "$(cd "$sdkroot" && pwd)" != "$(mkdir -p "$dest" && cd "$dest" && pwd)" ]; then
  rm -rf "${dest:?}"
  mkdir -p "$dest"
  # The bundled atak.apk (~400 MB) isn't needed to build the plugin.
  (cd "$sdkroot" && tar cf - --exclude='./atak.apk' .) | (cd "$dest" && tar xf -)
fi

version="$(basename "$sdkroot" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?' || true)"
[ -n "$version" ] || version="$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' "$dest/CHANGELOG.txt" 2>/dev/null | head -n 1 || true)"
[ -n "$version" ] || version="$(cat "$dest/VERSION.txt" 2>/dev/null || echo unknown)"
echo "ATAK SDK: $version"

template=""
for t in "$dest/samples/plugintemplate" "$dest/plugin-examples/plugintemplate"; do
  [ -f "$t/gradle/wrapper/gradle-wrapper.jar" ] && { template="$t"; break; }
done
[ -n "$template" ] || { echo "No plugintemplate with a Gradle wrapper in the SDK" >&2; exit 1; }
mkdir -p "$here/gradle/wrapper"
cp "$template/gradle/wrapper/gradle-wrapper.jar" "$here/gradle/wrapper/"
chmod +x "$here/gradlew"

props="$here/local.properties"
set_prop() { # key value
  if [ -f "$props" ] && grep -q "^$1=" "$props"; then
    tmpf="$(mktemp)"
    grep -v "^$1=" "$props" > "$tmpf"; cat "$tmpf" > "$props"; rm -f "$tmpf"
  fi
  printf '%s=%s\n' "$1" "$2" >> "$props"
}
if [ ! -f "$props" ]; then
  cat > "$props" <<PROPS
# Android SDK (Android Studio: File > Project Structure > SDK Location)
sdk.dir=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/path/to/Android/sdk}}
# Debug builds are signed with the SDK's development key by default. To use
# your own, set takDebugKeyFile, takDebugKeyFilePassword, takDebugKeyAlias
# and takDebugKeyPassword. Release builds need the takRelease* equivalents.
PROPS
  echo "Wrote local.properties; check sdk.dir."
fi
set_prop takdev.plugin "$dest/atak-gradle-takdev.jar"
# Where takdev finds ATAK's main.jar and the development keystore.
set_prop sdk.path "$dest"

want="$(grep -oE 'ATAK_VERSION = "[^"]+"' "$here/app/build.gradle" | grep -oE '[0-9.]+' || true)"
case "$version" in
  "$want"*) ;;
  *) echo "Note: app/build.gradle targets ATAK $want but this SDK is $version." \
          "Set ATAK_VERSION to match before building." >&2 ;;
esac
echo "Next: optional scripts/build-libaom.sh (direct-mode photos), then ./gradlew assembleCivDebug"
