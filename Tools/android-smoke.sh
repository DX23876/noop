#!/bin/bash
# Emulator smoke test of the Android demo build across screen sizes (Android plan D-8).
#
#   Tools/android-smoke.sh            # every profile below
#   Tools/android-smoke.sh small fold # only these
#
# Creates the emulators on first use (system image android-35 google_apis arm64-v8a), boots each in turn,
# installs android/app/build/outputs/apk/demo/debug/app-demo-debug.apk (build it first with
# ./gradlew assembleDemoDebug), runs Tools/android_smoke_flow.py and writes screenshots to
# artifacts/android/<profile>/ (not versioned). A profile is: name, device definition, font scale, night mode.
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export PATH="$PATH:$SDK/platform-tools:$SDK/emulator"
AVDM="$(ls "$SDK"/cmdline-tools/*/bin/avdmanager | head -1)"
IMAGE="system-images;android-35;google_apis;arm64-v8a"
APK="$ROOT/android/app/build/outputs/apk/demo/debug/app-demo-debug.apk"
PROFILES=(
  "small:small_phone:1.0:no"
  "pixel8:pixel_8:1.0:no"
  "pixel8-large-dark:pixel_8:1.3:yes"
  "fold:pixel_9_pro_fold:1.0:no"
  "tablet:pixel_tablet:1.0:no"
)
[ -f "$APK" ] || { echo "android-smoke: build the demo APK first (cd android && ./gradlew assembleDemoDebug)" >&2; exit 1; }
adb emu kill >/dev/null 2>&1 || true
for entry in "${PROFILES[@]}"; do
  IFS=: read -r name device scale night <<< "$entry"
  if [ $# -gt 0 ] && [[ " $* " != *" $name "* ]]; then continue; fi
  avd="noop-smoke-$device"
  "$AVDM" list avd -c 2>/dev/null | grep -qx "$avd" || echo no | "$AVDM" create avd -n "$avd" -k "$IMAGE" -d "$device" >/dev/null
  emulator -avd "$avd" -no-window -no-audio -no-snapshot-save >/dev/null 2>&1 &
  adb wait-for-device
  for _ in $(seq 1 120); do [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ] && break; sleep 2; done
  sleep 5
  adb shell settings put system font_scale "$scale"
  adb shell cmd uimode night "$night" >/dev/null
  adb install -r "$APK" >/dev/null
  adb shell pm clear io.github.dx23876.noop.demo.debug >/dev/null
  out="$ROOT/artifacts/android/$name"; rm -rf "$out"; mkdir -p "$out"
  echo "== $name: $(adb shell wm size | tr -d '\r' | tail -1), font x$scale, night $night"
  python3 "$ROOT/Tools/android_smoke_flow.py" "$out"
  adb emu kill >/dev/null 2>&1 || true
  sleep 8
done
