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


def swift_rows() -> list[tuple[str, str, str]]:
    """`TileMeasures.all` as (key, source, section), in source order."""
    text = SWIFT.read_text(encoding="utf-8")
    start = text.index("static let all: [(key: String, source: String, section: Section)] = [")
    body = text[start:text.index("\n    ]", start)]
    sources = {"MetricResolver.whoopSource": "my-whoop",
               "MetricResolver.appleHealthSource": "apple-health",
               "MetricResolver.healthConnectSource": "health-connect"}
    rows = []
    for key, source, section in re.findall(r'\("([a-z0-9_]+)",\s*([^,]+),\s*\.([a-z]+)\)', body):
        source = source.strip()
        rows.append((key, sources.get(source, source.strip('"')), section))
    return rows


def swift_pairs() -> list[tuple[str, str]]:
    return [(key, source) for key, source, _ in swift_rows()]


def kotlin_sections() -> list[tuple[str, list[str]]]:
    """`TodayWidgets.sections` as (section, keys), in source order."""
    text = KOTLIN.read_text(encoding="utf-8")
    start = text.index("val sections: List<Pair<Section, List<String>>> = listOf(")
    body = text[start:text.index("\n    )", start)]
    out = []
    for section, keys in re.findall(r"Section\.(\w+) to listOf\(([^)]*)\)", body, re.S):
        names = []
        for raw in (part.strip() for part in keys.split(",")):
            if not raw:
                continue
            names.append(raw.strip('"') if raw.startswith('"') else KEY_METRIC_CATALOG.get(raw, raw))
        out.append((section.lower(), names))
    return out


def kotlin_keys() -> list[str]:
    return [key for _, keys in kotlin_sections() for key in keys]


