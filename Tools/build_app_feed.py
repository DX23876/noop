#!/usr/bin/env python3
"""Build docs/app-feed.json: what the in-app Roadmap page shows about reported problems.

The app reads ONE static file instead of calling the GitHub API: no rate limit shared across everyone
behind a NAT, no third-party text arriving unfiltered, and a page that still renders when GitHub has
switched this fork's Actions off again (docs/fork/AGENT_RULES.md).

What crosses into the file, and nothing else: issue number, sanitised TITLE, state, dates, version. Never
an issue body, never a handle, never an avatar, never a URL out of someone's text. A bug report carries
logs, device details and sometimes a mail address; a title is the only part written to be read by others.

Determinism matters twice: a rerun must produce the same bytes (so a `git diff` means a real change), and
a run by hand must match the workflow's (so the page survives a dead Actions runner). Therefore the file
is only rewritten when something other than `generated` changed.

Usage:
    gh issue list -R DX23876/noop --state all --limit 300 \
        --json number,title,labels,state,stateReason,createdAt,closedAt > issues.json
    python3 Tools/build_app_feed.py --issues-file issues.json
"""
from __future__ import annotations

import argparse
import json
import re
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "docs" / "app-feed.json"

HIDE_LABEL = "hide-in-app"
RELEASE_LABEL = "public"
SUGGESTION_STATUS = {"planned": "planned", "maybe": "maybe", "wontfix": "notPlanned",
                     "not-planned": "notPlanned", "done": "done"}
ROADMAP_LABEL = "roadmap:"
MAX_SUGGESTION_DETAIL = 600
MAX_REPLY = 400
BUG_LABEL = "bug"
WORKING_LABEL = "in-progress"
FIXED_IN_RE = re.compile(r"^fixed-in:(\d+\.\d+(?:\.\d+)?)$")

MAX_TITLE = 120
MAX_ITEMS = 60
RECENT_FIXED = 5
DECIDED_DAYS = 30

CONTROL_RE = re.compile(r"[\x00-\x1f\x7f]")
LINK_RE = re.compile(r"\[([^\]]*)\]\([^)]*\)")
URL_RE = re.compile(r"(?:https?://|www\.)\S*")
SPACE_RE = re.compile(r"\s+")


def sanitise(title: str) -> str:
    """A title the screen can render as plain text: no markup, no links, one line, bounded."""
    text = LINK_RE.sub(r"\1", title or "")
    text = URL_RE.sub("", text)
    text = CONTROL_RE.sub(" ", text)
    text = text.replace("`", "").replace("*", "").replace("_", "")
    text = SPACE_RE.sub(" ", text).strip(" -–—:")
    if len(text) > MAX_TITLE:
        text = text[: MAX_TITLE - 1].rstrip() + "…"
    return text


def label_names(issue: dict) -> set[str]:
    out = set()
    for label in issue.get("labels") or []:
        name = label.get("name") if isinstance(label, dict) else label
        if isinstance(name, str):
            out.add(name.strip().lower())
    return out


def fixed_version(labels: set[str]) -> str | None:
    for label in sorted(labels):
        match = FIXED_IN_RE.match(label)
        if match:
            return match.group(1)
    return None


def day(value: str | None) -> str | None:
    return value[:10] if isinstance(value, str) and len(value) >= 10 else None


def suggestions(issues: list[dict], owner: str) -> list[dict]:
    """The released suggestions, from the PRIVATE repository's issues.

    Two rules carry the privacy of this lane. Nothing without the release label reaches the file, so no
    stranger's text appears in the app before the owner saw it; and the reply is the OWNER's own latest
    comment, never another account's, because the app has no way to show who said what and a quoted
    stranger would read as the project speaking.
    """
    out: list[dict] = []
    for issue in issues:
        labels = label_names(issue)
        if RELEASE_LABEL not in labels or HIDE_LABEL in labels:
            continue
        number = issue.get("number")
        title = sanitise(issue.get("title", ""))
        if not isinstance(number, int) or not title:
            continue
        body = issue.get("body") or ""
        # The worker makes the title from the first line, so the detail is what came after it.
        detail = "\n".join(body.splitlines()[1:]).strip() if body.strip().startswith(title[:40]) else body
        status = "open"
        roadmap = None
        for label in sorted(labels):
            status = SUGGESTION_STATUS.get(label, status)
            if label.startswith(ROADMAP_LABEL):
                roadmap = label[len(ROADMAP_LABEL):] or None
        reply = ""
        for comment in issue.get("comments") or []:
            author = ((comment.get("author") or {}).get("login") or "").lower()
            if author == owner.lower():
                reply = comment.get("body") or reply
        row = {
            "id": f"s-{number}",
            "title": title,
            "detail": sanitise_block(detail, MAX_SUGGESTION_DETAIL),
            "status": status,
        }
        if reply.strip():
            row["reply"] = sanitise_block(reply, MAX_REPLY)
        if roadmap:
            row["roadmap"] = roadmap
        out.append(row)
    out.sort(key=lambda r: -int(r["id"].split("-")[1]))
    return out


