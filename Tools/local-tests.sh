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
# Packages are compiled into the app too, so a package change also runs the app leg.
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
PACKAGES=()
while IFS= read -r path; do
  [ -n "$path" ] || continue
  case "$path" in
    Strand/*|StrandTests/*|StrandiOS/*|StrandiOSShared/*|StrandiOSWidgets/*|StrandiOSTests/*|NOOPWatch*/*|project.yml)
      APP=1 ;;
    Packages/*/*)
      APP=1
      name="$(printf '%s' "$path" | cut -d/ -f2)"
      case " ${PACKAGES[*]-} " in *" $name "*) ;; *) PACKAGES+=("$name") ;; esac ;;
  esac
done <<< "$CHANGED"

if [ "$APP" = 0 ] && [ "${#PACKAGES[@]}" = 0 ]; then
  echo "local-tests: nothing app- or package-side changed since $BASE; no stamp needed."
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
  xcodebuild -project Strand.xcodeproj -scheme NOOPiOS -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$DERIVED/ios" ARCHS=arm64 CODE_SIGNING_ALLOWED=NO build -quiet
  RAN+=("app")
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
