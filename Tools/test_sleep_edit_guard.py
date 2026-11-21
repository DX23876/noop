"""Correcting a night must act on the rows the night itself names, and must never go quiet.

Reported on Discord on 2026-11-21, with the strap log that proves it: a wearer opened the Sleep tab,
corrected the times, pressed save, and nothing happened. No message, no log line, and the night
unchanged on the next open.

His log named the shape without naming the bug:

    Recent 7d (my-whoop, 2026-11-02...2026-11-08): sleep=7/7
    Recent 7d (my-whoop-noop, computed, 2026-11-15...2026-11-21): sleep=6/7

Two lanes. The core builds the night from BOTH (`StoreReader.allSleepSessions`), and his recent nights
are the ones NOOP scores itself. The Android edit then looked the night's blocks up a SECOND time, by
time window, in the imported lane alone - so it found nothing, and three layers in a row swallowed that:
the empty group was dropped by a `takeIf`, the write was wrapped in `runCatching`, and no line was
written anywhere.

Both halves are guarded here, at the source, because the Compose shape is reachable by no JVM test:

1. the edit path takes the night's own blocks and never picks a lane itself;
2. every attempt ends in an outcome the screen says and the strap log records.
"""

import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
SLEEP_SCREEN = ROOT / "android/app/src/main/java/com/noop/ui/forge/ForgeSleep.kt"
SLEEP_EDITING = ROOT / "android/app/src/main/java/com/noop/ui/forge/ForgeSleepEditing.kt"
VIEW_MODEL = ROOT / "android/app/src/main/java/com/noop/ui/AppViewModel.kt"
CORE_EDIT = ROOT / "Packages/StrandCore/Sources/StrandCore/SleepNightEdit.swift"
CORE_BRIDGE = ROOT / "Packages/NoopCoreJNI/Sources/NoopCore/CoreSleepEdit.swift"

# The lane-picking reads. Correct where a SCREEN lists nights; never where an edit resolves the rows it
# is about to write, which is what made a computed night unchangeable.
LANE_READS = ("sleepSessionsUnion", "computedSleepSessionsUnion")


