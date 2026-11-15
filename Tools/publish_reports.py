#!/usr/bin/env python3
"""Turn a reported problem into a public issue, on the owner's press and never before.

A report sent from the app lands as an issue in the PRIVATE suggestions repository, and stops there.
Publishing is the one point in the whole path where something a stranger wrote becomes public, so it
is a human decision: this script never publishes on arrival, only on a label the owner sets.

What it does, in two passes over the private repository:

1. **Propose.** For a report that has no proposal yet, it asks the cheap model for a title and two
   sentences IN ENGLISH, because the repository's language is English and reports arrive in whatever
   the reporter speaks. The proposal is posted as a comment carrying the relay's own marker, so the
   reporter never sees it in their thread, and the owner reads it where the report is.
2. **Publish.** For a report the owner labelled, it opens the public issue from that proposal, writes
   `Public: #N` into the private body so the app can tell the reporter where it went, and takes the
   label back off.

What never crosses: the reporter's raw text, their code, their language, the log. A title and two
sentences do, and the owner has read them first.

It fails closed in both passes. No key, no answer, an unreadable answer: nothing is proposed and
nothing is published, which leaves exactly the state that was there before.

Usage:
    python3 Tools/publish_reports.py --repo owner/private --public owner/noop --apply
    python3 Tools/publish_reports.py --repo owner/private --public owner/noop        # dry run
Environment: NOOP_MODERATION_KEY, optional NOOP_MODERATION_URL and NOOP_MODERATION_MODEL.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from typing import Callable

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from moderate_suggestions import Held, ask_openai  # noqa: E402

PUBLISH_LABEL = "publish"
PUBLISHED_LABEL = "published"
REPORT_LABELS = {"bug", "from-app"}
# The same marker the relay puts on its own notes, so a proposal stays out of the reporter's thread.
RELAY_MARKER = "<!--relay-->"
PROPOSAL_HEADER = "Proposal for the public issue"
MAX_TITLE = 120
MAX_SUMMARY = 400

PROMPT = """You rewrite a bug report for a public issue tracker.

The app is NOOP, an offline companion for a fitness strap. The report below was sent from inside the
app by somebody who is not a developer, in whatever language they speak. Write a public issue for it.

Answer with STRICT JSON and nothing else:
{"title": "...", "summary": "..."}

Rules:
- English, both fields, whatever language the report is in.
- The title is one line, at most 100 characters, naming the symptom. Not "Bug" and not a question.
- The summary is at most two sentences: what happens, and when. No speculation about the cause.
- Never copy a name, a mail address, a URL, a device identifier or a code out of the report.
- If the report says nothing usable, answer {"title": "", "summary": ""}.

The report:
---
%s
---
"""


def proposal_comment(title: str, summary: str) -> str:
    """The comment the owner reads. Marked, so the reporter's thread never shows it."""
    return (f"{RELAY_MARKER}\n**{PROPOSAL_HEADER}**\n\n"
            f"`{title}`\n\n{summary}\n\n"
            f"Set the `{PUBLISH_LABEL}` label to open this as a public issue.")


def has_proposal(comments: list[dict]) -> bool:
    return any(PROPOSAL_HEADER in (c.get("body") or "") for c in comments)


def read_proposal(comments: list[dict]) -> tuple[str, str] | None:
    """The newest proposal in the thread, as (title, summary). None when there is none to publish."""
    for comment in reversed(comments):
        body = comment.get("body") or ""
        if PROPOSAL_HEADER not in body:
            continue
        match = re.search(r"`([^`]+)`\n\n(.+?)\n\nSet the ", body, re.S)
        if not match:
            return None
        title = match.group(1).strip()[:MAX_TITLE]
        summary = match.group(2).strip()[:MAX_SUMMARY]
        return (title, summary) if title else None
    return None


def parse_draft(raw: str) -> tuple[str, str]:
    """Title and summary out of a model answer. Anything unreadable is a hold, never a guess."""
    text = (raw or "").strip()
    if text.startswith("```"):
        text = re.sub(r"^```[a-zA-Z]*\n|\n```$", "", text).strip()
    try:
        data = json.loads(text)
    except json.JSONDecodeError as error:
        raise Held(f"the model did not answer in JSON ({error.msg})") from error
    if not isinstance(data, dict):
        raise Held("the model answered with something that is not an object")
    title = str(data.get("title") or "").strip().replace("\n", " ")[:MAX_TITLE]
    summary = str(data.get("summary") or "").strip()[:MAX_SUMMARY]
    if not title:
        raise Held("the model found nothing usable in the report")
    return title, summary


