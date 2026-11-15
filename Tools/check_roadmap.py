#!/usr/bin/env python3
"""Validate docs/roadmap.json, the hand-written roadmap the in-app Roadmap page renders.

The file is the owner's own text, edited by hand (and by an agent on request), so the gate here is not
"is this JSON" but "can the screen still draw it, and did a vote lose its anchor". Three classes:

1. Shape — unknown fields, unknown phase/area, missing or duplicate ids, over-long title/line, control
   characters, markdown or URLs in text that the screen renders as plain text.
2. Android reachability — every `icon` must appear in the Android icon map, because iOS SF Symbol names
   mean nothing to Compose. Without this, an icon added here renders as a blank square on Android and
   nobody notices until someone looks at a phone. This is the invalidator the gate has to observe.
3. Lost anchors — an `id` that existed in the previous revision and is gone now. Votes hang on ids, so
   removal has to be deliberate rather than a side effect of rewriting a line.

Usage:
    python3 Tools/check_roadmap.py
    python3 Tools/check_roadmap.py --base origin/main          # compare ids against that revision
    python3 Tools/check_roadmap.py --allow-removals            # removing an id is intended
Exit code 0 means pass; every finding is printed and the exit code is 1.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ROADMAP = ROOT / "docs" / "roadmap.json"
ANDROID_ICON_MAP = ROOT / "android/app/src/main/java/com/noop/ui/forge/ForgeRoadmap.kt"

PHASES = ("now", "next", "later")
AREAS = ("sleep", "cardio", "strength", "body", "app")
FIELDS = {"id", "phase", "title", "line", "icon", "area", "since"}
REQUIRED = ("id", "phase", "title", "line", "icon", "area")

ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]{1,38}$")
ICON_RE = re.compile(r"^[a-z0-9][a-z0-9.]{1,46}$")
SINCE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
URL_RE = re.compile(r"https?://|www\.", re.I)
MARKDOWN_RE = re.compile(r"\[[^\]]*\]\([^)]*\)|[*_`#]")
CONTROL_RE = re.compile(r"[\x00-\x1f\x7f]")

MAX_ITEMS = 60
MAX_TITLE = 48
MAX_LINE = 120


def load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def android_icons() -> set[str] | None:
    """The SF Symbol names the Android screen knows, read from its `"name" to Icons…` map.

    Returns None when the Android screen does not exist yet, so this check can be built before its twin
    without failing closed on a file that is about to appear.
    """
    if not ANDROID_ICON_MAP.exists():
        return None
    source = ANDROID_ICON_MAP.read_text(encoding="utf-8")
    return set(re.findall(r'"([a-z0-9][a-z0-9.]*)"\s+to\s+', source))


def text_findings(kind: str, item_id: str, value: str, limit: int) -> list[str]:
    out = []
    if not value.strip():
        out.append(f"{item_id}: {kind} is empty")
    if len(value) > limit:
        out.append(f"{item_id}: {kind} is {len(value)} characters, the screen takes {limit}")
    if CONTROL_RE.search(value):
        out.append(f"{item_id}: {kind} carries a control character")
    if MARKDOWN_RE.search(value):
        out.append(f"{item_id}: {kind} carries markdown; the screen renders plain text")
    if URL_RE.search(value):
        out.append(f"{item_id}: {kind} carries a URL; the screen renders plain text")
    return out


def check(data: dict, previous_ids: set[str] | None = None, allow_removals: bool = False,
          icons: set[str] | None = None) -> list[str]:
    findings: list[str] = []
    if data.get("schema") != 1:
        findings.append(f"schema is {data.get('schema')!r}, this checker and the app read 1")
    items = data.get("items")
    if not isinstance(items, list):
        return findings + ["items is missing or not a list"]
    if len(items) > MAX_ITEMS:
        findings.append(f"{len(items)} items, the cap is {MAX_ITEMS}")

    seen: set[str] = set()
    for index, item in enumerate(items):
        if not isinstance(item, dict):
            findings.append(f"item {index} is not an object")
            continue
        item_id = item.get("id", f"<item {index}>")
        for field in REQUIRED:
            if field not in item:
                findings.append(f"{item_id}: {field} is missing")
        unknown = sorted(set(item) - FIELDS)
        if unknown:
            findings.append(f"{item_id}: unknown field(s) {', '.join(unknown)}")

        if isinstance(item.get("id"), str):
            if not ID_RE.match(item["id"]):
                findings.append(f"{item_id}: id must be lowercase letters, digits and dashes")
            if item["id"] in seen:
                findings.append(f"{item_id}: id appears twice")
            seen.add(item["id"])
        elif "id" in item:
            findings.append(f"item {index}: id is not a string")

        phase = item.get("phase")
        if phase is not None and phase not in PHASES:
            findings.append(f"{item_id}: phase {phase!r} is not one of {', '.join(PHASES)}")
        area = item.get("area")
        if area is not None and area not in AREAS:
            findings.append(f"{item_id}: area {area!r} is not one of {', '.join(AREAS)}")

        for kind, limit in (("title", MAX_TITLE), ("line", MAX_LINE)):
            value = item.get(kind)
            if isinstance(value, str):
                findings += text_findings(kind, item_id, value, limit)
            elif kind in item:
                findings.append(f"{item_id}: {kind} is not a string")

        icon = item.get("icon")
        if isinstance(icon, str):
            if not ICON_RE.match(icon):
                findings.append(f"{item_id}: icon {icon!r} is not a symbol name")
            elif icons is not None and icon not in icons:
                findings.append(
                    f"{item_id}: icon {icon!r} has no Android counterpart. Add it to the map in "
                    f"{ANDROID_ICON_MAP.relative_to(ROOT)}, or the card draws nothing on Android.")
        elif "icon" in item:
            findings.append(f"{item_id}: icon is not a string")

        since = item.get("since")
        if since is not None:
            if not (isinstance(since, str) and SINCE_RE.match(since)):
                findings.append(f"{item_id}: since must look like 2026-11-15")
            if phase != "now":
                findings.append(f"{item_id}: since belongs to a phase 'now' item only")

    if previous_ids is not None and not allow_removals:
        lost = sorted(previous_ids - seen)
        if lost:
            findings.append(
                "id(s) gone since the previous revision: " + ", ".join(lost)
                + ". Votes hang on these. Pass --allow-removals when that is intended.")
    return findings


def ids_at_revision(base: str, path: str) -> set[str] | None:
    try:
        blob = subprocess.run(["git", "show", f"{base}:{path}"], cwd=ROOT, check=True,
                              capture_output=True, text=True).stdout
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None
    try:
        return {i["id"] for i in json.loads(blob).get("items", []) if isinstance(i.get("id"), str)}
    except json.JSONDecodeError:
        return None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--file", default=str(ROADMAP))
    parser.add_argument("--base", help="git revision to compare ids against, e.g. origin/main")
    parser.add_argument("--previous-file", help="a previous roadmap.json to compare ids against")
    parser.add_argument("--allow-removals", action="store_true")
    args = parser.parse_args()

    path = Path(args.file)
    if not path.exists():
        print(f"FAIL {path}: file is missing")
        return 1
    try:
        data = load(path)
    except json.JSONDecodeError as error:
        print(f"FAIL {path}: not valid JSON ({error})")
        return 1

    previous = None
    if args.previous_file:
        previous = {i["id"] for i in load(Path(args.previous_file)).get("items", [])
                    if isinstance(i.get("id"), str)}
    elif args.base:
        try:
            relative = path.resolve().relative_to(ROOT).as_posix()
        except ValueError:
            relative = path.as_posix()
        previous = ids_at_revision(args.base, relative)
        if previous is None:
            print(f"NOTE {args.base}: no readable roadmap there, skipping the lost-id check")

    findings = check(data, previous_ids=previous, allow_removals=args.allow_removals,
                     icons=android_icons())
    for finding in findings:
        print(f"FAIL {finding}")
    if findings:
        print(f"\n{len(findings)} finding(s) in {path}")
        return 1
    print(f"OK {path}: {len(data['items'])} items")
    return 0


if __name__ == "__main__":
    sys.exit(main())
