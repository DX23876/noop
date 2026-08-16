#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# forgejo-release.sh — cut a release on the self-hosted forge (replaces `gh release create`).
# Run from your Mac at release time, after the anonymized binaries are built.
#
# ⚠ UPSTREAM INFRASTRUCTURE. The forge it publishes to (noop.fans/NoopApp) belongs to upstream, and
# this fork has neither the host nor the token for it. Reachable only through Tools/release.sh, which
# is itself gated off here. Kept unmodified so an upstream sync has nothing to conflict over.
#
#   release/forgejo-release.sh <version> <asset> [<asset> ...] [-- "release notes"]
#   e.g. release/forgejo-release.sh 4.7.0 \
#          dist/NOOP-v4.7.0-macos.zip dist/NOOP-v4.7.0-ios.ipa dist/NOOP-v4.7.0-android.apk
#
# Creates tag v<version> (server-side, from the current default branch) + the release,
# then uploads every asset. Token from ~/.config/noop/forge_token. Idempotent on assets.
# FORGE_DOMAIN/FORGE_ORG/FORGE_REPO come from deploy.env (or env). No secret on any cmdline.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

# load config: prefer a sibling deploy.env, else expect FORGE_* in the environment
HERE="$(cd "$(dirname "$0")" && pwd)"
[ -f "$HERE/../deploy.env" ] && source "$HERE/../deploy.env"
DOMAIN="${FORGE_DOMAIN:-${NOOP_DOMAIN:-noop.fans}}"
ORG="${FORGE_ORG:-NoopApp}"; REPO="${FORGE_REPO:-noop}"

VER="${1:?usage: forgejo-release.sh <version> <asset...> [-- notes]}"; shift
TAG="v$VER"; NOTES="NOOP $TAG — see CHANGELOG.md."
ASSETS=()
while [ $# -gt 0 ]; do
  if [ "$1" = "--" ]; then shift; NOTES="${1:-$NOTES}"; break; fi
  ASSETS+=("$1"); shift
done

TOKEN_FILE="$HOME/.config/noop/forge_token"
[ -f "$TOKEN_FILE" ] || { echo "missing $TOKEN_FILE" >&2; exit 1; }
TOKEN="$(cat "$TOKEN_FILE")"
API="https://$DOMAIN/api/v1"
api(){ curl -fsS -H "Authorization: token $TOKEN" -H 'Content-Type: application/json' "$@"; }

echo "→ release $TAG on $ORG/$REPO ($DOMAIN)"
REL_ID="$(api "$API/repos/$ORG/$REPO/releases/tags/$TAG" 2>/dev/null | jq -r '.id // empty')"
if [ -z "$REL_ID" ]; then
  REL_ID="$(api -X POST "$API/repos/$ORG/$REPO/releases" \
    -d "$(jq -n --arg t "$TAG" --arg n "NOOP $TAG" --arg b "$NOTES" \
          '{tag_name:$t,name:$n,body:$b,draft:false,prerelease:false}')" | jq -r '.id')"
  echo "  created release id=$REL_ID"
else
  echo "  release exists id=$REL_ID — adding/refreshing assets"
fi

for f in "${ASSETS[@]}"; do
  [ -f "$f" ] || { echo "  ⚠ missing asset: $f" >&2; continue; }
  name="$(basename "$f")"
  existing="$(api "$API/repos/$ORG/$REPO/releases/$REL_ID/assets" | jq -r --arg n "$name" '.[]|select(.name==$n).id')"
  [ -n "$existing" ] && api -X DELETE "$API/repos/$ORG/$REPO/releases/$REL_ID/assets/$existing" >/dev/null
  curl -fsS -H "Authorization: token $TOKEN" \
       -F "attachment=@$f;type=application/octet-stream" \
       "$API/repos/$ORG/$REPO/releases/$REL_ID/assets?name=$name" >/dev/null
  echo "  ↑ $name"
done
echo "✓ $TAG published: https://$DOMAIN/$ORG/$REPO/releases/tag/$TAG"
