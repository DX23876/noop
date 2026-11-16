"""The sports somebody can tick on the "Help build it" page.

Every name there is matched against a running workout by `WorkoutSource.sportKey`, so a name the
catalogue does not carry simply never matches: the tick stays on, no window is ever recorded, and
nothing anywhere says why. Renaming a sport in `WorkoutCatalog` is the ordinary way to cause it, and
no build, test or gate notices today.

Both lists are read off the product source rather than restated here, which is the point: a copy kept
in this file would go stale in exactly the way the thing it guards does.
"""
from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CATALOG = ROOT / "Packages/StrandCore/Sources/StrandCore/WorkoutCatalog.swift"
PAGE = ROOT / "Strand/Screens/RawDonationView.swift"


def catalogue_sports() -> set[str]:
    return set(re.findall(r'Sport\(name:\s*"([^"]+)"', CATALOG.read_text(encoding="utf-8")))


def listed_sports() -> list[str]:
    text = PAGE.read_text(encoding="utf-8")
    names: list[str] = []
    for block in re.findall(r"(?:outdoorSports|indoorSports)\s*=\s*\[(.*?)\]", text, re.S):
        names += re.findall(r'"([^"]+)"', block)
    return names


class DonationSportsTest(unittest.TestCase):

    def test_every_tickable_sport_exists_in_the_catalogue(self):
        catalogue, listed = catalogue_sports(), listed_sports()
        self.assertGreater(len(catalogue), 50, "the catalogue was not read")
        self.assertGreaterEqual(len(listed), 10, "the page's lists were not read")
        unknown = sorted({name for name in listed if name not in catalogue})
        self.assertEqual(unknown, [], "a sport nobody can match: the tick stays on and no window "
                                      "is ever recorded, silently")

    def test_strength_stays_out(self):
        """Not an accident: the arm moves differently in every exercise, so a set of curls teaches a
        detector nothing. Written down because the list looks incomplete without it."""
        self.assertNotIn("Strength", listed_sports())


if __name__ == "__main__":
    unittest.main()
