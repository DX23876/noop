#!/usr/bin/env bash
# Runs the packaged-core notification/history regression on an emulator. Build the full debug app and
# assembleFullDebugAndroidTest first. No Bluetooth device or strap write is involved.
set -euo pipefail

APP_APK="${1:?usage: android-core-replay.sh <full-debug.apk> <androidTest.apk> [emulator-serial]}"
TEST_APK="${2:?usage: android-core-replay.sh <full-debug.apk> <androidTest.apk> [emulator-serial]}"
SERIAL="${3:-emulator-5554}"
ADB="${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb"
case "$SERIAL" in emulator-*) ;; *) echo 'This replay uses an emulator, not a physical device.' >&2; exit 2 ;; esac

"$ADB" -s "$SERIAL" install -r "$APP_APK" >/dev/null
"$ADB" -s "$SERIAL" install -r "$TEST_APK" >/dev/null
RESULT="$("$ADB" -s "$SERIAL" shell am instrument -w -r \
  -e class com.noop.core.CoreStrapReplayTest \
  io.github.dx23876.noop.debug.test/androidx.test.runner.AndroidJUnitRunner)"
printf '%s\n' "$RESULT"
# ADB returns success even when the instrumented native process crashed. Require the test runner's verdict.
printf '%s\n' "$RESULT" | grep -Eq '^OK \([1-9][0-9]* tests?\)'
