#!/usr/bin/env python3
"""Every background-task identifier the app registers must be permitted in `project.yml`.

iOS refuses `BGTaskScheduler.submit` for an identifier that is not listed in
`BGTaskSchedulerPermittedIdentifiers`, and every scheduler here swallows that refusal
(`try? BGTaskScheduler.shared.submit(request)`), because a declined background slot is not worth
an error path. The cost of the pair drifting is therefore silence: the task is registered, the
request is refused, nothing ever runs, and the feature only works while the app is open.

That is what happened to the stale-battery check. Its `.stalebattery` identifier was registered
from `StrandiOSApp.init` and left out of the permitted list, under a comment claiming the list
permits every identifier, and nothing could report it. This test is that report.

Run with::

    python3 Tools/test_background_task_ids.py
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# The app targets that can own a background task. `Packages/` cannot: BackgroundTasks is a
# framework the packages must not import (AGENTS.md), and the watch/widget targets have no
# BGTaskScheduler surface.
APP_DIRECTORIES = ("Strand", "StrandiOS")

# A launch handler being registered. The argument is a name, not a literal, in all six call sites:
# the literal is in the declaration the next pattern reads.
REGISTER = re.compile(
    r"BGTaskScheduler\.shared\.register\(\s*forTaskWithIdentifier:\s*([A-Za-z_][\w.]*)")

# How every scheduler builds its identifier, so it tracks BUNDLE_ID_PREFIX at runtime:
#   static let taskIdentifier = (Bundle.main.bundleIdentifier ?? "com.noopapp.noop") + ".rescore"
# Only the suffix is comparable with `project.yml`, where the prefix is $(PRODUCT_BUNDLE_IDENTIFIER).
DECLARED_SUFFIX = re.compile(
    r"Bundle\.main\.bundleIdentifier\s*\?\?\s*\"[^\"]*\"\s*\)\s*\+\s*\"\.([A-Za-z0-9]+)\"")

# One permitted entry: `- $(PRODUCT_BUNDLE_IDENTIFIER).rescore`
PERMITTED_ENTRY = re.compile(r"^\s*-\s*\$\(PRODUCT_BUNDLE_IDENTIFIER\)\.([A-Za-z0-9]+)\s*$")

PERMITTED_KEY = "BGTaskSchedulerPermittedIdentifiers:"


def swift_sources() -> list[Path]:
    out: list[Path] = []
    for directory in APP_DIRECTORIES:
        out.extend(sorted((ROOT / directory).rglob("*.swift")))
    return out


def registered_suffixes() -> tuple[set[str], list[str]]:
    """The identifier suffixes the app registers, and the files that register without declaring one."""
    suffixes: set[str] = set()
    unresolved: list[str] = []
    for path in swift_sources():
        text = path.read_text(encoding="utf-8")
        if not REGISTER.search(text):
            continue
        found = set(DECLARED_SUFFIX.findall(text))
        if found:
            suffixes |= found
        else:
            unresolved.append(str(path.relative_to(ROOT)))
    return suffixes, unresolved


def permitted_blocks() -> list[set[str]]:
    """Every `BGTaskSchedulerPermittedIdentifiers` list in `project.yml`, as sets of suffixes."""
    lines = (ROOT / "project.yml").read_text(encoding="utf-8").splitlines()
    blocks: list[set[str]] = []
    for index, line in enumerate(lines):
        if line.strip() != PERMITTED_KEY:
            continue
        block: set[str] = set()
        for rest in lines[index + 1:]:
            stripped = rest.strip()
            if not stripped or stripped.startswith("#"):
                continue          # blank lines and the per-entry explanations between them
            if not stripped.startswith("-"):
                break             # the next key ends the list
            match = PERMITTED_ENTRY.match(rest)
            if match:
                block.add(match.group(1))
            else:
                block.add(f"unparsed:{stripped}")
        blocks.append(block)
    return blocks


class BackgroundTaskIdentifiers(unittest.TestCase):

    def test_the_scan_finds_the_schedulers_at_all(self):
        """A zero-finding scan passes everything; it must read as broken discovery instead."""
        suffixes, unresolved = registered_suffixes()
        self.assertEqual(unresolved, [],
                         "these files register a launch handler but build its identifier in a shape this "
                         "test does not know; teach DECLARED_SUFFIX about it rather than deleting the case")
        self.assertGreaterEqual(len(suffixes), 5,
                                "the scan found almost no registered background tasks, so the comparison "
                                "below proves nothing: the patterns, not the app, are what to look at")

    def test_project_yml_has_exactly_one_permitted_list(self):
        """Only the iOS app owns background tasks, so one list is the whole roster to compare against."""
        blocks = permitted_blocks()
        self.assertEqual(len(blocks), 1,
                         "project.yml carries %d BGTaskSchedulerPermittedIdentifiers lists; a second target "
                         "with background tasks needs this test to compare per target" % len(blocks))
        self.assertEqual([e for e in blocks[0] if e.startswith("unparsed:")], [],
                         "an entry in the permitted list is not $(PRODUCT_BUNDLE_IDENTIFIER).<suffix>, so it "
                         "cannot be compared with what the code registers")

    def test_every_registered_identifier_is_permitted_and_nothing_stale_is_listed(self):
        registered, _ = registered_suffixes()
        permitted = permitted_blocks()[0]

        missing = sorted(registered - permitted)
        self.assertEqual(missing, [],
                         "registered but NOT permitted in project.yml: %s. iOS refuses the submit and the "
                         "scheduler's `try?` swallows it, so the task never runs outside the foreground. "
                         "Add $(PRODUCT_BUNDLE_IDENTIFIER).<suffix> to BGTaskSchedulerPermittedIdentifiers."
                         % ", ".join(missing))

        stale = sorted(permitted - registered)
        self.assertEqual(stale, [],
                         "permitted in project.yml but registered nowhere: %s. Either the scheduler was "
                         "removed and the permission outlived it, or its identifier moved and the list now "
                         "names a task that cannot exist." % ", ".join(stale))


if __name__ == "__main__":
    unittest.main()
