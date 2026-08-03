#!/usr/bin/env bash
# One-shot release-artifact build: mac universal + iOS AltStore/Full unsigned + Android full,
# each anonymized + leak-checked. Writes both iOS variants through package-ios-ipas.sh.
set -uo pipefail
cd ~/Documents/Strand

# ── Anonymity source guard ─────────────────────────────────────────────────────
# A maintainer name or home path must never reach a release. This is a build-from-
# source project, so the SOURCE (not just the compiled binary) has to stay clean.
# Abort before building if a real identity has leaked into tracked code/docs.
# (A first-name leak in code comments shipped silently for weeks once; never again.)
LEAK="$(git grep -niE 'aaron|iinde|phull' -- '*.swift' '*.kt' '*.md' '*.py' '*.sh' '*.yml' '*.json' '*.xcstrings' 2>/dev/null | grep -ivE 'aaronson' || true)"
if [ -n "$LEAK" ]; then
  echo "✗ ANONYMITY LEAK in tracked source, refusing to build:" >&2
  echo "$LEAK" | head -20 >&2
  exit 1
fi
# Codename guard: the word "Strand" must never reach a USER-FACING string literal (a shipped Android
# toast said "reopen Strand" until v8.2.0). Identifier prefixes (StrandFont/StrandPalette/…) and
# path/comment mentions are fine; a quoted standalone-word use is not.
CODENAME="$(git grep -nE '"[^"]*\bStrand\b[^"]*"' -- '*.swift' '*.kt' 2>/dev/null | grep -vE 'Strand(Font|Palette|Design|Analytics|Tests|iOS)|Strand/|/Strand|scheme|CFBundle|xcodeproj|\.swift"' || true)"
if [ -n "$CODENAME" ]; then
  echo "✗ CODENAME LEAK in a user-facing string, refusing to build:" >&2
  echo "$CODENAME" | head -20 >&2
  exit 1
fi
echo "✓ anonymity source-scan clean"

VER="${1:-7.0.1}"
DIST="dist"; mkdir -p "$DIST"
HOMEPATH="$HOME"
ok_mac=0; ok_ios=0; ok_apk=0

echo "═══ xcodegen ═══"
xcodegen generate >/tmp/v7a-xcodegen.log 2>&1 && echo "xcodegen OK" || { echo "xcodegen FAILED"; tail -5 /tmp/v7a-xcodegen.log; }

# ── macOS universal ───────────────────────────────────────────────────────────
echo "═══ macOS (universal Release) ═══"
rm -rf build/dd
xcodebuild -scheme Strand -configuration Release -derivedDataPath build/dd \
  -destination 'generic/platform=macOS' ARCHS="x86_64 arm64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO build >/tmp/v7a-mac.log 2>&1
MACAPP="build/dd/Build/Products/Release/NOOP.app"
if [ -d "$MACAPP" ]; then
  echo "  built. lipo: $(lipo -info "$MACAPP/Contents/MacOS/NOOP" 2>/dev/null | sed 's#.*: ##')"
  Tools/anonymize-macos-app.sh "$MACAPP" 2>&1 | sed 's/^/  /'
  LEAK=$(grep -rl "$HOMEPATH" "$MACAPP/Contents/MacOS/" 2>/dev/null | head -1)
  ENT=$(codesign -d --entitlements - "$MACAPP" 2>/dev/null | grep -c 'app-sandbox\|bluetooth')
  if [ -n "$LEAK" ]; then echo "  ✗ LEAK in $LEAK"; else echo "  ✓ no home-path leak"; fi
  echo "  entitlements (sandbox+bluetooth markers): $ENT"
  if lipo -info "$MACAPP/Contents/MacOS/NOOP" 2>/dev/null | grep -q 'x86_64 arm64\|arm64 x86_64'; then
    ditto -c -k --sequesterRsrc --keepParent "$MACAPP" "$DIST/NOOP-v$VER-macos.zip" && ok_mac=1
    echo "  ✓ dist/NOOP-v$VER-macos.zip ($(( $(stat -f '%z' "$DIST/NOOP-v$VER-macos.zip")/1024/1024 ))MB)"
  else echo "  ✗ NOT universal — refusing to package"; fi
else echo "  ✗ macOS build FAILED"; grep -E 'error:' /tmp/v7a-mac.log | sed 's#.*Strand/##' | sort -u | head; fi

# ── iOS unsigned (for AltStore/SideStore) ──────────────────────────────────────
echo "═══ iOS (unsigned Release) ═══"
rm -rf build/ios-dd
# Destination-driven (NOT -sdk iphoneos): the iOS app now embeds the watchOS app at
# NOOP.app/Watch/NOOPWatch.app, and forcing the iOS SDK on the whole scheme would compile the
# watch targets against iOS (where watch-only widget families like .accessoryCorner do not exist).
# The destination lets each target build for its own platform; output still lands in Release-iphoneos.
xcodebuild -scheme NOOPiOS -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath build/ios-dd CODE_SIGNING_ALLOWED=NO build >/tmp/v7a-ios.log 2>&1
IOSAPP="$(find build/ios-dd/Build/Products/Release-iphoneos -maxdepth 1 -name '*.app' -type d | head -1)"
if [ -d "$IOSAPP" ]; then
  echo "  built."
  Tools/anonymize-ios-app.sh "$IOSAPP" 2>&1 | sed 's/^/  /'
  LEAK=$(grep -rl "$HOMEPATH" "$IOSAPP/" 2>/dev/null | head -1)
  if [ -n "$LEAK" ]; then echo "  ✗ LEAK in $LEAK"; else echo "  ✓ no home-path leak"; fi
  LITE_IPA="$DIST/NOOP-ios-unsigned-v$VER.ipa"
  FULL_IPA="$DIST/NOOP-ios-full-unsigned-v$VER.ipa"
  Tools/package-ios-ipas.sh "$IOSAPP" "$LITE_IPA" "$FULL_IPA"
  [ -f "$LITE_IPA" ] && [ -f "$FULL_IPA" ] && ok_ios=1
else echo "  ✗ iOS build FAILED"; grep -E 'error:' /tmp/v7a-ios.log | sed 's#.*Strand/##' | sort -u | head; fi

# ── Android full release ───────────────────────────────────────────────────────
echo "═══ Android (assembleFullRelease) ═══"
export JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home
( cd android && ./gradlew assembleFullRelease ) >/tmp/v7a-android.log 2>&1
APK="android/app/build/outputs/apk/full/release/app-full-release.apk"
if [ -f "$APK" ]; then
  cp "$APK" "$DIST/NOOP-v$VER.apk" && ok_apk=1
  echo "  ✓ dist/NOOP-v$VER.apk ($(( $(stat -f '%z' "$DIST/NOOP-v$VER.apk")/1024/1024 ))MB)"
else echo "  ✗ Android build FAILED"; grep -iE 'error|FAILURE|what went wrong' /tmp/v7a-android.log | head; fi

echo ""
echo "═══ ARTIFACT SUMMARY ═══  mac=$ok_mac ios=$ok_ios apk=$ok_apk"
ls -la "$DIST"/*v$VER* 2>/dev/null
echo "═══ V7 ARTIFACTS DONE ═══"
