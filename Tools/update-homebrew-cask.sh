#!/usr/bin/env bash
#
# update-homebrew-cask.sh <version> [zip] — refresh the Homebrew cask after a macOS release.
# The cask download URL points at the GitHub release asset; the tap repo lives on GitHub
# (github.com/NoopApp/homebrew-noop, Homebrew's default tap host) and is also mirrored to the
# forge (noop.fans/NoopApp/homebrew-noop). This script pushes the updated cask to BOTH.
#
# Users install/update with:
#     brew tap noopapp/noop
#     brew install --cask noop   /   brew upgrade --cask noop
#
# Anonymity-safe: commits as NoopApp; tokens read from ~/.config/noop/ and supplied
# via a transient git credential helper — never on a command line, URL, or in output.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
[ -f "$HERE/../deploy.env" ] && source "$HERE/../deploy.env"
DOMAIN="${FORGE_DOMAIN:-${NOOP_DOMAIN:-noop.fans}}"
ORG="${FORGE_ORG:-NoopApp}"; REPO="${FORGE_REPO:-noop}"

VER="${1:?usage: $0 <version e.g. 4.7.0> [zip path]}"
ZIP="${2:-$HOME/Downloads/NOOP-v${VER}-macos.zip}"
GH_TOKEN_FILE="$HOME/.config/noop/gh_token"        # canonical tap host (github.com)
FORGE_TOKEN_FILE="$HOME/.config/noop/forge_token"  # mirror tap host (forge)
[ -f "$ZIP" ]             || { echo "missing release zip: $ZIP" >&2; exit 1; }
[ -f "$GH_TOKEN_FILE" ]   || { echo "missing GitHub token: $GH_TOKEN_FILE" >&2; exit 1; }

export GH_TOKEN; GH_TOKEN="$(cat "$GH_TOKEN_FILE")"
# Forge token is optional — the mirror push is best-effort, not a release blocker.
export FORGE_TOKEN; FORGE_TOKEN="$([ -f "$FORGE_TOKEN_FILE" ] && cat "$FORGE_TOKEN_FILE" || true)"
SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
GH_TAP_URL="https://github.com/$ORG/homebrew-noop.git"   # canonical
FORGE_TAP_URL="https://$DOMAIN/$ORG/homebrew-noop.git"    # mirror

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# Clone from the canonical GitHub tap; fall back to the forge mirror, then a fresh repo.
git clone --quiet "$GH_TAP_URL" "$TMP/tap" 2>/dev/null \
  || git clone --quiet "$FORGE_TAP_URL" "$TMP/tap" 2>/dev/null \
  || { mkdir -p "$TMP/tap"; git -C "$TMP/tap" init -q; }

mkdir -p "$TMP/tap/Casks"
cat > "$TMP/tap/Casks/noop.rb" <<EOF
cask "noop" do
  version "${VER}"
  sha256 "${SHA}"

  url "https://github.com/${ORG}/${REPO}/releases/download/v#{version}/NOOP-v#{version}-macos.zip"
  name "NOOP"
  desc "Standalone, fully offline companion app for WHOOP straps"
  homepage "https://github.com/${ORG}/${REPO}"

  app "NOOP.app"

  caveats "NOOP ships anonymously and is unsigned (no Apple Developer ID), so on first launch macOS Gatekeeper will block it. On macOS 15 Sequoia and later: try to open NOOP once, then go to System Settings > Privacy & Security, scroll down, and click 'Open Anyway' next to NOOP. (On macOS 14 and earlier you can right-click NOOP in /Applications and choose Open.) Update later with: brew upgrade --cask noop."
end
EOF

cd "$TMP/tap"
git -c user.name=NoopApp -c user.email=thenoopapp@gmail.com add Casks/noop.rb
if git rev-parse HEAD >/dev/null 2>&1 && git diff --cached --quiet; then
  echo "Homebrew cask already current for ${VER} — nothing to push."; exit 0
fi
git -c user.name=NoopApp -c user.email=thenoopapp@gmail.com commit --quiet -m "noop ${VER}"

# Push to the canonical GitHub tap (required) and the forge mirror (best-effort).
git -c credential.helper='!f() { echo username=NoopApp; echo "password=$GH_TOKEN"; }; f' \
    push --quiet "$GH_TAP_URL" HEAD:main
echo "✓ Homebrew cask updated to ${VER} on GitHub (sha256 ${SHA:0:12}…)"

if [ -n "$FORGE_TOKEN" ]; then
  if git -c credential.helper='!f() { echo username=NoopApp; echo "password=$FORGE_TOKEN"; }; f' \
       push --quiet "$FORGE_TAP_URL" HEAD:main; then
    echo "✓ Mirrored cask to forge ($DOMAIN)."
  else
    echo "⚠ Mirror push to forge ($DOMAIN) failed — GitHub tap is current; mirror is stale." >&2
  fi
else
  echo "⚠ No forge token — skipped mirror push to $DOMAIN." >&2
fi
