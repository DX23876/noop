"""Android against iOS: every iOS screen, Settings page, Today section and Sleep section has an Android
counterpart, an Apple-only reason, or a named gap (fork, Android parity plan 2.3).

Why this exists: when ryanbr's Android Today, Sleep and Trends screens were removed for the Forge screens on the
shared core (E-3f, 2026-10), whole sections went with them (the body-clock dial, the Night detail tiles, sleep
marks, nine Today sections) and nothing noticed. The Sleep tab even listed only the cards it drew and hid the
rest. This test reads the iOS lists from the Swift source, so a new iOS case shows up here on its own, and checks
each against a witness in the Android source.

Rules:
- WITNESS: the iOS case has an Android counterpart; the given text must appear in the given Android file.
- APPLE_ONLY: no Android counterpart by design, with the reason.
- KNOWN_GAPS: not on Android yet. The list may only shrink: a gap that now has a witness must be moved to
  WITNESS, and an iOS case in none of the three fails the test.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FORGE = "android/app/src/main/java/com/noop/ui/forge"


def swift_cases(path: str, enum: str) -> list[str]:
    """The case names of a Swift enum, in source order (associated values ignored)."""
    text = (ROOT / path).read_text(encoding="utf-8")
    start = text.index(f"enum {enum}")
    body = text[start:text.index("\n}", start)]
    names: list[str] = []
    for line in body.splitlines():
        m = re.match(r"\s*case\s+(.+)", line)
        if not m or "return" in line or ":" in m.group(1).split("(")[0]:
            continue
        for part in re.split(r",\s*(?![^()]*\))", m.group(1)):
            name = re.match(r"([a-zA-Z_]\w*)", part.strip())
            if name:
                names.append(name.group(1))
    return names


def android(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


MORE = f"{FORGE}/ForgeMoreIndex.kt"
MORE_TAB = f"{FORGE}/ForgeMore.kt"
SETTINGS = f"{FORGE}/ForgeSettings.kt"
TODAY = f"{FORGE}/ForgeToday.kt"
SLEEP = f"{FORGE}/ForgeSleep.kt"

# iOS `MoreDestination` (StrandiOS/App/RootTabView.swift).
MORE_WITNESS = {
    "category": (MORE, "MoreRoute.Category"),
    "profile": (MORE_TAB, "ProfileRow("),
    "devices": (MORE_TAB, "DevicesScreen("),
    "training": (MORE, "MoreDest.Training ->"),
    "momentum": (MORE, "MoreDest.Momentum"),
    "insightsHub": (MORE, "InsightsHubScreen("),
    "intelligence": (MORE, "IntelligenceScreen("),
    "coach": (MORE, "ForgeCoachDestination("),
    "coachSettings": (SETTINGS, "ForgeSettingsPage.Coach"),
    "goalJourney": (MORE, "ForgeGoalsPage("),
    "insights": (MORE, "InsightsScreen("),
    "explore": (MORE, "TrendsExploreScreen("),
    "compare": (MORE, "CompareScreen("),
    "live": (MORE, "LiveScreen("),
    "workouts": (MORE, "WorkoutsScreen("),
    "health": (MORE, "HealthScreen("),
    "labBook": (MORE, "LabBookScreen("),
    "stress": (MORE, "StressScreen("),
    "breathe": (MORE, "BreatheScreen("),
    "intervals": (MORE, "IntervalsScreen("),
    "rhythm": (MORE, "RhythmRoute("),
    "ecg": (MORE, "ForgeEcgPage("),
    "strength": (MORE, "ForgeStrengthHub("),
    "cardio": (MORE, "ForgeCardioPage("),
    "trainingLoad": (MORE, "ForgeTrainingLoadPage("),
    "body": (MORE, "ForgeBodyPage("),
    "energyPlan": (MORE, "MoreDest.Energy"),
    "ageless": (MORE, "ForgeAgeLessPage("),
    "rhythmAge": (MORE, "ForgeRhythmAgePage("),
    "fusedRecord": (MORE, "FusedRecordRoute("),
    "dataSources": (SETTINGS, "DataSourcesScreen("),
    "backupSync": (SETTINGS, "BackupSyncSettingsPage("),
    "noopLimitations": (SETTINGS, "LimitationsSettingsPage("),
    "alarms": (MORE, "SmartAlarmScreen("),
    "automations": (SETTINGS, "ForgeSettingsPage.StrapActions"),
    "testCentre": (SETTINGS, "TestCentreScreen("),
    "powerSaving": (SETTINGS, "ForgeSettingsPage.BatteryRecording"),
    "settings": (MORE, "MoreDest.Settings"),
    "settingsSearch": (MORE, "matchingSettingsEntries("),
    "settingsPage": (MORE_TAB, "initialPage = page"),
    # iOS's Mi Band screen imports a Mi Fitness export; Android imports it under Settings › Data sources.
    "miBand": ("android/app/src/main/java/com/noop/ui/DataSourcesScreen.kt", "XiaomiBandImporter.importExport"),
}
MORE_APPLE_ONLY = {
    "appleHealth": "HealthKit; Android reads Health Connect under Data Sources",
    "siriShortcuts": "Siri and App Intents",
    "shortcutsExport": "the Shortcuts app",
}
MORE_GAPS: dict[str, str] = {}

# iOS `SettingsPage` (Strand/Screens/SettingsSearchCatalog.swift).
SETTINGS_WITNESS = {
    "roadmap": "Roadmap(", "profile": "Profile(", "goals": "Goals(", "strap": "Strap(", "batteryRecording": "BatteryRecording(",
    "strapActions": "StrapActions(", "training": "Training(", "todayTrends": "TodayTrends(",
    "notifications": "Notifications(", "coach": "Coach(", "languageUnits": "LanguageUnits(",
    "appearance": "Appearance(", "calculations": "Calculations(", "dataBackup": "DataBackup(", "help": "Help(",
    "lab": "Lab(", "about": "About(",
}
SETTINGS_APPLE_ONLY = {"siri": "Siri and App Intents"}

# iOS `TodaySection` (Strand/Data/TodayLayoutPrefs.swift): drawn in ForgeToday's section switch.
TODAY_ANDROID = {
    "coach": "COACH", "hero": "HERO", "liveSession": "LIVE_SESSION", "synthesis": "SYNTHESIS", "goals": "GOALS",
    "keyMetrics": "KEY_METRICS", "trainingLoad": "TRAINING_LOAD", "energy": "ENERGY", "workouts": "WORKOUTS",
    "heartRate": "HEART_RATE", "recoveryVitals": "RECOVERY_VITALS", "yourCards": "YOUR_CARDS",
    "menstrualCycle": "MENSTRUAL_CYCLE", "journal": "JOURNAL", "dataSources": "DATA_SOURCES",
    "addedCards": "ADDED_CARDS",
}
TODAY_GAPS: set[str] = set()
# Sections iOS's Liquid Today draws nothing for (`LiquidTodayView`): the guided session starts from the quick
# actions, Data Sources lives in Settings. Android draws nothing for them either, and says so in its switch.
TODAY_SAME_AS_IOS = {
    "liveSession": "started from the quick actions (Android: QuickAction.LiveSession)",
    "dataSources": "excluded from Liquid Today; Settings › Data & Backup",
}

# iOS `SleepSection` (Strand/Data/SleepLayoutPrefs.swift): drawn in ForgeSleep's section switch.
SLEEP_ANDROID = {
    "sleepMarks": "SLEEP_MARKS", "stages": "STAGES", "bodyClock": "BODY_CLOCK", "nightDetail": "NIGHT_DETAIL",
    "sleepDebt": "SLEEP_DEBT", "stagesVsTypical": "STAGES_VS_TYPICAL", "asleepDuration": "ASLEEP_DURATION",
}
SLEEP_GAPS: set[str] = set()


class AndroidIOSParityTest(unittest.TestCase):
    def check(self, ios: list[str], witness, apple_only: dict, gaps, label: str):
        for name in ios:
            known = name in witness or name in apple_only or name in gaps
            self.assertTrue(known, f"{label}: iOS case '{name}' has no Android witness, Apple-only reason or gap")
        for name, found in witness.items():
            self.assertIn(name, ios, f"{label}: '{name}' is no longer an iOS case; drop it here")
            self.assertTrue(found(), f"{label}: the Android counterpart of '{name}' is gone")
        for name in gaps:
            self.assertNotIn(name, witness, f"{label}: '{name}' is both a gap and witnessed")
            self.assertFalse(witness_for(label, name),
                             f"{label}: '{name}' now exists on Android; move it from the gaps to the witnesses")

    def test_more_destinations(self):
        ios = swift_cases("StrandiOS/App/RootTabView.swift", "MoreDestination")
        witness = {n: (lambda p=p, t=t: t in android(p)) for n, (p, t) in MORE_WITNESS.items()}
        self.check(ios, witness, MORE_APPLE_ONLY, MORE_GAPS, "More")

    def test_settings_pages(self):
        ios = swift_cases("Strand/Screens/SettingsSearchCatalog.swift", "SettingsPage")
        src = android(SETTINGS)
        witness = {n: (lambda t=t: f"    {t}" in src) for n, t in SETTINGS_WITNESS.items()}
        self.check(ios, witness, SETTINGS_APPLE_ONLY, set(), "Settings")

    def test_today_sections(self):
        ios = swift_cases("Strand/Data/TodayLayoutPrefs.swift", "TodaySection")
        drawn = drawn_sections(TODAY, "TodaySection")
        witness = {n: (lambda a=a: a in drawn) for n, a in TODAY_ANDROID.items()
                   if n not in TODAY_GAPS and n not in TODAY_SAME_AS_IOS}
        self.check(ios, witness, TODAY_SAME_AS_IOS, TODAY_GAPS, "Today")
        self.assertIn("QuickAction.LiveSession", android(TODAY), "the guided session lost its quick action")

    def test_dashboard_styles(self):
        ios = swift_cases("Strand/Data/TodayDashboardStyle.swift", "TodayDashboardStyle")
        src = android(f"{FORGE}/ForgeDashboards.kt")
        # Read the OFFERED list, not the whole file: every section raw ("overview", "focus", …) is a
        # string in here too, so a file-wide search would witness a style nobody can choose.
        offered = re.search(r"val STYLES = listOf\(([^)]*)\)", src)
        self.assertIsNotNone(offered, "DashboardStylePrefs.STYLES is gone; this gate reads it by name")
        styles = offered.group(1)
        witness = {n: (lambda t=t: t in styles) for n, t in STYLE_ANDROID.items()}
        self.check(ios, witness, STYLE_APPLE_ONLY, set(), "Dashboard style")
        for name in STYLE_APPLE_ONLY:
            self.assertNotIn(f'"{name}"', styles,
                             f"Dashboard style: '{name}' is offered on Android again. Either it draws a "
                             f"screen of its own here now, and belongs in STYLE_ANDROID, or the "
                             f"Apple-only reason above is stale")
        self.assertIn("ForgeClassicToday(", android(f"{FORGE}/ForgeRoot.kt"), "Classic Today is not mounted")
        self.assertIn("ForgeStyledDashboard(", android(TODAY), "the Trends style is not mounted")

    def test_sleep_sections(self):
        ios = swift_cases("Strand/Data/SleepLayoutPrefs.swift", "SleepSection")
        drawn = drawn_sections(SLEEP, "SleepSection")
        witness = {n: (lambda a=a: a in drawn) for n, a in SLEEP_ANDROID.items() if n not in SLEEP_GAPS}
        self.check(ios, witness, {}, SLEEP_GAPS, "Sleep")

    def test_today_first_widget_set(self):
        """Both Today screens start a new install with the same six measure tiles, in the same order.

        The set is seeded once per install, so a tile missing here is missing for good unless the wearer
        goes looking in the gallery. Android shipped five of iOS's six: stress was left out with a comment
        saying Android had no tile for it, and nothing failed when one was built. The keys differ by
        namespace (Android stores a `KeyMetric` raw where iOS stores the catalog key), so the table below
        is the translation, and an iOS key that is not in it fails rather than passing unseen.
        """
        swift = (ROOT / "Strand/Forge/ForgeTodayTileSeed.swift").read_text(encoding="utf-8")
        m = re.search(r"static let firstSet = \[([^\]]*)\]", swift)
        self.assertIsNotNone(m, "iOS's seeded widget list is gone; this gate reads it by name")
        ios = [k.strip().strip('"') for k in m.group(1).split(",")]
        kotlin = android(f"{FORGE}/ForgeTodayWidgets.kt")
        first = re.search(r"val firstSet: List<TodayWidget> = listOf\((.*?)\)\s*\n\s*\.map", kotlin, re.S)
        self.assertIsNotNone(first, "Android's firstSet is gone; this gate reads it by name")
        android_keys = [t.strip() for t in first.group(1).split(",") if t.strip()]
        self.assertEqual([FIRST_SET_ANDROID.get(k, k) for k in android_keys], ios,
                         "the seeded Today tiles differ between the platforms")

    def test_today_widget_kinds(self):
        """Every kind of Today widget iOS offers can be placed on Android too.

        The sibling of the seeded-set gate above, for the cards rather than the measures: the twenty kinds
        agree today, and a kind added on one side only would otherwise be noticed by whoever happened to
        compare the two gallery screens.
        """
        swift = (ROOT / "StrandiOS/Forge/ForgeTodayWidgets.swift").read_text(encoding="utf-8")
        start = swift.index("enum Kind: String, Codable, CaseIterable {")
        body = swift[start:swift.index("}", start)]
        ios = [c.strip() for line in body.splitlines() if line.strip().startswith("case ")
               for c in line.strip()[len("case "):].split(",")]
        self.assertGreaterEqual(len(ios), 20, "iOS's widget kinds did not parse; this gate reads them by name")
        kotlin = android(f"{FORGE}/ForgeTodayWidgets.kt")
        # The entries alone. Read to the end of the file instead and this gate goes quietly false-green: the
        # same pattern picks up `o.optString("kind")` and its siblings further down, so four JSON keys would
        # stand in as witnesses, and the next kind whose name happens to match a stored key would pass while
        # Android could not draw the card. Bounded twice, so neither the companion object nor a reformat that
        # drops the `;` can widen it again.
        tail = kotlin[kotlin.index("enum class Kind(val raw: String) {"):]
        entries = tail[:tail.index("\n    }")].split("companion object", 1)[0]
        raws = set(re.findall(r'\w+\("(\w+)"\)', entries))
        for name in ios:
            self.assertIn(name, raws, f"Today widget kind '{name}' is on iOS and not on Android")

    def test_release_notes_render_their_markup(self):
        """Both What's New sheets must render the entries' markup, not print it.

        Every changelog item is written `**Lead.** rest`. iOS renders it by handing the string to
        `LocalizedStringKey`; Android printed the asterisks on the card for one release after the Apple
        side was fixed, which is what a reader saw first after updating. The Kotlin side now goes through
        `parseInline`. Neither call shape is reachable from the other's test suite, so the gate reads both.
        """
        swift = (ROOT / "Strand/Screens/WhatsNewView.swift").read_text(encoding="utf-8")
        self.assertIn("Text(LocalizedStringKey(item))", swift,
                      "iOS stopped rendering release items as markup; the asterisks are back on the card")
        kotlin = android("android/app/src/main/java/com/noop/ui/WhatsNewSheet.kt")
        self.assertIn("parseInline(item, ", kotlin,
                      "Android stopped rendering release items as markup; the asterisks are back on the card")
        self.assertIn("parseInline(release.title, ", kotlin,
                      "Android stopped rendering the release title as markup")


# Android's seeded Today tiles, as the keys iOS stores them under: Android holds a `KeyMetric` raw where
# iOS holds the shared catalog key (`KeyMetric.catalogKey()` is the same translation in Kotlin), and the two
# measures that are not a KeyMetric carry the catalog key on both sides.
FIRST_SET_ANDROID = {
    "KeyMetric.HRV.raw": "hrv",
    "KeyMetric.RESTING_HR.raw": "rhr",
    "KeyMetric.STEPS.raw": "steps",
    "KeyMetric.WEIGHT.raw": "weight",
    "TodayWidget.SLEEP_KEY": "sleep_total_min",
    "TodayWidget.STRESS_KEY": "stress",
}

# iOS `TodayDashboardStyle` (Strand/Data/TodayDashboardStyle.swift): offered under Settings > Dashboard style.
STYLE_ANDROID = {"classic": '"classic"', "liquid": '"liquid"', "trends": '"trends"'}
# Overview is Apple-only on purpose (decided 2026-11-15, docs/fork/decisions.md). On Apple it is its own
# screen (OverviewDashboardView) with its own health-card and focus-slot preferences; on Android it drew
# the same Forge Today as Liquid, down to the default order, so it was a second name for one screen and
# part of why one wearer read two Effort figures (#41). The loop in test_dashboard_styles fails if it is
# offered here again, so this reason cannot go quietly stale.
STYLE_APPLE_ONLY = {"overview": "its own screen on Apple; on Android it duplicated Liquid"}


def drawn_sections(path: str, enum: str) -> set[str]:
    """The sections a Forge screen's `when (section)` switch draws."""
    return set(re.findall(rf"{enum}\.([A-Z_]+)\s*(?:->|,\s*{enum}\.)", android(path)))


def witness_for(label: str, name: str) -> bool:
    if label == "Today":
        return TODAY_ANDROID[name] in drawn_sections(TODAY, "TodaySection")
    if label == "Sleep":
        return SLEEP_ANDROID[name] in drawn_sections(SLEEP, "SleepSection")
    return False


if __name__ == "__main__":
    unittest.main()
