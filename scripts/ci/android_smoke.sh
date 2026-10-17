#!/usr/bin/env bash
# Android smoke test (smoke.yml): install the release APK, start it, and wait for
# the first frame the app logs ("MeshCoreOpen: first frame", lib/main.dart).
#
# Fails when the first frame never comes, or when the log shows the kind of
# error a release build alone produces: classes or methods R8 removed, a native
# library that won't load, a plugin missing, or the process dying. Other uncaught
# errors (no Bluetooth on an emulator, no network) are listed, not fatal.
set -uo pipefail

APK="${1:?usage: android_smoke.sh app.apk}"
PKG="com.jadeonmesh.meshcore_open_vox"
ACT="com.meshcore.meshcore_open.MainActivity"
TIMEOUT="${SMOKE_TIMEOUT:-180}"
FATAL='NoSuchMethodError|NoSuchFieldError|ClassNotFoundException|NoClassDefFoundError|UnsatisfiedLinkError|MissingPluginException|FATAL EXCEPTION|JNI DETECTED ERROR|Fatal signal'

adb wait-for-device
adb install -r -g "$APK" || { echo "::error::adb install failed"; exit 1; }
adb logcat -c
adb shell am start -W -n "$PKG/$ACT"

start=$(date +%s)
result=timeout
while :; do
  log=$(adb logcat -d -v brief 2>/dev/null)
  if grep -q "MeshCoreOpen: first frame" <<<"$log"; then result=ok; break; fi
  if grep -Eq "$FATAL" <<<"$log"; then result=fatal; break; fi
  if ! adb shell pidof "$PKG" >/dev/null 2>&1 && [ $(( $(date +%s) - start )) -gt 20 ]; then
    result=died; break
  fi
  [ $(( $(date +%s) - start )) -ge "$TIMEOUT" ] && break
  sleep 3
done
elapsed=$(( $(date +%s) - start ))
log=$(adb logcat -d -v brief 2>/dev/null)

grep -E "MeshCoreOpen: (uncaught error|startup step)" <<<"$log" | head -20 | while IFS= read -r l; do
  echo "::warning::${l}"
done

case "$result" in
  ok)
    if grep -Eq "$FATAL" <<<"$log"; then
      echo "::error::first frame after ${elapsed}s, but the log has a release-build error:"
      grep -E -m 10 "$FATAL" <<<"$log" | while IFS= read -r l; do echo "::error::${l}"; done
      exit 1
    fi
    echo "::notice::first frame after ${elapsed}s"
    exit 0 ;;
  fatal)
    echo "::error::release-build error after ${elapsed}s:"
    grep -E -A3 -m 5 "$FATAL" <<<"$log" | head -30 | while IFS= read -r l; do echo "::error::${l}"; done ;;
  died)
    echo "::error::the app's process ended after ${elapsed}s without a first frame" ;;
  *)
    echo "::error::no first frame in ${TIMEOUT}s (stuck on the splash screen?)" ;;
esac
echo "---- last flutter / AndroidRuntime lines ----"
grep -E " (flutter|AndroidRuntime|DEBUG)\b|${PKG}" <<<"$log" | tail -60
exit 1
