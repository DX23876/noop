#!/usr/bin/env bash
# local-tests.sh — run the checks no CI runs on a push, and record that they passed for this tree.
#
# `app-build.yml` runs only before a release and `swift-packages.yml` only before a release or on
# dispatch (decisions 2026-09-30 and 2026-10-10: macOS runner cost, and GitHub paused the fork's Actions
# on 2026-10-08). Between releases the StrandTests and the package tests ran only when someone
# remembered to. This script runs what a push to main changes, and `.githooks/pre-push` refuses such a
# push unless this script passed on exactly the tree being pushed.
#
#   Tools/local-tests.sh            # against origin/main
#   Tools/local-tests.sh <base>     # against another base, e.g. HEAD~3
#
# What runs, by changed path since <base>:
#   app code (Strand*/, NOOPWatch*/, project.yml)   macOS `Strand` StrandTests + iOS `NOOPiOS` build
#   Packages/<Name>/                                 `swift test` in that package
#   android/ and what its build reads                Gradle debug builds of both flavours + unit tests
# Packages are compiled into the app too, so a package change also runs the app leg. The Android inputs
# outside android/ are the ones `.github/workflows/android.yml` lists: project.yml, the shared protocol
# and schema fixtures and Tools/parity_cases.
#
# The stamp is the tree hash of HEAD, so the working tree must be clean: a passing run over uncommitted
# edits says nothing about the commit being pushed. Stamps live in the shared git dir, one per line.
set -euo pipefail

BASE="${1:-origin/main}"
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  echo "local-tests: the working tree has uncommitted changes; commit first so the stamp means something." >&2
  exit 1
fi

TREE="$(git rev-parse 'HEAD^{tree}')"
CHANGED="$(git diff --name-only "$BASE" HEAD)"

APP=0
ANDROID=0
PACKAGES=()
while IFS= read -r path; do
  [ -n "$path" ] || continue
  case "$path" in
    android/*|.github/workflows/android.yml|project.yml|Tools/parity_cases/*|\
    Packages/WhoopProtocol/Sources/WhoopProtocol/Resources/*|Packages/WhoopProtocol/Tests/WhoopProtocolTests/Resources/*|\
    Packages/WhoopStore/Tests/WhoopStoreTests/Resources/*)
      ANDROID=1 ;;
  esac
  case "$path" in
    Strand/*|StrandTests/*|StrandiOS/*|StrandiOSShared/*|StrandiOSWidgets/*|StrandiOSTests/*|NOOPWatch*/*|project.yml)
      APP=1 ;;
    Packages/*/*)
      APP=1
      name="$(printf '%s' "$path" | cut -d/ -f2)"
      case " ${PACKAGES[*]-} " in *" $name "*) ;; *) PACKAGES+=("$name") ;; esac ;;
  esac
done <<< "$CHANGED"

if [ "$APP" = 0 ] && [ "$ANDROID" = 0 ] && [ "${#PACKAGES[@]}" = 0 ]; then
  echo "local-tests: nothing app-, package- or Android-side changed since $BASE; no stamp needed."
  exit 0
fi

DERIVED="${NOOP_LOCAL_TESTS_DERIVED:-$ROOT/build/local-tests}"
RAN=()

for name in "${PACKAGES[@]-}"; do
  [ -n "$name" ] || continue
  if [ ! -f "Packages/$name/Package.swift" ]; then
    echo "local-tests: Packages/$name has no Package.swift (deleted?), skipped."
    continue
  fi
  echo "local-tests: swift test in Packages/$name"
  (cd "Packages/$name" && swift test)
  RAN+=("pkg:$name")
done

if [ "$APP" = 1 ]; then
  echo "local-tests: xcodegen generate"
  xcodegen generate >/dev/null
  echo "local-tests: macOS Strand + StrandTests"
  xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED/mac" CODE_SIGNING_ALLOWED=NO test -quiet
  echo "local-tests: iOS NOOPiOS build"
  IOS_LOG="$DERIVED/ios-build.log"
  xcodebuild -project Strand.xcodeproj -scheme NOOPiOS -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$DERIVED/ios" ARCHS=arm64 CODE_SIGNING_ALLOWED=NO build -quiet 2>&1 | tee "$IOS_LOG"
  # The app ships to iOS 17, but Swift only warns about a newer-OS conformance (EnumeratedSequence as a
  # collection, TupleContent as a View): that compiles and then crashes on iOS 17/18 (Settings, 12.0.1).
  # An incremental build re-reports only recompiled files, so this sees new sites, not old ones.
  if grep -E "warning: .*(is only available in iOS|does not implement 'buildLimitedAvailability')" "$IOS_LOG" >&2; then
    echo "local-tests: the iOS build uses an API newer than the iOS 17 deployment target (above); gate or replace it." >&2
    exit 1
  fi
  RAN+=("app")
fi

if [ "$ANDROID" = 1 ]; then
  echo "local-tests: Android full and demo debug builds + unit tests"
  export JAVA_HOME="${JAVA_HOME:-$(/usr/libexec/java_home -v 17)}"
  export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
  (cd android && ./gradlew --quiet assembleFullDebug assembleDemoDebug testFullDebugUnitTest)
  RAN+=("android")
fi

# Builds rewrite the String Catalogs; a stamp over a tree the build itself changed would be a lie.
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  echo "local-tests: the build changed tracked files (String Catalogs?); restore them and run again:" >&2
  git status --short --untracked-files=no >&2
  exit 1
fi

STAMPS="$(git rev-parse --git-common-dir)/noop-local-tests"
printf '%s %s %s\n' "$TREE" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${RAN[*]}" >> "$STAMPS"
echo "local-tests: passed (${RAN[*]}); stamped tree ${TREE:0:9}."