def reported_text(body: str) -> str:
    """The report as written, without the lines the relay appended."""
    cut = re.search(r"\nCode: |\nSent without a thread|\nPublic: #", body or "")
    return (body[: cut.start()] if cut else (body or "")).strip()


def already_public(body: str) -> int | None:
    match = re.search(r"(?:^|\n)Public: #(\d+)", body or "")
    return int(match.group(1)) if match else None


def public_body(summary: str, number: int) -> str:
    """What the public issue says. The summary, and where it came from. Never the raw report."""
    return (f"{summary}\n\n"
            f"_Reported from inside the app. The full report and its log stay private._")


def run_gh(args: list[str], run=subprocess.run) -> str:
    result = run(["gh", *args], capture_output=True, text=True, check=True)
    return (result.stdout or "").strip()


def propose(repo: str, issue: dict, ask: Callable[[str], str], apply: bool, run=subprocess.run) -> str:
    text = reported_text(issue.get("body", ""))
    if not text:
        return "skipped: nothing written"
    try:
        title, summary = parse_draft(ask(PROMPT % text[:2000]))
    except Held as error:
        return f"held: {error}"
    if apply:
        run_gh(["issue", "comment", str(issue["number"]), "-R", repo,
                "--body", proposal_comment(title, summary)], run=run)
    return f"proposed: {title}"


def publish(repo: str, public: str, issue: dict, apply: bool, run=subprocess.run) -> str:
    if (existing := already_public(issue.get("body", ""))) is not None:
        return f"skipped: already #{existing}"
    proposal = read_proposal(issue.get("comments", []))
    if proposal is None:
        return "held: no readable proposal to publish"
    title, summary = proposal
    if not apply:
        return f"would publish: {title}"
    number = int(run_gh(["issue", "create", "-R", public, "--title", title,
                         "--body", public_body(summary, issue["number"]), "--label", "bug"],
                        run=run).rstrip("/").rsplit("/", 1)[-1])
    body = (issue.get("body", "") or "").rstrip() + f"\nPublic: #{number}"
    run_gh(["issue", "edit", str(issue["number"]), "-R", repo, "--body", body], run=run)
    run_gh(["issue", "edit", str(issue["number"]), "-R", repo,
            "--remove-label", PUBLISH_LABEL, "--add-label", PUBLISHED_LABEL], run=run)
    return f"published as #{number}"


def labels_of(issue: dict) -> set[str]:
    return {(label.get("name") or "") for label in issue.get("labels", [])}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--issues-file", help="`gh issue list --json …` of the PRIVATE repository")
    parser.add_argument("--repo", required=True, help="the private suggestions repository")
    parser.add_argument("--public", required=True, help="the public app repository")
    parser.add_argument("--apply", action="store_true", help="write; without it nothing is changed")
    args = parser.parse_args()

    if args.issues_file:
        issues = json.loads(open(args.issues_file, encoding="utf-8").read())
    else:
        issues = json.loads(run_gh(["issue", "list", "-R", args.repo, "--state", "open",
                                    "--limit", "100", "--json",
                                    "number,title,body,labels,comments"]))

    key = os.environ.get("NOOP_MODERATION_KEY", "")
    url = os.environ.get("NOOP_MODERATION_URL", "https://api.openai.com/v1/chat/completions")
    model = os.environ.get("NOOP_MODERATION_MODEL", "gpt-5-mini")

    def ask(prompt: str) -> str:
        if not key:
            raise Held("no model key configured")
        return ask_openai(prompt, url=url, key=key, model=model)

    reports = [i for i in issues if REPORT_LABELS <= labels_of(i)]
    for issue in reports:
        labels = labels_of(issue)
        if PUBLISH_LABEL in labels:
            print(f"#{issue['number']}: {publish(args.repo, args.public, issue, args.apply)}")
        elif not has_proposal(issue.get("comments", [])):
            print(f"#{issue['number']}: {propose(args.repo, issue, ask, args.apply)}")
    print(f"OK {len(reports)} report(s) seen")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
