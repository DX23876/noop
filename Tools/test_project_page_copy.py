"""Every word on the project pages has a catalogue entry.

The pages the fork added last (the project hub, problems, wishes, the help page and the report flow)
are new code written between Xcode builds, which is exactly when a catalogue entry does not exist
yet: Xcode extracts the keys, nothing else does. The audit's patterns are deliberately narrow and
cannot see every shape — a conditioned `subtitle:`, a `title:` argument — so for these five files the
rule is simply stricter: every literal that reads like copy must resolve to a catalogue entry.

A literal that is not copy is listed in ALLOWED below, by hand, so adding one is a decision rather
than an accident.
"""
from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "Tools"))

import i18n_audit as ia  # noqa: E402

FILES = ["Strand/Screens/ProjectPages.swift",
         "Strand/Screens/ProjectReportViews.swift",
         "Strand/Screens/RawDonationView.swift",
         "Strand/Screens/RoadmapView.swift",
         "Strand/System/ProjectReportWatcher.swift"]

# Not copy: defaults keys, file names, a date format, bundle-entry scaffolding, and the sport names,
# which are matched against `WorkoutCatalog` by name and translated with the catalogue.
ALLOWED = {
    "selectedWhoopModel", "projectReportNotices", "projectReportLastCheck", "ProjectPage",
    "noop-report", "picture.jpg", "-wal", "-shm", "UTC", "yyyy-MM-dd", "CFBundleShortVersionString",
    "Walking", "Nordic walking", "Hiking", "Running", "Rucking", "Cycling", "Mountain biking",
    "Rowing", "Treadmill walk", "Treadmill run", "Indoor cycle", "Spinning", "Elliptical",
    "Row machine", "Stair climber", "Jump rope", "Pool swim",
}


def copy_literals(rel: str) -> list[str]:
    text = ia.mask_swift_previews(ia._mask_comments((ROOT / rel).read_text(encoding="utf-8")))
    out = []
    for match in re.finditer(r'"((?:[^"\\\n]|\\.)*)"', text):
        literal = match.group(1)
        if literal in ALLOWED or not ia.is_probably_ui_text(literal):
            continue
        if "\\(" in literal or "\\n" in literal:      # a built string, checked where it is built
            continue
        if " " not in literal and ("." in literal or "_" in literal):   # symbol or asset name
            continue
        out.append(literal)
    return out


class ProjectPageCopyTest(unittest.TestCase):

    def test_every_line_on_these_pages_can_be_translated(self):
        catalog = ia.load_catalog(ROOT / "Strand/Resources/Localizable.xcstrings")
        missing = []
        for rel in FILES:
            for literal in copy_literals(rel):
                if ia.swift_catalog_lookup(catalog, literal) is None:
                    missing.append(f"{rel}: {literal!r}")
        self.assertEqual(missing, [], "copy with no catalog entry ships English everywhere")

    def test_the_scan_actually_reads_something(self):
        """A guard on the guard: a rename that empties the file list would pass silently."""
        self.assertGreater(sum(len(copy_literals(rel)) for rel in FILES), 60)


if __name__ == "__main__":
    unittest.main()
