#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# release.sh — cut a NOOP release on BOTH forges.
# Run from your Mac at release time, after the anonymized binaries are built.
#
#   Tools/release.sh <version> <asset> [<asset> ...] [-- "release notes"]
#   e.g. Tools/release.sh 4.7.0 \
#          dist/NOOP-v4.7.0-macos.zip dist/NOOP-v4.7.0.ipa dist/NOOP-v4.7.0.apk \
#          -- "Bug fixes and the new Lab Book."
#
# GitHub is CANONICAL — the release is created there FIRST (NoopApp/noop, marked
# --latest). The self-hosted Forgejo is published SECOND as a mirror by handing
# the same args straight to forgejo-release.sh. A Forgejo failure is tolerated:
# it warns but does NOT abort or fail the run, because the GitHub release already
# succeeded.
#
# Same args as forgejo-release.sh: <version> <asset...> [-- notes].
# Idempotent: re-running clobbers the release's assets (and edits the title/notes)
# rather than erroring on an existing tag.
#
# GitHub token from ~/.config/noop/gh_token. Forge token handled by forgejo-release.sh.
# No secret ever appears on a command line.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

# canonical GitHub mirror coordinates (override via env if ever needed)
GH_REPO="${GH_REPO:-NoopApp/noop}"

VER="${1:?usage: release.sh <version> <asset...> [-- notes]}"; shift
TAG="v$VER"
NOTES="NOOP $TAG — see CHANGELOG.md."
ASSETS=()
# split args into assets + optional "-- notes", preserving the original arg list
# so the SAME list can be replayed verbatim to forgejo-release.sh below.
ORIG_ARGS=("$@")
while [ $# -gt 0 ]; do
  if [ "$1" = "--" ]; then shift; NOTES="${1:-$NOTES}"; break; fi
  ASSETS+=("$1"); shift
done

# ── 1. GitHub (canonical) ────────────────────────────────────────────────────
GH_TOKEN_FILE="$HOME/.config/noop/gh_token"
[ -f "$GH_TOKEN_FILE" ] || { echo "missing $GH_TOKEN_FILE" >&2; exit 1; }
command -v gh >/dev/null 2>&1 || { echo "gh CLI not found on PATH" >&2; exit 1; }

# collect the assets that actually exist on disk (warn, don't die, on a miss).
# ${ARR[@]+"${ARR[@]}"} guards against the empty-array "unbound variable" trap
# in macOS's stock bash 3.2 under `set -u`.
GH_ASSETS=()
for f in ${ASSETS[@]+"${ASSETS[@]}"}; do
  if [ -f "$f" ]; then GH_ASSETS+=("$f"); else echo "  ⚠ missing asset: $f" >&2; fi
done

echo "→ release $TAG on GitHub $GH_REPO (canonical)"
GH_OK=1
if GH_TOKEN="$(cat "$GH_TOKEN_FILE")" \
   gh release view "$TAG" --repo "$GH_REPO" >/dev/null 2>&1; then
  # idempotent: release already exists → refresh notes + clobber assets
  echo "  release exists — refreshing notes + clobbering assets"
  GH_TOKEN="$(cat "$GH_TOKEN_FILE")" \
    gh release edit "$TAG" --repo "$GH_REPO" \
      --title "NOOP $TAG" --notes "$NOTES" --latest >/dev/null \
    || { echo "  ⚠ gh release edit failed" >&2; GH_OK=0; }
  if [ "${#GH_ASSETS[@]}" -gt 0 ]; then
    GH_TOKEN="$(cat "$GH_TOKEN_FILE")" \
      gh release upload "$TAG" "${GH_ASSETS[@]}" --repo "$GH_REPO" --clobber \
      || { echo "  ⚠ gh release upload failed" >&2; GH_OK=0; }
  fi
else
  GH_TOKEN="$(cat "$GH_TOKEN_FILE")" \
    gh release create "$TAG" ${GH_ASSETS[@]+"${GH_ASSETS[@]}"} --repo "$GH_REPO" \
      --title "NOOP $TAG" --notes "$NOTES" --latest \
    || { echo "  ⚠ gh release create failed" >&2; GH_OK=0; }
fi
[ "$GH_OK" = 1 ] \
  && echo "✓ $TAG on GitHub: https://github.com/$GH_REPO/releases/tag/$TAG" \
  || echo "✗ GitHub release for $TAG had errors (see above)" >&2

# ── 2. Forgejo mirror (best-effort; never aborts) ────────────────────────────
echo "→ mirroring $TAG to Forgejo"
if [ -x "$HERE/forgejo-release.sh" ]; then
  if "$HERE/forgejo-release.sh" "$VER" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}; then
    :  # forgejo-release.sh prints its own success line
  else
    echo "  ⚠ Forgejo mirror failed (non-fatal — GitHub is canonical)" >&2
  fi
else
  echo "  ⚠ $HERE/forgejo-release.sh not found/executable — skipping mirror" >&2
fi

# exit reflects the canonical (GitHub) outcome only
[ "$GH_OK" = 1 ]
