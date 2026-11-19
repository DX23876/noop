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


if __name__ == "__main__":
    unittest.main()
