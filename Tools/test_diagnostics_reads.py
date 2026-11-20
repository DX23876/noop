#!/usr/bin/env python3
"""What the strap-log export is allowed to read, on both platforms.

The export is a diagnostic. It must not be able to take the app down, and it must not read a window it
is going to throw away. Both exports a tester took after a merge died with an OutOfMemoryError against
Android's 256 MB heap limit (#53, finding 4): the WHOOP 4 skin-temperature device anchor was read with
`Int.MAX_VALUE` over fourteen days - about 1.2 million rows on a 5/MG - handed across JNI as one JSON
string, parsed into objects a second time, and then dropped, because the anchor is a WHOOP 4 concept.

Source assertions rather than a run: the fault is not in a value the code computes, it is in which rows
it asks for, and nothing an export returns says how much it read. These run on the unfiltered
`tools-python` leg, so an edit to either file is seen by the gate that is about it.

Run with::

    python3 Tools/test_diagnostics_reads.py
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

ANDROID = ROOT / "android/app/src/main/java/com/noop/testcentre/AndroidDiagnostics.kt"
APPLE = ROOT / "Strand/System/DebugDataDiagnostics.swift"

#: The window both platforms read for the anchor. One number, named on each side, so a change to one
#: that is not made to the other fails here instead of on a wearer's phone.
ANCHOR_WINDOW_LIMIT = "200_000"


class SkinTempAnchorWindowTest(unittest.TestCase):

    def setUp(self) -> None:
        self.android = ANDROID.read_text(encoding="utf-8")
        self.apple = APPLE.read_text(encoding="utf-8")

    def test_android_names_the_same_limit_as_apple(self) -> None:
        self.assertIn(f"SKIN_TEMP_ANCHOR_WINDOW_LIMIT = {ANCHOR_WINDOW_LIMIT}", self.android)
        self.assertIn(f"skinTempAnchorWindowLimit = {ANCHOR_WINDOW_LIMIT}", self.apple)

    def test_no_multi_day_window_is_read_unbounded(self) -> None:
        """An unbounded row limit is only safe where the TIME span bounds it.

        The export reads several streams with `Int.MAX_VALUE`, and over one night that is fine: a night
        is about thirty thousand rows at 1 Hz. What is not fine is an unbounded read over a window of
        days, which is what the anchor read was. So the rule is about the two together: a read that
        spans days (`86400`) must name a limit.
        """
        offenders = [
            line.strip() for line in self.android.splitlines()
            if "Int.MAX_VALUE" in line and "86400" in line and not line.lstrip().startswith(("//", "*"))
        ]
        self.assertEqual([], offenders,
                         "a read spanning days must carry a row limit: " + "; ".join(offenders))

    def test_the_anchor_window_is_read_with_the_named_limit(self) -> None:
        self.assertRegex(self.android, r"skinTempSamples\([^)]*SKIN_TEMP_ANCHOR_WINDOW_LIMIT\)")
        self.assertRegex(self.apple, r"limit:\s*skinTempAnchorWindowLimit")

    def test_neither_platform_reads_the_anchor_window_under_a_5_mg(self) -> None:
        """The anchor is a WHOOP 4 concept. Reading it under any other family is pure waste, and on a
        5/MG the waste is the largest window in the store."""
        android_read = self._enclosing_lines(self.android, "SKIN_TEMP_ANCHOR_WINDOW_LIMIT", back=6)
        self.assertIn("WHOOP4", android_read,
                      "the Android anchor read must sit inside the WHOOP 4 branch, not before it")
        apple_read = self._enclosing_lines(self.apple, "skinTempAnchorWindowLimit", back=6)
        self.assertIn("family == .whoop4", apple_read,
                      "the Apple anchor read must sit inside the WHOOP 4 branch, not before it")

    @staticmethod
    def _enclosing_lines(source: str, needle: str, back: int) -> str:
        lines = source.splitlines()
        hits = [i for i, line in enumerate(lines) if needle in line]
        assert hits, f"{needle} not found"
        last = hits[-1]
        return "\n".join(lines[max(0, last - back):last + 1])


if __name__ == "__main__":
    unittest.main()
