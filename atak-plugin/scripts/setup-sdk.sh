#!/usr/bin/env bash
# One-time setup for building the MeshCore ATAK plugin.
#
#   scripts/setup-sdk.sh /path/to/atak-civ-sdk-4_6_0_5.zip
#
# Unpacks the ATAK-CIV SDK (from tak.gov; it can't live in this repo) into
# atak-plugin/sdk/, and copies the Gradle wrapper jar from the SDK's plugin
# template (Git LFS keeps .jar files out of this repo).
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
zip="${1:?usage: setup-sdk.sh /path/to/atak-civ-sdk.zip}"
mkdir -p "$here/sdk"
unzip -q -o "$zip" -d "$here/sdk"
sdk="$here/sdk/atak-civ"
[ -f "$sdk/main.jar" ] || { echo "No atak-civ/main.jar in $zip" >&2; exit 1; }
mkdir -p "$here/gradle/wrapper"
cp "$sdk/plugin-examples/plugintemplate/gradle/wrapper/gradle-wrapper.jar" "$here/gradle/wrapper/"
chmod +x "$here/gradlew"
echo "ATAK SDK: $(cat "$sdk/VERSION.txt" 2>/dev/null || echo unknown)"
if [ ! -f "$here/local.properties" ]; then
  cat > "$here/local.properties" <<PROPS
# Android SDK (Android Studio: File > Project Structure > SDK Location)
sdk.dir=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/path/to/Android/sdk}}
takdev.plugin=$sdk/atak-gradle-takdev.jar
# Where takdev finds ATAK's main.jar (offline SDK build)
sdk.path=$sdk
# Debug signing (ATAK accepts any key for development builds):
#   keytool -genkeypair -v -keystore debug.keystore -alias androiddebugkey \\
#     -storepass android -keypass android -keyalg RSA -validity 10000 -dname "CN=Android Debug"
takDebugKeyFile=$HOME/.android/debug.keystore
takDebugKeyFilePassword=android
takDebugKeyAlias=androiddebugkey
takDebugKeyPassword=android
PROPS
  echo "Wrote local.properties; check sdk.dir and the signing key."
elif ! grep -q '^sdk\.path=' "$here/local.properties"; then
  printf '\n# Where takdev finds ATAK'"'"'s main.jar (offline SDK build)\nsdk.path=%s\n' "$sdk" >> "$here/local.properties"
  echo "Added sdk.path to local.properties."
fi
echo "Next: optional scripts/build-libaom.sh (direct-mode photos), then ./gradlew assembleCivDebug"