class SleepEditGuardTest(unittest.TestCase):
    def setUp(self):
        self.screen = SLEEP_SCREEN.read_text(encoding="utf-8")
        self.editing = SLEEP_EDITING.read_text(encoding="utf-8")
        self.view_model = VIEW_MODEL.read_text(encoding="utf-8")
        self.core = CORE_EDIT.read_text(encoding="utf-8")
        self.bridge = CORE_BRIDGE.read_text(encoding="utf-8")

    def test_the_lane_the_block_names_reaches_the_write(self):
        # The planner builds its clipped rows WITHOUT a device, so a fragment's own field is always nil:
        # reading it there compiles, looks right, and silently falls back to the owner order. The map
        # comes from the group the caller named instead. Covered by tests, and pinned here because the
        # failure is invisible - it writes the other lane's row and reports success.
        self.assertIn("preferring: lane[fragment.startTs]", self.core)
        self.assertNotIn("preferring: fragment.deviceId", self.core)
        self.assertIn("preferring: key.deviceId", self.bridge)

    def test_the_edit_path_never_picks_a_lane_itself(self):
        for read in LANE_READS:
            self.assertNotIn(read, self.editing,
                             f"{read} derives the night's rows a second time and can disagree with "
                             "what the screen drew; the night names its blocks")
            self.assertNotIn(read, self.view_model,
                             f"{read} has no business in a write path")

    def test_both_writes_take_the_night_s_own_blocks(self):
        self.assertIn("viewModel.editSleepNight(night.blocks", self.editing)
        self.assertIn("viewModel.deleteSleepNight(night.blocks", self.editing)

    def test_a_nap_is_deleted_by_its_own_row(self):
        self.assertIn("val block = nap.block", self.screen)
        self.assertIn("applyNapDelete(viewModel, context, nap, block)", self.screen)
        self.assertIn("viewModel.deleteSleepNight(listOf(block))", self.editing)

    def test_every_attempt_reaches_the_strap_log(self):
        body = self.view_model.split("private suspend fun finishSleepChange", 1)[1].split("\n    }", 1)[0]
        # Unconditional: at the function's own indent, not inside a branch. A line written only when the
        # write succeeded is exactly the log a tester could not produce.
        self.assertIn("\n        ble.externalLog(detail)\n", body,
                      "the log line must be written for a refusal too")
        self.assertIn("refused: ", body, "a refusal must say which one it was")

    def test_a_written_change_tells_the_screens(self):
        body = self.view_model.split("private suspend fun finishSleepChange", 1)[1].split("\n    }", 1)[0]
        self.assertIn("CoreShadow.noteDataChanged()", body,
                      "the write happens inside the core, so nothing else tells the Sleep tab that the "
                      "night moved; without this it draws the old times over a saved correction")

    def test_the_undo_restores_before_it_lifts_the_markers(self):
        body = self.view_model.split("suspend fun undoSleepRetirement", 1)[1].split("\n    }", 1)[0]
        restore = body.index("CoreSleepEdit.undo(")
        lift = body.index("allowSleepReDetection")
        self.assertLess(restore, lift,
                        "lifting a marker for a row that did not come back leaves the night deleted "
                        "AND re-detectable")

    def test_a_failed_undo_reaches_the_wearer(self):
        self.assertIn("forge_sl_undo_failed", self.screen,
                      "the core holds ONE retirement and only in memory, so an undo can find nothing")

    def test_the_strip_tells_the_three_cases_apart(self):
        body = self.editing.split("internal fun SleepUndoStrip", 1)[1].split("\n}", 1)[0]
        self.assertIn("offer.fromEdit", body, "a corrected night was never deleted")
        self.assertIn("writesTombstone", body,
                      "only a deleted DETECTED night carries the re-detection promise")
        self.assertIn("forge_se_deleted_suppressed", body)
        self.assertIn("onExpire", body, "the offer outlives nothing, so neither may the strip")

    def test_deleting_is_asked_for_first(self):
        # One tap on a red word recomputed the day and, on a detected night, wrote a marker that keeps it
        # from coming back. iOS has asked first since its editor shipped; Android did not ask at all.
        editor = self.editing.split("internal fun SleepEditDialog", 1)[1]
        self.assertIn("confirmingDelete = true", editor,
                      "the red word opens the question, it does not do the deleting")
        self.assertIn("forge_se_delete_q", editor)
        # And the question's copy may not promise suppression for a night that writes no marker.
        self.assertIn("night.edited", editor)
        self.assertIn("forge_se_delete_msg_suppress", editor)
        self.assertIn("forge_se_delete_nap_q", self.screen, "a nap is asked for too")

    def test_both_ends_carry_their_day(self):
        # Android could only nudge a night inside the day it was detected on, while the iPhone has
        # always edited date AND time in both rows: the same editor over the same core, with half the
        # feature missing on one side.
        editor = self.editing.split("internal fun SleepEditDialog", 1)[1]
        self.assertIn("var bedDay by remember", editor)
        self.assertIn("var wakeDay by remember", editor)
        self.assertIn("DayRow(stringResource(R.string.forge_se_asleep)", editor)
        self.assertIn("DayRow(stringResource(R.string.forge_se_woke)", editor)
        # And the save reads those days rather than deriving them from the night it started on.
        self.assertIn("val newStart = at(bedDay, bed)", editor)
        self.assertNotIn("newStart.minusDays(1)", editor,
                         "the old day arithmetic is what made a move impossible")

    def test_moving_a_night_off_its_data_is_asked_for(self):
        editor = self.editing.split("internal fun SleepEditDialog", 1)[1]
        # Both halves of the iPhone's #940 guard, from the shared rules rather than a local copy.
        self.assertIn("SleepEditGuard.autoCorrectedBed", editor)
        self.assertIn("SleepEditGuard.isDisjoint", editor)
        self.assertIn("forge_se_move_q", editor)
        self.assertIn("onSave(window.first, window.second, true)", editor,
                      "a move only goes out with the wearer's consent behind it")

    def test_the_pickers_read_the_wearer_s_own_clock(self):
        # NOOP has its own 12/24-hour setting and everything it prints goes through it. A picker that
        # asks the DEVICE instead shows 11:32 PM under a card that says 23:32: one instant, two ways,
        # one screen. Both platforms had it.
        self.assertIn("ClockPrefs.uses24Hour", self.editing)
        self.assertNotIn("DateFormat.is24HourFormat", self.editing)
        apple = (ROOT / "Strand/Screens/SleepView.swift").read_text(encoding="utf-8")
        self.assertIn("AppClock.formattingLocale", apple,
                      "a SwiftUI DatePicker asks the environment, so the sheet has to carry the setting")

    def test_the_undo_offer_outlives_the_night_s_page(self):
        # Deleting a night takes its page out of the pager. While the offer lived on that page it was
        # shown to nobody, which made the question's "you can undo" a promise nothing kept.
        self.assertIn("class SleepChangeHost", self.editing)
        self.assertIn("val changes = remember { SleepChangeHost() }", self.screen)
        self.assertIn("changes.undo?.let", self.screen)

    def test_a_refusal_reaches_the_wearer(self):
        # Every outcome maps to a sentence, and the mapping is exhaustive by its `else`.
        mapping = self.editing.split("fun sleepChangeMessage", 1)[1].split("\n}", 1)[0]
        for outcome in ("INVALID_WINDOW", "NO_OVERLAP", "WRITE_FAILED"):
            self.assertIn(outcome, mapping)
        self.assertIn("else ->", mapping)
        # And the screen actually shows it rather than dropping the message on the floor: one place takes
        # what a change left behind, so neither half can be forgotten at a call site.
        self.assertIn("problem = change.message", self.editing)
        self.assertIn("changes.accept(", self.screen)
        self.assertIn("changes.problem?.let", self.screen)
        self.assertIn("forge_sl_edit_partial", self.editing,
                      "a night only partly removed must say so, not report a whole deletion")


if __name__ == "__main__":
    unittest.main()
