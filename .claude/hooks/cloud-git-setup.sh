#!/usr/bin/env bash
# Session start in a cloud agent session: commit as the fork's identity and turn on the repository's hooks.
#
# A cloud session clones the repository fresh, so it has neither the owner's git identity nor the hooks
# that refuse a foreign author or an AI trailer; without this it commits as "Claude <noreply@anthropic.com>"
# (three such commits reached origin/main on 2026-11-08). Local sessions are left alone: their clone
# already carries the identity and hooks, and this script must not overwrite them.
set -euo pipefail

[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || exit 0
cd "${CLAUDE_PROJECT_DIR:-.}"
git config user.name "DX23876"
git config user.email "176692557+DX23876@users.noreply.github.com"
git config core.hooksPath .githooks
echo "Git identity set to DX23876 and .githooks enabled for this cloud session."
