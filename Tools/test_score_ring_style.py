"""Every Charge, Effort and Rest ring goes through `ScoreRing`, which honours the ring style setting.

A screen that drew `OrganicScoreRing` itself would keep moving after the wearer chose classic rings.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
ALLOWED = {"Strand/Liquid/ScoreRing.swift", "Strand/Liquid/OrganicScoreRing.swift"}


class ScoreRingStyleTest(unittest.TestCase):
    def test_no_screen_draws_the_organic_ring_directly(self) -> None:
        offenders = []
        for root in ("Strand", "StrandiOS", "StrandiOSShared"):
            for path in (REPO_ROOT / root).rglob("*.swift"):
                rel = path.relative_to(REPO_ROOT).as_posix()
                if rel in ALLOWED:
                    continue
                if re.search(r"(?<![A-Za-z])OrganicScoreRing\(", path.read_text(encoding="utf-8")):
                    offenders.append(rel)
        self.assertEqual(offenders, [], "draw score rings through ScoreRing so the ring style setting holds")


if __name__ == "__main__":
    unittest.main()
