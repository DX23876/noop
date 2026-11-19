#!/usr/bin/env python3
"""Carry the public issue's state back onto the private report, so the reporter is told once.

The way back a report has was half-built: `publish_reports.py` opens the public issue and writes
`Public: #N` into the private body, and the relay reads the status the app shows from the PRIVATE
issue alone (`src/worker.js`: closed means fixed, `NOT_PLANNED` means notPlanned, `in-progress`
means working, a `fixed-in:X.Y.Z` label carries the version). So the owner had to keep two issues in
step by hand, and the one that was easy to forget is the one nobody sees: label the public issue
`in-progress` and the reporter still reads "arrived", close it and they are never told it was fixed.

This closes that gap in ONE direction. The public issue is where the work is tracked; the private
one follows it:

- `in-progress` on the public issue is added to the private one, and removed again with it.
- a `fixed-in:X.Y.Z` label is copied across, and a stale one removed.
- public closed as completed closes the private issue as completed (the app then says "fixed").
- public closed as not planned closes it with that reason (the app says so, rather than inventing
  "we are looking into it").
- a reopened public issue reopens the private one.

What never travels: nothing at all from private to public. The reporter's text, their code, their
language and their log are not read here, and no comment is written into their thread - a mirror
that talks would turn a status into a message from somebody who said nothing.

It fails closed. No token, no private repository, an unreadable list: nothing is changed, which
leaves exactly the state that was there before. Without `--apply` it only says what it would do.

Usage:
    python3 Tools/mirror_reports.py --repo owner/private --public owner/noop --apply
    python3 Tools/mirror_reports.py --repo owner/private --public owner/noop   # dry run
    python3 Tools/mirror_reports.py --repo … --public … --public-file issues.json
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys

WORKING_LABEL = "in-progress"
FIXED_IN_RE = re.compile(r"^fixed-in:(\d+\.\d+(?:\.\d+)?)$")
#: The fields this needs from either side. Kept as one string so the workflow and a hand run agree.
PRIVATE_FIELDS = "number,body,labels,state,stateReason"
PUBLIC_FIELDS = "number,labels,state,stateReason"


def run_gh(args: list[str], run=subprocess.run) -> str:
    result = run(["gh", *args], capture_output=True, text=True, check=True)
    return (result.stdout or "").strip()


def labels_of(issue: dict) -> set[str]:
    out = set()
    for label in issue.get("labels") or []:
        name = label.get("name") if isinstance(label, dict) else label
        if name:
            out.add(str(name))
    return out


def public_number(body: str) -> int | None:
    """The public issue a report became, as `publish_reports.publish` wrote it."""
    match = re.search(r"(?:^|\n)Public: #(\d+)", body or "")
    return int(match.group(1)) if match else None


def fixed_in(labels: set[str]) -> str | None:
    for label in sorted(labels):
        if (hit := FIXED_IN_RE.match(label)) is not None:
            return hit.group(1)
    return None


def plan(private: dict, public: dict) -> tuple[list[str], list[str], str | None]:
    """What to add, what to remove, and whether to close or reopen. Only differences.

    Returns `(add, remove, state)` where `state` is "completed", "not planned", "open" or None for
    "leave the state alone". Nothing outside the mirrored set is ever proposed for removal: the
    report keeps `bug`, `from-app` and `published`, which are not this script's to touch.
    """
    priv, pub = labels_of(private), labels_of(public)
    add: list[str] = []
    remove: list[str] = []

    if WORKING_LABEL in pub and WORKING_LABEL not in priv:
        add.append(WORKING_LABEL)
    if WORKING_LABEL not in pub and WORKING_LABEL in priv:
        remove.append(WORKING_LABEL)

    want_version, have_version = fixed_in(pub), fixed_in(priv)
    if want_version != have_version:
        if have_version is not None:
            remove.append(f"fixed-in:{have_version}")
        if want_version is not None:
            add.append(f"fixed-in:{want_version}")

    pub_state = (public.get("state") or "").upper()
    priv_state = (private.get("state") or "").upper()
    pub_reason = (public.get("stateReason") or "").upper()
    priv_reason = (private.get("stateReason") or "").upper()
    state: str | None = None
    if pub_state == "CLOSED":
        want = "not planned" if pub_reason == "NOT_PLANNED" else "completed"
        have = "not planned" if priv_reason == "NOT_PLANNED" else "completed"
        if priv_state != "CLOSED" or have != want:
            state = want
    elif priv_state == "CLOSED":
        state = "open"
    return add, remove, state


def describe(number: int, add: list[str], remove: list[str], state: str | None) -> str:
    parts = []
    if add:
        parts.append("+" + ",".join(add))
    if remove:
        parts.append("-" + ",".join(remove))
    if state:
        parts.append("reopened" if state == "open" else f"closed as {state}")
    return f"#{number}: " + (", ".join(parts) if parts else "already in step")


def mirror(repo: str, private: dict, public: dict, apply: bool, run=subprocess.run) -> str:
    add, remove, state = plan(private, public)
    number = private["number"]
    if not (add or remove or state):
        return describe(number, add, remove, state)
    if apply:
        if add or remove:
            args = ["issue", "edit", str(number), "-R", repo]
            for label in add:
                args += ["--add-label", label]
            for label in remove:
                args += ["--remove-label", label]
            run_gh(args, run=run)
        if state == "open":
            run_gh(["issue", "reopen", str(number), "-R", repo], run=run)
        elif state is not None:
            run_gh(["issue", "close", str(number), "-R", repo, "--reason",
                    "not planned" if state == "not planned" else "completed"], run=run)
    return ("" if apply else "would ") + describe(number, add, remove, state)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True, help="the private suggestions repository")
    parser.add_argument("--public", required=True, help="the public app repository")
    parser.add_argument("--issues-file", help=f"`gh issue list --json {PRIVATE_FIELDS}` of the private repo")
    parser.add_argument("--public-file", help=f"`gh issue list --json {PUBLIC_FIELDS}` of the public repo")
    parser.add_argument("--apply", action="store_true", help="write; without it nothing is changed")
    args = parser.parse_args()

    try:
        if args.issues_file:
            private = json.loads(open(args.issues_file, encoding="utf-8").read())
        else:
            private = json.loads(run_gh(["issue", "list", "-R", args.repo, "--state", "all",
                                         "--limit", "200", "--json", PRIVATE_FIELDS]))
        if args.public_file:
            public_list = json.loads(open(args.public_file, encoding="utf-8").read())
        else:
            public_list = json.loads(run_gh(["issue", "list", "-R", args.public, "--state", "all",
                                             "--limit", "300", "--json", PUBLIC_FIELDS]))
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"nothing mirrored: {error}")
        return 0

    by_number = {issue.get("number"): issue for issue in public_list if isinstance(issue, dict)}
    touched = 0
    for issue in private:
        if not isinstance(issue, dict) or not isinstance(issue.get("number"), int):
            continue
        number = public_number(issue.get("body", ""))
        if number is None:
            continue
        counterpart = by_number.get(number)
        if counterpart is None:
            # The public issue is gone or out of the window read above. Saying so beats guessing a
            # state from its absence: a deleted issue is not a fixed report.
            print(f"#{issue['number']}: public #{number} not in the list, left alone")
            continue
        line = mirror(args.repo, issue, counterpart, args.apply, run=subprocess.run)
        print(line)
        touched += 1
    print(f"{touched} published report(s) checked")
    return 0


if __name__ == "__main__":
    sys.exit(main())