def sanitise_block(text: str, limit: int) -> str:
    """Like `sanitise`, but keeps sentences: the app renders this as a paragraph, not a row label."""
    cleaned = LINK_RE.sub(r"\1", text or "")
    cleaned = URL_RE.sub("", cleaned)
    cleaned = CONTROL_RE.sub(" ", cleaned)
    cleaned = cleaned.replace("`", "").replace("*", "").replace("_", "")
    cleaned = SPACE_RE.sub(" ", cleaned).strip()
    if len(cleaned) > limit:
        cleaned = cleaned[: limit - 1].rstrip() + "…"
    return cleaned


def service_url(value: str | None) -> str | None:
    """Judge the service address here, by the same rule the core applies in `ProjectFeedParser.service`.

    The app keeps an address only when it is https with a host and carries no credentials, and discards
    anything else without a word, on every device at once. Refusing it here as well means a typo in the
    repository variable fails the job that wrote it, instead of publishing a feed on which voting simply
    never appears. Empty means there is no service, which is the kill switch, not an error.
    """
    text = (value or "").strip()
    if not text:
        return None
    parsed = urlparse(text)
    if parsed.scheme.lower() != "https" or not parsed.hostname:
        raise SystemExit(f"FAIL service {text!r}: an https address with a host, or nothing at all")
    if parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise SystemExit(f"FAIL service {text!r}: no credentials, no query, no fragment")
    return text.rstrip("/")


def build(issues: list[dict], now: datetime, service: str | None = None,
          released: list[dict] | None = None, owner: str = "DX23876") -> dict:
    open_items: list[dict] = []
    fixed: list[dict] = []
    decided: list[dict] = []
    cutoff = now - timedelta(days=DECIDED_DAYS)

    for issue in issues:
        labels = label_names(issue)
        if HIDE_LABEL in labels or BUG_LABEL not in labels:
            continue
        number = issue.get("number")
        title = sanitise(issue.get("title", ""))
        if not isinstance(number, int) or not title:
            continue
        state = (issue.get("state") or "").upper()
        reason = (issue.get("stateReason") or "").upper()

        if state == "OPEN":
            open_items.append({
                "n": number,
                "title": title,
                "status": "working" if WORKING_LABEL in labels else "reported",
                "opened": day(issue.get("createdAt")),
            })
            continue

        closed = day(issue.get("closedAt"))
        if reason == "NOT_PLANNED":
            closed_at = issue.get("closedAt")
            try:
                when = datetime.fromisoformat((closed_at or "").replace("Z", "+00:00"))
            except ValueError:
                when = None
            if when is not None and when >= cutoff:
                decided.append({"n": number, "title": title, "closed": closed, "status": "notPlanned"})
            continue
        entry = {"n": number, "title": title, "status": "fixed", "closed": closed}
        version = fixed_version(labels)
        if version:
            entry["fixedIn"] = version
        fixed.append(entry)

    open_items.sort(key=lambda i: -i["n"])
    fixed.sort(key=lambda i: ((i.get("closed") or ""), i["n"]), reverse=True)
    decided.sort(key=lambda i: ((i.get("closed") or ""), i["n"]), reverse=True)
    fixed = fixed[:RECENT_FIXED]

    payload = {
        "schema": 1,
        "generated": now.replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "service": service,
        "counts": {
            "reported": sum(1 for i in open_items if i["status"] == "reported"),
            "working": sum(1 for i in open_items if i["status"] == "working"),
            "fixed": len(fixed),
        },
        "suggestions": suggestions(released or [], owner)[:MAX_ITEMS],
        "issues": open_items[:MAX_ITEMS],
        "fixed": fixed,
        "decided": decided[:MAX_ITEMS],
    }
    return payload


def unchanged(payload: dict, path: Path) -> bool:
    """True when only `generated` would move. Keeps the commit history about real changes."""
    if not path.exists():
        return False
    try:
        old = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return False
    return {k: v for k, v in old.items() if k != "generated"} == \
           {k: v for k, v in payload.items() if k != "generated"}


def render(payload: dict) -> str:
    return json.dumps(payload, indent=2, sort_keys=True, ensure_ascii=False) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--issues-file", required=True, help="`gh issue list --json …` output")
    parser.add_argument("--out", default=str(OUT))
    parser.add_argument("--service", default=None, help="base URL of the service, once it exists")
    parser.add_argument("--suggestions-file", default=None,
                        help="`gh issue list --json number,title,body,labels,comments` of the PRIVATE "
                             "suggestions repository; only items carrying the release label are used")
    parser.add_argument("--owner", default="DX23876", help="whose comment counts as the reply")
    parser.add_argument("--now", default=None, help="ISO timestamp, for reproducible runs and tests")
    args = parser.parse_args()

    issues = json.loads(Path(args.issues_file).read_text(encoding="utf-8"))
    now = (datetime.fromisoformat(args.now.replace("Z", "+00:00")) if args.now
           else datetime.now(timezone.utc))
    service = service_url(args.service)
    released = (json.loads(Path(args.suggestions_file).read_text(encoding="utf-8"))
                if args.suggestions_file else [])
    payload = build(issues, now=now, service=service, released=released, owner=args.owner)
    path = Path(args.out)
    if unchanged(payload, path):
        print(f"OK {path}: unchanged ({payload['counts']})")
        return 0
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(render(payload), encoding="utf-8")
    print(f"OK {path}: written ({payload['counts']})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
