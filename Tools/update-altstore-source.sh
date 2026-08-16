#!/usr/bin/env bash
#
# update-altstore-source.sh <version> <ipa> [desc] — refresh altstore-source.json with a new iOS release.
#
# NOT the normal path. `.github/workflows/fork-release.yml` updates altstore-source.json and pushes it
# to main on every release; this script is the manual fallback for a release cut by hand. It writes the
# same shape: reads CFBundleVersion + size from the IPA, prepends/replaces apps[0].versions[0], and
# mirrors the legacy top-level fields.
#
# The downloadURL points at this fork's GitHub release asset — repo DX23876/noop, tag v<VERSION>-dx,
# file NOOP-ios-unsigned-v<VERSION>-dx.ipa. Getting any of the three wrong publishes a source whose
# every install 404s, so they are derived here rather than typed: the fork's `-dx` marker lives in the
# tag and the filename, never in the numeric version Apple reads.
#
# Run LOCALLY right after the .ipa is built, then commit altstore-source.json + push it (the file is
# served from the repo at raw.githubusercontent.com/DX23876/noop/main/altstore-source.json, which is
# the source URL sideloaders subscribe to).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
GH_REPO="${GH_REPO:-DX23876/noop}"

VERSION="${1:?usage: $0 <version> <ipa> [desc]}"
IPA="${2:?usage: $0 <version> <ipa> [desc]}"
DESC="${3:-"NOOP $VERSION. See the release notes for what changed."}"

# altstore-source.json lives at the repo root — this checkout's, not a path that happens to exist on
# one machine. The file being edited must be the one that gets committed and served.
SRC="${ALTSTORE_SRC:-$REPO_ROOT/altstore-source.json}"
MIN_OS="17.0"

[ -f "$SRC" ] || { echo "✗ $SRC not found (set ALTSTORE_SRC)" >&2; exit 1; }
[ -f "$IPA" ] || { echo "✗ IPA not found: $IPA" >&2; exit 1; }
command -v jq >/dev/null || { echo "✗ jq is required" >&2; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
unzip -qq "$IPA" -d "$TMP"
PLIST="$(find "$TMP/Payload" -maxdepth 2 -name Info.plist | head -1)"
[ -n "$PLIST" ] || { echo "✗ no Payload/*.app/Info.plist in IPA" >&2; exit 1; }
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
SHORT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
[ "$SHORT" = "$VERSION" ] || echo "⚠ IPA short version=$SHORT but you passed $VERSION (using $VERSION)" >&2

SIZE="$(stat -f%z "$IPA")"
DATE="$(date -u +%Y-%m-%d)"
# The sideload IPA — app + widgets, no Watch app — is what the source must offer: the Full IPA needs a
# team that can provision an embedded watchOS bundle, which is exactly what a free-Apple-ID sideloader
# cannot do (docs/IOS.md). Tag and filename both carry `-dx`; the version inside the JSON stays numeric.
URL="https://github.com/${GH_REPO}/releases/download/v${VERSION}-dx/NOOP-ios-unsigned-v${VERSION}-dx.ipa"

echo "→ $VERSION (build $BUILD), ${SIZE} bytes, $DATE"
jq --arg v "$VERSION" --arg b "$BUILD" --arg d "$DATE" --arg desc "$DESC" \
   --arg url "$URL" --argjson size "$SIZE" --arg min "$MIN_OS" '
  ( {version:$v, buildVersion:$b, date:$d, localizedDescription:$desc,
     downloadURL:$url, size:$size, minOSVersion:$min} ) as $entry
  | .apps[0].versions = ([ $entry ] + ( .apps[0].versions | map(select(.version != $v)) ))
  | .apps[0].version            = $v
  | .apps[0].buildVersion       = $b
  | .apps[0].versionDate        = $d
  | .apps[0].versionDescription = $desc
  | .apps[0].downloadURL        = $url
  | .apps[0].size               = $size
  | .apps[0].minOSVersion       = $min
' "$SRC" > "$SRC.tmp" && mv "$SRC.tmp" "$SRC"
jq empty "$SRC" && echo "✓ altstore-source.json updated for $VERSION"
