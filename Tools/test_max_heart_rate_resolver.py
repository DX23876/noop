"""#2438: the wearer's maximum heart rate is resolved in ONE place, `MaxHeartRate` in StrandAnalytics.

Effort, workout scores, zones, workout energy, the healthspan age and the coach all read that number.
It used to be written out by hand at each caller ("manual setting, else Tanaka from age"), in forms that
rounded differently, and two such copies had silently dropped the setting (#2460). Step 0 of #2438
changes what the number means, so every reader must change together, which is only safe if no reader
resolves it by itself.

`MaxHeartRateTests` (StrandAnalytics) pins the resolver. This file pins its readers, which no unit test
can see. Modelled on bartmuskala's `Tools/test_effort_hrmax_resolver.py` (bartmuskala/noop,
refactor/effort-hrmax-resolver), widened from Effort to every reader.

Scope is the Swift product source. The Kotlin analytics under `android/` are the pre-core engine that
phase E of docs/fork/android/PLAN.md retires; Android reads the maximum heart rate of the shared core
through `CoreAnalysis`, which is Swift and covered here.

Three assertions, following AGENTS.md ("assert the single resolver" rather than counting call sites):

1. No product source outside the resolver computes the age formula or merges the setting by hand.
2. Each known reader names the resolver.
3. Every exemption still matches, so the list can only shrink.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]

PRODUCT_ROOTS = (
    "Strand", "StrandiOS", "StrandiOSShared", "StrandiOSWidgets", "NOOPWatch", "NOOPWatchComplications",
    "Packages",
)

ANALYTICS = "Packages/StrandAnalytics/Sources/StrandAnalytics/"
CORE = "Packages/StrandCore/Sources/StrandCore/"

# Where the formula is supposed to be: the resolver, and the scorer that defines the formula itself.
RESOLVER_FILES = {
    ANALYTICS + "MaxHeartRate.swift",
    ANALYTICS + "StrainScorer.swift",
}

# The age formula, through a helper or as a literal, and the observed-percentile estimator.
FORMULA = re.compile(
    r"tanakaHRmax\(|tanakaMaxHR\(|estimateHRmax\(|208(?:\.0)?\s*-\s*0\.7\s*\*|220\s*-\s*age\b"
)
# "Setting if set, else something else", merged by hand.
HAND_MERGE = re.compile(r"hrMaxOverride\s*>\s*0\s*\?\s*(?:Double\()?[\w.]*hrMaxOverride")

# Known sites that are not the wearer's maximum, each with the reason. An entry that no longer matches
# fails `test_every_exemption_still_matches`.
EXEMPT = {
    # The zones' own formula entry point, kept for its callers and delegating to the scorer's formula.
    (ANALYTICS + "HRZones.swift", "func tanakaMaxHR(age: Double)"),
    (ANALYTICS + "HRZones.swift", "StrainScorer.tanakaHRmax(age: age)"),
    # The detector's last resort for an age-less profile with no HRmax passed in (every product caller
    # passes the day's value). Step 0 removes it.
    (ANALYTICS + "WorkoutDetector.swift", "StrainScorer.estimateHRmax(hrSeg.map"),
    # A classifier feature: the peak of one session, not the wearer's maximum.
    (ANALYTICS + "WorkoutTypeClassifier.swift", "StrainScorer.estimateHRmax(bpms, age: nil)"),
}

# Every reader that resolves the wearer's maximum, and how it must reach the resolver.
READERS = {
    ANALYTICS + "AnalyticsEngine.swift": "MaxHeartRate.resolve(",
    ANALYTICS + "WorkoutEnergyEstimate.swift": "MaxHeartRate.ageFormula(",
    CORE + "DailyAnalysis.swift": "MaxHeartRate.resolve(",
    CORE + "DailyAnalysis+Healthspan.swift": "MaxHeartRate.resolve(",
    CORE + "DayCycleIntelligenceIntegration.swift": "MaxHeartRate.resolve(",
    CORE + "EnergyModelRefresh.swift": "MaxHeartRate.ageFormula(",
    "Packages/NoopCoreJNI/Sources/NoopCore/CoreAnalysis.swift": "MaxHeartRate.resolve(",
    "Strand/Data/Profile.swift": "MaxHeartRate.resolve(",
    # The Today views, the live workout and the settings read it through ProfileStore, routed above.
    "Strand/Data/LiveEffort.swift": "profile.effortHRmax",
}


def _strip_comment(line: str) -> str:
    """Drop a trailing `//` comment so prose that mentions the formula is not a hit."""
    index = line.find("//")
    return line if index < 0 else line[:index]


def _product_sources() -> list[Path]:
    files: list[Path] = []
    for root in PRODUCT_ROOTS:
        base = REPO_ROOT / root
        if not base.exists():
            continue
        files.extend(p for p in base.rglob("*.swift")
                     if "/Tests/" not in p.as_posix() and "/.build/" not in p.as_posix())
    return sorted(files)


def hand_resolved_sites(text: str) -> list[tuple[int, str]]:
    """Lines that compute the formula or merge the setting by hand."""
    hits = []
    for index, raw in enumerate(text.splitlines()):
        line = _strip_comment(raw)
        if FORMULA.search(line) or HAND_MERGE.search(line):
            hits.append((index + 1, raw.strip()))
    return hits


def _exempt(relative: str, line: str) -> bool:
    return any(path == relative and marker in line for path, marker in EXEMPT)


class MaxHeartRateResolverTests(unittest.TestCase):
    def test_no_product_source_resolves_the_maximum_by_hand(self) -> None:
        offenders = []
        for path in _product_sources():
            relative = path.relative_to(REPO_ROOT).as_posix()
            if relative in RESOLVER_FILES:
                continue
            for line_no, line in hand_resolved_sites(path.read_text(encoding="utf-8")):
                if not _exempt(relative, line):
                    offenders.append(f"{relative}:{line_no}: {line}")
        self.assertEqual(
            offenders, [],
            "maximum heart rate resolved by hand. Call MaxHeartRate.resolve (or read ProfileStore.hrMax / "
            "effortHRmax) instead, so step 0 of #2438 has one place to change:\n" + "\n".join(offenders),
        )

    def test_every_reader_names_the_resolver(self) -> None:
        for relative, needle in READERS.items():
            with self.subTest(file=relative):
                text = (REPO_ROOT / relative).read_text(encoding="utf-8")
                self.assertIn(needle, text, f"{relative} resolves the maximum heart rate and must read {needle}")

    def test_every_exemption_still_matches(self) -> None:
        """An exemption whose code has moved or been routed must be deleted, not left to excuse a new site."""
        for relative, marker in EXEMPT:
            with self.subTest(file=relative, marker=marker):
                text = (REPO_ROOT / relative).read_text(encoding="utf-8")
                matched = any(marker in line for _, line in hand_resolved_sites(text))
                self.assertTrue(matched, f"stale exemption: {relative} no longer matches {marker!r}")

    # The detector itself, on fixtures, so a regex change cannot quietly blind the tests above.

    def test_detects_the_shape_that_caused_2460(self) -> None:
        src = "let effMaxHR = maxHROverride ?? (profile.age > 0 ? StrainScorer.tanakaHRmax(age: profile.age) : nil)"
        self.assertEqual(len(hand_resolved_sites(src)), 1)

    def test_detects_a_literal_formula(self) -> None:
        self.assertEqual(len(hand_resolved_sites("let m = Int((208 - 0.7 * Double(age)).rounded())")), 1)

    def test_detects_the_estimator(self) -> None:
        self.assertEqual(len(hand_resolved_sites("let x = StrainScorer.estimateHRmax([], age: a).0")), 1)

    def test_detects_a_hand_merge_without_the_formula(self) -> None:
        src = "Text(\"\\(profile.hrMaxOverride > 0 ? profile.hrMaxOverride : profile.hrMax)\")"
        self.assertEqual(len(hand_resolved_sites(src)), 1)

    def test_ignores_a_label_that_only_asks_whether_a_setting_exists(self) -> None:
        self.assertEqual(hand_resolved_sites('autoSource: hrMaxOverride > 0 ? "manual" : "tanaka"'), [])

    def test_ignores_comments(self) -> None:
        self.assertEqual(hand_resolved_sites("// maxHROverride ?? tanakaHRmax(age:) used to live here"), [])


if __name__ == "__main__":
    unittest.main()
