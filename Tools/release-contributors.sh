#!/usr/bin/env bash
# release-contributors.sh — collect THIRD-PARTY contributor handles for a release's credit line (#736).
#
# Release notes used to credit people by display name ("FF", "Pipiche"), which GitHub cannot resolve: the
# contributor is thanked visibly but never notified, and the credit links nowhere. Getting the handles right
# by hand means cross-referencing every merged PR and closed issue in the range, which is exactly the sort
# of chore that silently drifts. This does the mechanical half.
#
# It prints each third-party @handle with the PRs they landed and the issues they reported, so the release
# author only has to write WHAT each person contributed — the judgement part — instead of hunting logins.
#
# The maintainer's own handles are excluded on purpose: self-credit is noise, and a self-mention notifies
# nobody. Override with MAINTAINERS="a,b" if the set ever changes.
#
# Usage:
#   Tools/release-contributors.sh 2026-07-20              # since a date (inclusive, whole day)
#   Tools/release-contributors.sh v9.0.2                  # since that tag's exact commit time
#   MAINTAINERS="ryanbr,Fanboynz" Tools/release-contributors.sh 2026-07-20
#
# Requires: gh, authenticated. A dead or unauthenticated gh is a hard error, never an empty list —
# for a tool whose whole job is "nobody is missed", silently missing EVERYBODY is the worst failure mode.
set -euo pipefail

SINCE_INPUT="${1:-}"
if [ -z "$SINCE_INPUT" ]; then
  echo "usage: $(basename "$0") <since-date|since-tag>" >&2
  exit 2
fi

command -v gh >/dev/null 2>&1 || { echo "error: gh not found on PATH" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "error: gh is not authenticated (run: gh auth login)" >&2; exit 1; }

# A tag resolves to its exact commit TIME, not just its date. A date-only bound is inclusive of the whole
# day, so it re-credits everything merged earlier on release day — work that shipped in the PREVIOUS
# release. On v9.0.2 (tagged 06:15Z) that was 14 PRs. GitHub search honours an ISO8601 instant, so use one.
if git rev-parse -q --verify "refs/tags/$SINCE_INPUT" >/dev/null 2>&1; then
  # git does the UTC conversion, not `date -u -d`: that flag is GNU-only, and on the macOS where releases
  # are actually cut BSD date's -d means daylight-savings, so the tag path would die under `set -e`.
  SINCE="$(TZ=UTC git log -1 --format=%cd --date=format-local:%Y-%m-%dT%H:%M:%SZ "refs/tags/$SINCE_INPUT")"
  echo "# since tag $SINCE_INPUT ($SINCE)"
elif printf '%s' "$SINCE_INPUT" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}(T[0-9]{2}:[0-9]{2}:[0-9]{2}Z?)?$'; then
  SINCE="$SINCE_INPUT"
  echo "# since $SINCE"
else
  # Anything unrecognised must be rejected, not passed through as a date. Tags here are v-prefixed, so
  # "9.0.2" is the natural typo — and GitHub search swallows "merged:>=9.0.2" without complaint, returning
  # nothing. The author then reads "(none)" as "no third-party contributors" and ships notes crediting
  # nobody: the same silent miss the gh preflight exists to prevent, arriving through a different door.
  echo "error: '$SINCE_INPUT' is neither an existing tag nor a YYYY-MM-DD date." >&2
  case "$SINCE_INPUT" in
    [0-9]*.[0-9]*) echo "       tags in this repo are v-prefixed — did you mean v$SINCE_INPUT?" >&2 ;;
  esac
  echo "       recent tags:" >&2
  git tag --sort=-creatordate 2>/dev/null | head -5 | sed 's/^/         /' >&2
  exit 2
fi

MAINTAINERS="${MAINTAINERS:-ryanbr,Fanboynz}"
REPO="${GH_REPO:-ryanbr/noop}"
LIMIT=300

# Field-exact, case-insensitive. The rows are "handle<TAB>#N<TAB>title", so a whole-line anchor never
# matches and the maintainer leaks through; compare only field 1.
#
# Bot accounts are dropped in the same pass. This repo has none today, so it is precaution rather than a
# fix: nothing in the release flow would stop a merged Dependabot PR from putting "@dependabot[bot]" in a
# published credit line, and a bot is not someone to thank. GitHub suffixes every bot login with "[bot]".
drop_uncredited() {
  awk -F'\t' -v ex="$MAINTAINERS" '
    # Entries are trimmed: MAINTAINERS="digitalerdude, ryanbr" is how a human writes a two-name list, and
    # an untrimmed " ryanbr" matches nothing — putting the maintainer back in their own credit line.
    BEGIN { n = split(tolower(ex), m, ",")
            for (i = 1; i <= n; i++) gsub(/^[ \t]+|[ \t]+$/, "", m[i]) }
    { h = tolower($1); skip = 0
      for (i = 1; i <= n; i++) if (m[i] != "" && h == m[i]) skip = 1
      if (h ~ /\[bot\]$/) skip = 1
      if (!skip) print }'
}

