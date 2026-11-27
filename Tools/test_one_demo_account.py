"""One demo account, written by the core, on both phones.

Why this exists: the demo days are seeded by `DemoDataset` in the shared core, so an iPhone and an
Android emulator showing the same day show the same figures. Android also carries a Kotlin seeder of its
own (`DemoSeeder`), kept for the paired-device row on the Devices screen. Until 2026-11-19 it also seeded
the DAYS, into the same store, and both seeders refuse a store that already holds days — so it was never
a conflict, only a race, and a race decides which account the wearer gets. On screen that evening the
iPhone read HRV 67 ms over a 46-to-108 range while the emulator read 76 ms over 53 to 105, from what was
supposed to be one account.

A code comment cannot hold that shut, so this does. It runs on the `tools-python` leg, which has no path
filter, and it reads product source in two trees.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ANDROID = ROOT / "android/app/src/main/java/com/noop"


class OneDemoAccountTests(unittest.TestCase):

    def test_android_never_seeds_the_days_itself(self):
        """`DemoSeeder.seedIfEmpty` writes a second account's days. Nothing may call it."""
        callers = []
        for path in ANDROID.rglob("*.kt"):
            if path.name == "DemoSeeder.kt":
                continue
            for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
                if "DemoSeeder.seedIfEmpty" in line:
                    callers.append(f"{path.relative_to(ROOT)}:{number}")
        self.assertEqual([], callers,
                         "the demo days come from the core's DemoDataset, so both phones show the same "
                         "account; DemoSeeder is only for the paired-device row")

    def test_the_core_still_seeds_on_a_demo_build(self):
        """And the one seeder that is left must still be wired, or the demo build starts empty."""
        core_read = (ANDROID / "core/CoreRead.kt").read_text(encoding="utf-8")
        self.assertIn("ENABLE_DEMO", core_read)
        self.assertIn("seedDemo()", core_read)

    def test_the_core_seeder_refuses_a_store_that_already_has_days(self):
        """It must never overwrite a real account, which is what lets it run on every launch."""
        bridge = (ROOT / "Packages/NoopCoreJNI/Sources/NoopCore/Bridge.swift").read_text(encoding="utf-8")
        self.assertRegex(bridge, r"func seedDemo\(\)[\s\S]{0,1200}DemoDataset\.seedIfEmpty")


class OneDemoPersonTests(unittest.TestCase):
    """And one demo PERSON. The account's body lives in the profile prefs, not in the store, so each
    platform has to write its own file; the figures must still come from the one shared dataset. If either
    side were to carry its own age, height or weight, the two demo accounts would compute different calorie
    goals, different heart-rate zones and different body ages from the same history, which is the exact
    class of confusion the shared dataset was built to end."""

    def test_both_platforms_write_the_profile_from_the_shared_dataset(self):
        apple = (ROOT / "Strand/Data/DemoPerson.swift").read_text(encoding="utf-8")
        self.assertIn("DemoDataset.person(", apple)
        android = (ANDROID / "ui/DemoPerson.kt").read_text(encoding="utf-8")
        self.assertIn('SwiftCore.call("demo.person"', android)
        core_call = (ROOT / "Packages/NoopCoreJNI/Sources/NoopCore/CoreCall.swift").read_text(encoding="utf-8")
        self.assertRegex(core_call, r'case "demo\.person":[\s\S]{0,600}DemoDataset\.person\(\)')

    def test_neither_side_invents_a_body_of_its_own(self):
        """Only the shared dataset may name the figures. A literal on either side is a second person."""
        for path in [ROOT / "Strand/Data/DemoPerson.swift", ANDROID / "ui/DemoPerson.kt"]:
            source = path.read_text(encoding="utf-8")
            body = "\n".join(line.split("//")[0] for line in source.splitlines()
                             if not line.lstrip().startswith(("*", "/*", "///", "//")))
            numbers = re.findall(r"(?<![\w.])\d{2,}(?![\w.])", body)
            self.assertEqual([], numbers,
                             f"{path.relative_to(ROOT)} names a figure of its own: {numbers}")

    def test_both_platforms_refuse_a_profile_somebody_has_filled_in(self):
        apple = (ROOT / "Strand/Data/DemoPerson.swift").read_text(encoding="utf-8")
        self.assertIn("applyIfUnset", apple)
        self.assertRegex(apple, r"saidKeys\.allSatisfy\(\{ defaults\.object\(forKey: \$0\) == nil \}\)")
        # The height and the cohort, never the age or the weight: those two the app writes by itself on a
        # profile nobody has touched, so a guard built on them refuses every time.
        self.assertIn('static let saidKeys = ["profile.heightCm", "profile.sex"]', apple)
        android = (ANDROID / "ui/DemoPerson.kt").read_text(encoding="utf-8")
        self.assertIn("if (!profile.isUnset()) return false", android)
        # `ProfileStore` moved out of `SettingsScreen.kt` into its own file (Settings parity, P0).
        settings = (ANDROID / "ui/ProfileStore.kt").read_text(encoding="utf-8")
        self.assertRegex(settings, r"fun isUnset\(\): Boolean = !prefs\.contains\(KEY_HEIGHT\) && !prefs\.contains\(KEY_SEX\)")

    def test_both_platforms_actually_call_it(self):
        """A writer nothing calls leaves the demo exactly as empty as before."""
        app_model = (ROOT / "Strand/App/AppModel.swift").read_text(encoding="utf-8")
        self.assertIn("DemoPerson.applyIfUnset(to: profile)", app_model)
        main_activity = (ANDROID / "ui/MainActivity.kt").read_text(encoding="utf-8")
        self.assertIn("DemoPerson.seedIfUnset(applicationContext)", main_activity)


if __name__ == "__main__":
    unittest.main()
