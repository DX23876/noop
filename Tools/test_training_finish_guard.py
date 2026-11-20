"""The strength logger's finish guard must read the draft STATE, not a captured snapshot.

Reported on Discord on 2026-11-20 and reproduced in the emulator: every tick stored, the header
counting them, the rows drawn green, and Finish answering "Mark at least one set as done to save the
workout." The strap log named it exactly:

    Training: finish refused before the core was asked - 0 exercise(s), 0 set(s), 0 ticked

The top bar was handed `::requestFinish`. A reference to a local function carries the locals it closed
over, and the one the bar kept was built on the first composition, when the draft had not loaded yet.
So the guard asked an empty draft for ever after, and the loop had no way out.

This is a shape no unit test on the JVM reaches, because it only exists inside Compose's recomposition.
So it is guarded here, at the source, where it is one line either way.
"""

import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
LOGGER = ROOT / "android/app/src/main/java/com/noop/ui/forge/ForgeTraining.kt"


class TrainingFinishGuardTest(unittest.TestCase):
    def setUp(self):
        self.source = LOGGER.read_text(encoding="utf-8")

    def test_the_top_bar_gets_a_lambda_not_a_local_function_reference(self):
        self.assertIn("onFinish = { requestFinish() }", self.source)
        self.assertNotIn("onFinish = ::", self.source,
                         "a local function reference freezes the draft it closed over")

    def test_the_guard_reads_the_state(self):
        body = self.source.split("fun requestFinish()", 1)[1].split("\n    }", 1)[0]
        self.assertIn("draft?.exercises", body)
        self.assertNotRegex(body, r"\bd\?\.exercises",
                            "the body's `d` snapshot is the value that went stale")

    def test_the_logged_shape_reads_the_state_too(self):
        body = self.source.split("fun draftShape()", 1)[1].split("\n    }", 1)[0]
        self.assertIn("draft?.exercises", body)
        self.assertNotRegex(body, r"\bd\?\.exercises",
                            "a shape read from the stale snapshot would report 0 ticked and hide the bug")


if __name__ == "__main__":
    unittest.main()
