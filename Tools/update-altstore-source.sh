#!/usr/bin/env bash
#
# update-altstore-source.sh — write a released iOS build into altstore-source.json.
#
# THE ONE IMPLEMENTATION. The same rule used to live in three places: an inline `jq` block in
# publish-ios-release.yml, a second one in fork-release.yml, and this script — and they had already
# drifted. fork-release.yml looked for an asset named `NOOP-ios-unsigned-v<V>.ipa` while releases are
# published as `NOOP-ios-unsigned-v<V>-dx.ipa`, so its update step would find nothing, warn, and skip
# SILENTLY, leaving every sideloader on the previous version. Both workflows now call this script, so
# the naming rule is stated once.
#
# The downloadURL is DERIVED, never typed: repo DX23876/noop, tag v<VERSION>-dx, file
# NOOP-ios-unsigned-v<VERSION>-dx.ipa. Get any of the three wrong and the published source offers a
# download that 404s for everyone. The `-dx` marker lives in the tag and the filename only — the
# version Apple reads stays numeric (docs/FORK_GUIDE.md).
#
# It offers the SIDELOAD IPA (app + widgets, no Watch app) on purpose: the Full IPA needs a team that
# can provision an embedded watchOS bundle, which is exactly what a free-Apple-ID sideloader cannot do,
# and a failure there costs the whole install (docs/IOS.md).
#
# Usage:
#   Tools/update-altstore-source.sh --version 10.1.0 --ipa dist/NOOP-ios-unsigned-v10.1.0-dx.ipa
#   Tools/update-altstore-source.sh --version 10.1.0 --build 219 --size 361862652
#
#   --version X.Y.Z   required, numeric — the version the app reports.
#   --ipa PATH        read build number and byte size from the IPA (local, hand-cut release).
#   --build N         CFBundleVersion, when no IPA is at hand (CI reads it from project.yml).
#   --size BYTES      the asset's byte size, when no IPA is at hand (CI reads it off the release).
#   --desc TEXT       localizedDescription; defaults to a pointer at the release notes.
#   --repo owner/name defaults to DX23876/noop (or $GH_REPO).
#
# Editing the file is all it does — committing and pushing is the caller's job, so a CI run and a
# local run leave the same artifact behind.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"

GH_REPO="${GH_REPO:-DX23876/noop}"
VERSION=""
IPA=""
BUILD=""
SIZE=""
DESC=""

usage() {
    sed -n '22,32p' "$0" >&2
    exit 2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --version) VERSION="${2:?--version needs a value}"; shift 2 ;;
        --ipa)     IPA="${2:?--ipa needs a value}"; shift 2 ;;
        --build)   BUILD="${2:?--build needs a value}"; shift 2 ;;
        --size)    SIZE="${2:?--size needs a value}"; shift 2 ;;
        --desc)    DESC="${2:?--desc needs a value}"; shift 2 ;;
        --repo)    GH_REPO="${2:?--repo needs a value}"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "✗ unknown argument: $1" >&2; usage ;;
    esac
done

[ -n "$VERSION" ] || { echo "✗ --version is required" >&2; usage; }
# Numeric only: CFBundleShortVersionString must be numeric or Apple rejects it, and the manifest
# mirrors what the app reports. A caller passing the TAG (v10.1.0-dx) instead of the version is the
# mistake this catches — it would publish a version string no installed app can compare against.
case "$VERSION" in
    [0-9]*.[0-9]*.[0-9]*) : ;;
    *) echo "✗ --version must be numeric X.Y.Z (got '$VERSION') — the -dx marker is added here" >&2; exit 1 ;;
esac

# altstore-source.json lives at the repo root — this checkout's, not a path that happens to exist on
# one machine. The file being edited must be the one that gets committed and served.
SRC="${ALTSTORE_SRC:-$REPO_ROOT/altstore-source.json}"
[ -f "$SRC" ] || { echo "✗ $SRC not found (set ALTSTORE_SRC)" >&2; exit 1; }
command -v jq >/dev/null || { echo "✗ jq is required" >&2; exit 1; }

if [ -n "$IPA" ]; then
    [ -f "$IPA" ] || { echo "✗ IPA not found: $IPA" >&2; exit 1; }
    TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
    unzip -qq "$IPA" -d "$TMP"
    PLIST="$(find "$TMP/Payload" -maxdepth 2 -name Info.plist | head -1)"
    [ -n "$PLIST" ] || { echo "✗ no Payload/*.app/Info.plist in IPA" >&2; exit 1; }
    BUILD="${BUILD:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")}"
    SHORT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
    [ "$SHORT" = "$VERSION" ] || echo "⚠ IPA reports $SHORT but --version says $VERSION (using $VERSION)" >&2
    # BSD stat (macOS) and GNU stat (Linux) disagree on the flag; try both rather than assuming the OS.
    SIZE="${SIZE:-$(stat -f%z "$IPA" 2>/dev/null || stat -c%s "$IPA")}"
fi

[ -n "$BUILD" ] || { echo "✗ need --build (or --ipa to read it from the bundle)" >&2; exit 1; }
[ -n "$SIZE" ] || { echo "✗ need --size (or --ipa to measure it)" >&2; exit 1; }
# A zero or non-numeric size is how a silent failure upstream of here arrives: `gh release view` on a
# missing asset yields an empty string. Publishing it would leave sideloaders with a 0-byte download.
case "$SIZE" in
    ''|*[!0-9]*) echo "✗ --size must be a byte count (got '$SIZE')" >&2; exit 1 ;;
    0) echo "✗ --size is 0 — the release asset was not found" >&2; exit 1 ;;
esac

DESC="${DESC:-"NOOP AI $VERSION. See the release notes for what changed."}"
DATE="$(date -u +%Y-%m-%d)"
TAG="v${VERSION}-dx"
ASSET="NOOP-ios-unsigned-v${VERSION}-dx.ipa"
URL="https://github.com/${GH_REPO}/releases/download/${TAG}/${ASSET}"
# Keep whatever minimum the manifest already declares; it tracks the iOS deployment target in
# project.yml and is not a per-release decision.
MIN_OS="$(jq -r '.apps[0].minOSVersion // "17.0"' "$SRC")"

echo "→ $VERSION (build $BUILD), ${SIZE} bytes, $DATE"
echo "  $URL"

# Prepend to versions[] — dropping any existing entry for this version, so a re-run is idempotent —
# AND mirror into the app-level legacy fields. Both shapes matter: newer sideloaders read versions[0],
# older ones only the top-level fields, and updating one without the other strands half the clients.
tmp="$(mktemp)"
jq --arg v "$VERSION" --arg b "$BUILD" --arg d "$DATE" --arg desc "$DESC" \
   --arg url "$URL" --argjson size "$SIZE" --arg min "$MIN_OS" '
  {version: $v, buildVersion: $b, date: $d, localizedDescription: $desc,
   downloadURL: $url, size: $size, minOSVersion: $min} as $entry
  | .apps[0].versions           = ([$entry] + (.apps[0].versions | map(select(.version != $v))))
  | .apps[0].version            = $v
  | .apps[0].buildVersion       = $b
  | .apps[0].versionDate        = $d
  | .apps[0].versionDescription = $desc
  | .apps[0].downloadURL        = $url
  | .apps[0].size               = $size
  | .apps[0].minOSVersion       = $min
' "$SRC" > "$tmp" && mv "$tmp" "$SRC"

jq empty "$SRC" && echo "✓ altstore-source.json updated for $VERSION"