# Titles are user-supplied and 3 of this repo's issues contain a newline or tab (e.g. #717). Left raw they
# split one record across several lines, and a continuation line has no handle in field 1 — so a
# MAINTAINER-authored issue leaks its title fragments into the third-party listing. Flatten first.
JQ_ROW='.[] | "\(.author.login)\t#\(.number)\t\(.title | gsub("[\r\n\t]+"; " "))"'

prs="$(gh pr list --repo "$REPO" --state merged --limit "$LIMIT" \
        --search "merged:>=$SINCE" --json number,author,title --jq "$JQ_ROW")"
# stateReason rides along as a 4th column so the truncation guard below can count what was FETCHED.
# Filtering inside the jq would hide truncation: 300 issues fetched of which 260 are completed leaves 260
# rows, under the limit, and the guard stays silent about the 300-item wall it just hit.
#
# Fetched over GRAPHQL, not `gh issue list --json stateReason`. That field is only exposed by newer gh
# builds: on gh 2.45 the whole command exits with "Unknown JSON field: stateReason" and prints the list of
# fields it does support, so the script produced NOTHING — no rows, no warning, no non-zero signal that
# anyone noticed until a release was being cut by hand. GraphQL has carried stateReason for far longer and
# its search connection excludes pull requests natively, so this also drops the PR-vs-issue ambiguity the
# REST endpoint has (REST /issues returns PRs too, with state_reason null).
# PAGINATED: the search connection refuses a `first` above 100, so the LIMIT is reached a page at a time
# rather than in one request. Without this the whole call errors out and, again, prints nothing useful.
GQL_ISSUES='query($q:String!,$endCursor:String){search(query:$q,type:ISSUE,first:100,after:$endCursor){
  nodes{... on Issue{number title stateReason author{login}}}
  pageInfo{hasNextPage endCursor}}}'
issues_raw="$(gh api graphql --paginate -f query="$GQL_ISSUES" \
        -f q="repo:$REPO is:issue is:closed closed:>=$SINCE" \
        --jq '.data.search.nodes[] | select(.author != null)
              | "\(.author.login)\t#\(.number)\t\(.title | gsub("[\r\n\t]+"; " "))\t\(.stateReason // "NULL")"' \
        | head -n "$LIMIT")"

# A silent top-N cap would read as "that is everyone" when it is not.
warn_if_truncated() {   # warn_if_truncated <what> <rows>
  if [ -n "$2" ] && [ "$(printf '%s\n' "$2" | wc -l)" -ge "$LIMIT" ]; then
    echo "# warning: hit the $LIMIT-item limit for $1 — the range may be truncated" >&2
  fi
}
warn_if_truncated "pull requests" "$prs"
warn_if_truncated "issues" "$issues_raw"

# Only COMPLETED issues. A report closed as not-planned or duplicate did not drive a fix, and crediting it
# is the same kind of noise the handle convention exists to remove. (Checked: this repo has no closed issue
# with a null reason, so nothing legitimately fixed is dropped by requiring the field.)
issues="$(printf '%s\n' "$issues_raw" | awk -F'\t' '$4 == "COMPLETED" { print $1 "\t" $2 "\t" $3 }')"

section() {   # section <heading> <rows>
  echo
  echo "$1"
  # Emptiness is judged AFTER filtering: rows that exist but are all the maintainer's still mean
  # "nothing to credit here", and a bare heading reads as a glitch rather than an answer.
  local kept; kept="$(printf '%s\n' "$2" | drop_uncredited | grep -v '^$' | sort -f || true)"
  if [ -z "$kept" ]; then echo "(none)"; else printf '%s\n' "$kept"; fi
}
section "## Merged PRs by third-party contributors"                       "$prs"
section "## Issues reported by third-party contributors (closed as completed)" "$issues"

echo
echo "## Credit line (add what each person contributed, then paste into the release notes)"
# Derived from the rows already fetched, so the line can never disagree with the listings above.
handles="$(printf '%s\n%s\n' "$prs" "$issues" | drop_uncredited | cut -f1 | grep -v '^$' | sort -uf || true)"
if [ -z "$handles" ]; then
  # Legitimate for a maintainer-only hotfix. Emitting a dangling "Thanks to" would be worse than saying so,
  # and exiting non-zero here (grep finding no match under pipefail) made the tool look broken.
  echo "(no third-party contributors in range — omit the credit section)"
else
  printf '%s\n' "$handles" \
    | awk 'BEGIN { ORS="" } { if (NR > 1) print ", "; print "@" $0 } END { print "\n" }' \
    | sed 's/^/Thanks to /'
fi
