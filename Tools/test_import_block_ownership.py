"""A month-wise import must write only the days its block owns, and must run the water window once.

The Health Connect import reads a month at a time since 2026-11-22, which bounds a pass that had peaked
at 2 269 462 records in memory. Two lines in that change are the ones that can LOSE a wearer's data, and
neither is reachable by any JVM test: `HealthConnectImporter.import` needs a live `HealthConnectClient`,
so every existing HealthConnect test pins a pure helper instead and the write-out path is covered by
none. Inverting either guard leaves the whole Android suite green. So they are guarded here, at the
source, which is also the leg of CI that has no path filter.

**The month boundary.** A night is keyed by the day the sleeper WOKE (`SleepSessionRecord` is bucketed on
`endTime`) while Health Connect filters a read by the record's START, and the per-day write REPLACES the
whole row (`upsertAppleDaily` is a Room `@Upsert`). A night from 23:00 on the 31st to 07:00 on the 1st is
therefore read in one month and belongs to the next. Without the ownership guard the two blocks take
turns replacing that day: whichever runs last wins, so the wearer loses either the night or the next
month's steps. `ImportBlocks` reads a night wider than it owns so the records are THERE; these guards are
what stop the wrong block writing them.

**The water window.** Imported water is a REPLACE over the last thirty days WITH zero-fill, so that a
deletion in the source app propagates. Run per block, the second block - an older month, with no keys
inside that window - writes it as zeros and erases thirty days of water. It belongs to the first block
only, which is the newest, so the window lies in its range.

Both remedies follow `HealthWriteback.sleepEntriesOwned`, which answered the same shape for the Apple
Health write-back: read wider than the window, write only the keys the window owns.
"""

import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
IMPORTER = ROOT / "android/app/src/main/java/com/noop/ingest/HealthConnectImporter.kt"
BLOCKS = ROOT / "android/app/src/main/java/com/noop/ingest/ImportBlocks.kt"


class ImportBlockOwnershipTest(unittest.TestCase):
    def setUp(self) -> None:
        self.src = IMPORTER.read_text(encoding="utf-8")
        self.blocks = BLOCKS.read_text(encoding="utf-8")

    def test_the_per_day_rows_are_written_only_by_the_block_that_owns_the_day(self) -> None:
        self.assertTrue(
            "if (window != null && !window.owns(day)) continue" in self.src,
            "The per-day write loop no longer skips days the block does not own. A night that woke on "
            "the 1st is read by BOTH the block that owns it and the previous one (whose read reaches a "
            "night further back), and the write REPLACES the whole day row - so without this the two "
            "blocks erase each other's half of that day.",
        )

    def test_the_sleep_rows_are_written_only_by_the_block_that_owns_the_night(self) -> None:
        self.assertTrue(
            "(window == null || window.owns(it.first))" in self.src,
            "The sleep-session write no longer filters by block ownership. Sessions are keyed by the "
            "wake day, so a night read in the previous month would be written there too.",
        )

    def test_a_workout_is_dropped_at_the_read_by_the_block_that_does_not_own_its_start_day(self) -> None:
        # At the READ, not the write: `workouts`, `workoutDays` and `workoutSamples` are index-parallel,
        # so a session skipped later would have to be removed from three places at once.
        self.assertTrue(
            "!window.owns(localDayKey(r.startTime, r.startZoneOffset, zone))" in self.src,
            "The exercise-session read no longer drops sessions outside the block's own days. A workout "
            "is keyed by the day it started, and the block whose read reaches back a night would file a "
            "second copy of it.",
        )

    def test_the_water_window_is_written_by_the_first_block_only(self) -> None:
        self.assertTrue(
            "if (isFirstBlock && hydrationReadOk &&" in self.src,
            "The water write is no longer gated on the first block. It is a REPLACE over thirty days "
            "with zero-fill, so an older month's block writes that window as zeros and erases the "
            "wearer's imported water.",
        )
        # The zero-fill is what makes the gate necessary; if it ever goes, this test's reason goes with it.
        self.assertIn("HydrationStore.importWindow(windowDays, hydrationMl)", self.src)

    def test_the_loop_marks_the_first_block_and_leaves_the_stamp_to_the_import(self) -> None:
        self.assertTrue("isFirstBlock = index == 0" in self.src,
                        "importAll no longer tells the first block that it is first, so either every "
                      "block runs the once-per-import work or none does.")
        self.assertTrue("stampRun = false" in self.src,
                        "importAll no longer suppresses the per-block run stamp, so the last month would "
                      "be recorded as the whole import (#1735).")

    def test_a_block_reads_a_night_wider_than_it_owns(self) -> None:
        self.assertIn("READ_LEAD_SECONDS", self.blocks)
        self.assertTrue("minusSeconds(READ_LEAD_SECONDS)" in self.blocks,
                        "A block no longer starts reading before its first owned day, so a night that "
                      "began the evening before is not read by the block that must write it.")


if __name__ == "__main__":
    unittest.main()
