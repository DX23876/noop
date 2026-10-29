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
    "strength": (MORE, "ForgeStrengthPage("),
    "cardio": (MORE, "ForgeCardioPage("),
    "trainingLoad": (MORE, "ForgeTrainingLoadPage("),
    "body": (MORE, "ForgeBodyPage("),
    "energyPlan": (MORE, "MoreDest.Energy"),
    "ageless": (MORE, "ForgeAgeLessPage("),
    "rhythmAge": (MORE, "ForgeRhythmAgePage("),
    "fusedRecord": (MORE, "FusedRecordRoute("),
    "dataSources": (SETTINGS, "DataSourcesScreen("),
    "backupSync": (SETTINGS, "BackupSyncScreen("),
    "noopLimitations": (SETTINGS, "NoopLimitationsScreen("),
    "alarms": (MORE, "SmartAlarmScreen("),
    "automations": (SETTINGS, "ForgeSettingsPage.StrapActions"),
    "testCentre": (SETTINGS, "TestCentreScreen("),
    "powerSaving": (SETTINGS, "ForgeSettingsPage.BatteryRecording"),
    "settings": (MORE, "MoreDest.Settings"),
    "settingsSearch": (MORE, "SETTINGS_SEARCH_WORDS"),
    "settingsPage": (MORE_TAB, "initialPage = page"),
}
MORE_APPLE_ONLY = {
    "appleHealth": "HealthKit; Android reads Health Connect under Data Sources",
    "siriShortcuts": "Siri and App Intents",
    "shortcutsExport": "the Shortcuts app",
}
MORE_GAPS = {
    "miBand": "the Mi Fitness import screen",
}

# iOS `SettingsPage` (Strand/Screens/SettingsSearchCatalog.swift).
SETTINGS_WITNESS = {
    "profile": "Profile(", "goals": "Goals(", "strap": "Strap(", "batteryRecording": "BatteryRecording(",
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

    def test_sleep_sections(self):
        ios = swift_cases("Strand/Data/SleepLayoutPrefs.swift", "SleepSection")
        drawn = drawn_sections(SLEEP, "SleepSection")
        witness = {n: (lambda a=a: a in drawn) for n, a in SLEEP_ANDROID.items() if n not in SLEEP_GAPS}
        self.check(ios, witness, {}, SLEEP_GAPS, "Sleep")


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
