#!/usr/bin/env python3
"""The Charge breakdown's skin-temperature lines must not name a temperature unit themselves.

The fault this pins: both lines carried a literal "C" in the string while the number came from the
scoring engine in Celsius, so a wearer who had set Fahrenheit was shown a Celsius figure and told it
was Celsius. Apple fixed the same thing in #622 with `ChargeBreakdownFormat.displayDriver`.

The unit now rides with the figure (`UnitFormatter.skinTempDeviation`, covered by
`UnitFormatterTest`), so the sentence is pinned at both ends: that test says the figure carries
"°C"/"°F", this one says the string around it carries no unit of its own, in every locale. Neither
half can see the other, which is exactly how the bug survived: each looked right alone.

Run with::

    python3 Tools/test_temperature_rows_carry_no_unit.py
"""

from __future__ import annotations

import re
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RES = ROOT / "android/app/src/main/res"

# The two lines of the Charge breakdown that state a skin-temperature deviation.
KEYS = ("today_driver_value_temp_deviation", "forge_cb_vs_normal")

# A degree sign, or a lone C/F standing as a unit next to the figure. "°C" is the giveaway; the bare
# letter is how the fault was actually written.
UNIT = re.compile(r"°|(?:^|[\s(])[CF](?:$|[\s).,·])")
PLACEHOLDER = re.compile(r"%(?:\d+\$)?[-#+ 0,(]*\d*(?:\.\d+)?[a-zA-Z@]")


def strings(path: Path) -> dict[str, str]:
    return {el.get("name"): "".join(el.itertext()) for el in ET.parse(path).getroot()
            if el.tag == "string" and el.get("name")}


class TemperatureRowTests(unittest.TestCase):
    def test_no_locale_names_the_unit_in_the_string(self):
        files = [RES / "values/strings.xml", *sorted(RES.glob("values-*/strings.xml"))]
        self.assertGreater(len(files), 1, "no locale files found")
        for path in files:
            table = strings(path)
            for key in KEYS:
                with self.subTest(locale=path.parent.name, key=key):
                    self.assertIn(key, table, f"{key} is missing from {path.parent.name}")
                    value = table[key]
                    self.assertIsNone(
                        UNIT.search(value),
                        f"{path.parent.name}/{key} names a temperature unit itself ({value!r}); the "
                        f"figure carries it, so this one is wrong for a Fahrenheit reader")

    def test_each_line_takes_exactly_the_one_figure(self):
        """One placeholder, because the figure arrives whole: number, sign and unit together."""
        for path in [RES / "values/strings.xml", *sorted(RES.glob("values-*/strings.xml"))]:
            table = strings(path)
            for key in KEYS:
                with self.subTest(locale=path.parent.name, key=key):
                    found = PLACEHOLDER.findall(table[key].replace("%%", ""))
                    self.assertEqual(1, len(found),
                                     f"{path.parent.name}/{key} takes {len(found)} values, not 1")


if __name__ == "__main__":
    unittest.main()