class TodayTileGalleryTests(unittest.TestCase):

    def test_both_galleries_offer_the_same_measures_in_the_same_order(self):
        swift = [key for key, _ in swift_pairs()]
        self.assertEqual(swift, kotlin_keys(),
                         "Today's tile gallery differs between the phones. Add the measure to both "
                         "TileMeasures.all (Strand/Data/TileHistory.swift) and TodayWidgets.measures "
                         "(ForgeTodayWidgets.kt), in the same place.")

    def test_both_phones_group_the_gallery_the_same_way(self):
        """The sections too, not only the measures: a measure under another heading is a different gallery."""
        swift = []
        for _, _, section in swift_rows():
            if not swift or swift[-1][0] != section:
                swift.append((section, []))
            swift[-1][1].append(section)
        swift_order = [section for section, _ in swift]
        self.assertEqual(swift_order, [section for section, _ in kotlin_sections()])
        by_section: dict[str, list[str]] = {}
        for key, _, section in swift_rows():
            by_section.setdefault(section, []).append(key)
        self.assertEqual(by_section, {section: keys for section, keys in kotlin_sections()})

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

    def test_both_phones_resolve_the_same_measures_goal(self):
        """A measure whose goal is RESOLVED rather than stored must be the same measure on both phones. If
        one side thought protein's goal came from a key, its tile would show no goal at all while the other
        showed one, from the same account — and a goal shown on one phone only is worse than none."""
        swift = (ROOT / "Strand/Data/MeasureFacts.swift").read_text(encoding="utf-8")
        body = swift[swift.index("static func resolvesItsTarget"):]
        swift_keys = re.findall(r'"([a-z0-9_]+)"', body[:body.index("\n")])
        kotlin = (ROOT / "android/app/src/main/java/com/noop/core/CoreTile.kt").read_text(encoding="utf-8")
        body = kotlin[kotlin.index("fun resolvesItsTarget"):]
        kotlin_keys = re.findall(r'"([a-z0-9_]+)"', body[:body.index("\n")])
        self.assertEqual(["protein_g"], swift_keys)
        self.assertEqual(swift_keys, kotlin_keys,
                         "the measures whose goal is resolved must be the same on both phones")

    def test_both_phones_ask_the_core_for_that_goal(self):
        """And neither may work it out: the day's goal comes from the one resolver (`FoodTargets.dayGoal`),
        which is why the Food page, the Nutrition tile and this tile cannot name three different goals."""
        apple = (ROOT / "StrandiOS/Forge/ForgeTodayWidgets.swift").read_text(encoding="utf-8")
        self.assertIn("MeasureFacts.resolvesItsTarget(forKey: key)", apple)
        self.assertIn("ForgeNutritionReading.load(repo: repo, profile: profile)?.proteinGoal", apple)
        kotlin = (ROOT / "android/app/src/main/java/com/noop/ui/forge/ForgeTodayWidgets.kt").read_text(encoding="utf-8")
        self.assertIn("CoreTile.resolvesItsTarget(catalogKey)", kotlin)
        self.assertIn("CoreDietPlan.dayGoal(", kotlin)
        core = (ROOT / "Packages/NoopCoreJNI/Sources/NoopCore/CoreDietPlan.swift").read_text(encoding="utf-8")
        self.assertRegex(core, r'case "food\.dayGoal":[\s\S]{0,2000}FoodTargets\.dayGoal\(')

    def test_android_resolves_a_days_goal_only_through_the_core(self):
        """The Kotlin `when` that held the goal order beside the Swift one is gone, and must stay gone."""
        for path in (ROOT / "android/app/src/main/java/com/noop").rglob("*.kt"):
            text = path.read_text(encoding="utf-8")
            self.assertNotIn("fun foodDayGoal", text,
                             f"{path.relative_to(ROOT)} holds a second copy of the goal order")

    def test_neither_wide_tile_draws_a_second_reading_of_the_usual(self):
        """The row-wide chart states the usual and the range in its caption, from one resolver. Android drew
        the mean a second time as a dashed rule, derived from the plotted points, while the caption read a
        longer series: two answers to one question, able to part company on screen."""
        apple = (ROOT / "StrandiOS/Forge/ForgeTodayWidgets.swift").read_text(encoding="utf-8")
        wide = apple[apple.index("private func wideChart"):]
        wide = wide[:wide.index("\n    /// ")]
        self.assertNotIn("baselineValue", wide, "the Apple wide chart passes no dashed reference")
        kotlin = (ROOT / "android/app/src/main/java/com/noop/ui/forge/ForgeTodayWidgets.kt").read_text(encoding="utf-8")
        chart = kotlin[kotlin.index("private fun WideMeasureChart"):]
        chart = chart[:chart.index("\n}")]
        self.assertIn("average = null", chart,
                      "the row-wide tile passes no mean, so no dashed rule is drawn under its caption")

    def test_neither_phone_keeps_a_colour_table_of_its_own(self):
        """WHICH colour a measure is drawn in is one decision, in the shared table. Two tables drifted:
        the iPhone drew Charge, Effort and Rest in the plain accent because its table never listed them,
        and protein in that accent where Android used the energy colour; Android drew the weight and the
        skin temperature in the sleep violet where the iPhone used amber."""
        shared = (ROOT / "Strand/Data/TileHistory.swift").read_text(encoding="utf-8")
        table = shared[shared.index("static func tint(forKey key: String) -> Tint"):]
        table = table[:table.index("\n    }")]
        named = set(re.findall(r'"([a-z0-9_]+)"', table))
        self.assertIn("recovery", named)
        self.assertIn("protein_g", named)

        apple = (ROOT / "StrandiOS/Forge/ForgeTodayWidgets.swift").read_text(encoding="utf-8")
        body = apple[apple.index("static func tint(_ key: String) -> Color"):]
        body = body[:body.index("\n    }")]
        self.assertIn("TileMeasures.tint(forKey: key)", body)
        self.assertEqual([], re.findall(r'case "([a-z0-9_]+)"', body),
                         "the Apple side maps names to colours, it does not name measures")

        kotlin = (ROOT / "android/app/src/main/java/com/noop/ui/forge/ForgeTodayWidgets.kt").read_text(encoding="utf-8")
        body = kotlin[kotlin.index("private fun measureTint(key: String): Color"):]
        body = body[:body.index("\n}")]
        self.assertIn("CoreTile.tints[key]", body)
        self.assertEqual([], [m for m in re.findall(r'"([a-z0-9_]+)"', body)
                              if m not in {"charge", "effort", "rest", "cyan", "rose", "amber", "energy"}],
                         "the Kotlin side maps names to colours, it does not name measures")

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
