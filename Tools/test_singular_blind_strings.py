#!/usr/bin/env python3
"""A count beside a fixed plural noun, with no singular to fall back on.

What it looks like on screen: "Best series so far: 1 weeks" on the weekly-goal page, seen on a real
build (2026-11-18). The string is "Best series so far: %lld weeks" with no plural form, so the only
wording it has is the plural one, whatever the number says.

Both platforms have the machinery and use it elsewhere: Android `<plurals>` and the String Catalog's
`variations.plural`. This counts the places that do not, per platform, against a baseline that may
only shrink.

Counted only where the noun is governed by the string's ONLY number. "%lld of %lld days" is not a
fault however small the first number gets: the noun belongs to the second one, and "1 of 4 nights"
is correct English. Counting those made the number twice as large and every one of them a false
alarm, which is how a gate stops being read.

Even so it is a floor, not a verdict: some of what is left can never show 1 either (a trailing window
is 7, 14 or 30 days, never one), and arguing that case by case is worth less than the line this
holds. What the baseline stops is the number going UP.

Run with::

    python3 Tools/test_singular_blind_strings.py
"""

from __future__ import annotations

import json
import re
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RES = ROOT / "android/app/src/main/res/values/strings.xml"
CATALOGS = ("Strand/Resources/Localizable.xcstrings",
            "StrandiOSWidgets/Localizable.xcstrings",
            "Packages/StrandDesign/Sources/StrandDesign/Resources/Localizable.xcstrings")
BASELINE = Path(__file__).resolve().parent / "i18n_singular_baseline.txt"

# A count straight against a noun that only exists here in the plural. Deliberately a short, closed
# list of nouns rather than "any word ending in s": "%lld days" is the shape, "%@ status" is not.
NOUNS = ("weeks", "days", "months", "nights", "workouts", "minutes", "hours", "readings",
         "sessions", "times", "entries", "years", "sets", "reps", "sources", "steps")
COUNT = re.compile(r"%(?:\d+\$)?(?:lld|llu|d|u)\s+(?:" + "|".join(NOUNS) + r")\b")
NUMBER = re.compile(r"%(?:\d+\$)?(?:lld|llu|d|u)\b")


def singular_blind(text: str) -> bool:
    """True when a count stands against a plural noun AND is the only number in the line."""
    return bool(COUNT.search(text)) and len(NUMBER.findall(text)) == 1


def android_singular_blind() -> list[str]:
    root = ET.parse(RES).getroot()
    out = []
    for el in root:
        if el.tag != "string" or not el.get("name"):
            continue
        if singular_blind("".join(el.itertext())):
            out.append(el.get("name"))
    return sorted(out)


def apple_singular_blind() -> list[str]:
    out = []
    for rel in CATALOGS:
        path = ROOT / rel
        if not path.exists():
            continue
        for key, entry in json.loads(path.read_text(encoding="utf-8")).get("strings", {}).items():
            if not singular_blind(key):
                continue
            # An entry that carries plural variations anywhere has been dealt with.
            if '"plural"' in json.dumps(entry):
                continue
            out.append(f"{Path(rel).parent.name}:{key}")
    return sorted(out)


def baseline() -> dict[str, int]:
    allowed = {}
    for line in BASELINE.read_text(encoding="utf-8").splitlines():
        line = line.split("#", 1)[0].strip()
        if line:
            name, count = line.rsplit(" ", 1)
            allowed[name] = int(count)
    return allowed


class SingularBlindTests(unittest.TestCase):
    def test_neither_platform_grows_its_count(self):
        allowed = baseline()
        for name, found in (("android", android_singular_blind()), ("apple", apple_singular_blind())):
            with self.subTest(platform=name):
                self.assertIn(name, allowed, f"{name} has no baseline entry")
                example = f" e.g. {found[0]}" if found else ""
                self.assertLessEqual(
                    len(found), allowed[name],
                    f"{name}: {len(found)} string(s) put a count beside a plural noun with no "
                    f"singular, allowance is {allowed[name]}.{example}")

    def test_the_baseline_does_not_sit_above_what_is_there(self):
        """An allowance left high after a repair stops the gate from guarding that platform."""
        allowed = baseline()
        self.assertEqual(len(android_singular_blind()), allowed["android"],
                         "android: lower the baseline to what is left")
        self.assertEqual(len(apple_singular_blind()), allowed["apple"],
                         "apple: lower the baseline to what is left")

    def test_the_repaired_streak_lines_stay_repaired(self):
        """The ones that were seen saying "1 weeks" on screen are a zero-tolerance set."""
        android = set(android_singular_blind())
        for name in ("forge_goals_best_weeks", "forge_goals_streak_weeks",
                     "forge_goals_best_months", "forge_goals_streak_months"):
            with self.subTest(name=name):
                self.assertNotIn(name, android, f"{name} went back to a plain string")
        apple = set(apple_singular_blind())
        for key in ("Resources:Best series so far: %lld weeks", "Resources:%lld weeks in a row"):
            with self.subTest(key=key):
                self.assertNotIn(key, apple, f"{key} lost its plural variations")


if __name__ == "__main__":
    unittest.main()
