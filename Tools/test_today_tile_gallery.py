"""The two phones' Today tile gallery offers the same measures, in the same order.

Why this exists: the gallery is the list of measures Today can place as a tile, and it is written twice —
once in Swift (`TileMeasures.all`, which the iPhone reads and which the core answers Android's reads from)
and once in Kotlin (`TodayWidgets.measures`, which draws Android's gallery rows). On 2026-11-18 the two
lists had drifted: iOS offered VO2max, stress, the fitness age and the calories eaten, Android offered
Charge, Effort and Rest instead, and "the same customisation on both phones" was not true. A Kotlin unit
test pins the Kotlin list against a literal, which catches a careless edit there but says nothing about the
Swift one; this reads BOTH and compares them, so adding a measure on one side alone fails.

It runs on the `tools-python` leg, which has no path filter, because the lists it reads are product source
in two different trees and no path list describes its inputs (the #1691 lesson).
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SWIFT = ROOT / "Strand/Data/TileHistory.swift"
KOTLIN = ROOT / "android/app/src/main/java/com/noop/ui/forge/ForgeTodayWidgets.kt"

# Android keys its measure tiles by the Key Metric spelling, iOS by the measure catalogue's
# (`KeyMetric.catalogKey`, ForgeTodayTile.kt). The two never meet in stored data, so the mapping lives here.
KEY_METRIC_CATALOG = {
    "KeyMetric.HRV.raw": "hrv",
    "KeyMetric.RESTING_HR.raw": "rhr",
    "KeyMetric.BLOOD_OXYGEN.raw": "spo2",
    "KeyMetric.RESPIRATORY.raw": "resp_rate",
    "KeyMetric.SKIN_TEMP.raw": "skin_temp",
    "KeyMetric.CALORIES.raw": "active_kcal",
    "KeyMetric.STEPS.raw": "steps",
    "KeyMetric.WEIGHT.raw": "weight",
    "TodayWidget.SLEEP_KEY": "sleep_total_min",
}


def swift_pairs() -> list[tuple[str, str]]:
    """`TileMeasures.all` as (key, source), in source order."""
    text = SWIFT.read_text(encoding="utf-8")
    start = text.index("static let all: [(key: String, source: String)] = [")
    body = text[start:text.index("\n    ]", start)]
    sources = {"MetricResolver.whoopSource": "my-whoop",
               "MetricResolver.appleHealthSource": "apple-health",
               "MetricResolver.healthConnectSource": "health-connect"}
    pairs = []
    for key, source in re.findall(r'\("([a-z0-9_]+)",\s*([^)]+)\)', body):
        source = source.strip()
        pairs.append((key, sources.get(source, source.strip('"'))))
    return pairs


def kotlin_keys() -> list[str]:
    """`TodayWidgets.measures` as catalogue keys, in source order."""
    text = KOTLIN.read_text(encoding="utf-8")
    start = text.index("val measures: List<String> = listOf(")
    body = text[start:text.index(")\n", start)]
    body = body[body.index("listOf(") + len("listOf("):]
    keys = []
    for raw in (part.strip() for part in body.split(",")):
        if not raw:
            continue
        if raw.startswith('"'):
            keys.append(raw.strip('"'))
        else:
            keys.append(KEY_METRIC_CATALOG.get(raw, raw))
    return keys


class TodayTileGalleryTests(unittest.TestCase):

    def test_both_galleries_offer_the_same_measures_in_the_same_order(self):
        swift = [key for key, _ in swift_pairs()]
        self.assertEqual(swift, kotlin_keys(),
                         "Today's tile gallery differs between the phones. Add the measure to both "
                         "TileMeasures.all (Strand/Data/TileHistory.swift) and TodayWidgets.measures "
                         "(ForgeTodayWidgets.kt), in the same place.")

    def test_every_entry_names_a_source(self):
        for key, source in swift_pairs():
            self.assertTrue(source, f"{key} has no source to read from")
            self.assertNotIn(" ", source, f"{key}'s source did not parse: {source!r}")

    def test_the_measures_that_are_read_from_somewhere_else_keep_their_source(self):
        """The three the strap does not carry. A weight read under the strap's source comes back empty,
        which is what left Android's weight tile with no caption at all until 2026-11-19."""
        sources = dict(swift_pairs())
        self.assertEqual(sources["weight"], "noop-weight")
        self.assertEqual(sources["active_kcal"], "apple-health")
        self.assertEqual(sources["calories_in"], "nutrition-csv")

    def test_both_phones_draw_the_week_for_the_same_measures(self):
        """The day totals, whose row-wide form is seven bars rather than thirty days of line. The list also
        decides which best mark the strip under the picture may name, so a phone with a different list would
        both draw a different chart AND date its best mark against a window the other does not have."""
        swift = (ROOT / "Strand/Data/MeasureFacts.swift").read_text(encoding="utf-8")
        body = swift[swift.index("static func drawsTheWeek"):]
        swift_keys = re.findall(r'"([a-z0-9_]+)"', body[:body.index("}")])
        kotlin = KOTLIN.read_text(encoding="utf-8")
        body = kotlin[kotlin.index("private fun isDayTotal"):]
        body = body[:body.index("\n\n")]
        kotlin_keys = []
        for raw in re.findall(r'"([a-z0-9_]+)"|KeyMetric\.([A-Z_]+)\.raw', body):
            literal, metric = raw
            kotlin_keys.append(literal or KEY_METRIC_CATALOG.get(f"KeyMetric.{metric}.raw", metric))
        self.assertEqual(sorted(set(swift_keys)), sorted(set(kotlin_keys)),
                         "the measures drawn as a week must be the same on both phones")

    def test_android_never_names_a_source_for_a_tile_itself(self):
        """Android asks the core by key (`CoreTile.history`). The moment it passes a source of its own, the
        table above stops being the one answer to "where is this tile's history read from"."""
        text = KOTLIN.read_text(encoding="utf-8")
        start = text.index("val factSeries by produceState")
        body = text[start:text.index("\n    val sleepMinutes", start)]
        self.assertIn("CoreTile.history(", body)
        self.assertNotIn("resolvedSeries(", body,
                         "the tile series is read through the core's one door, not by naming a source here")


if __name__ == "__main__":
    unittest.main()
