#!/usr/bin/env python3
"""What the mirror carries from the public issue to the private report, and what it must not."""
from __future__ import annotations

import os
import subprocess
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import mirror_reports as mirror  # noqa: E402


def priv(number=5, body="a report\nPublic: #42", labels=(), state="OPEN", reason=None):
    return {"number": number, "body": body, "labels": [{"name": n} for n in labels],
            "state": state, "stateReason": reason}


def pub(number=42, labels=(), state="OPEN", reason=None):
    return {"number": number, "labels": [{"name": n} for n in labels],
            "state": state, "stateReason": reason}


class Recorder:
    """Stands in for `subprocess.run`, so a test sees the gh calls without making any."""

    def __init__(self, stdout=""):
        self.calls: list[list[str]] = []
        self.stdout = stdout

    def __call__(self, args, capture_output=True, text=True, check=True):
        self.calls.append(list(args))
        return subprocess.CompletedProcess(args, 0, self.stdout, "")


class PublicNumberTest(unittest.TestCase):
    def test_the_line_publish_reports_writes_is_found(self) -> None:
        self.assertEqual(42, mirror.public_number("text\nPublic: #42"))
        self.assertEqual(7, mirror.public_number("Public: #7"))

    def test_a_report_that_was_never_published_has_none(self) -> None:
        self.assertIsNone(mirror.public_number("I think the Public: #42 button is broken"))
        self.assertIsNone(mirror.public_number(""))


class PlanTest(unittest.TestCase):
    def test_nothing_to_do_when_both_sides_agree(self) -> None:
        self.assertEqual(([], [], None), mirror.plan(priv(), pub()))

    def test_in_progress_travels_and_comes_back_off(self) -> None:
        self.assertEqual((["in-progress"], [], None),
                         mirror.plan(priv(), pub(labels=["in-progress"])))
        self.assertEqual(([], ["in-progress"], None),
                         mirror.plan(priv(labels=["in-progress"]), pub()))

    def test_the_version_is_copied_and_a_stale_one_replaced(self) -> None:
        self.assertEqual((["fixed-in:13.0.1"], [], None),
                         mirror.plan(priv(), pub(labels=["fixed-in:13.0.1"])))
        add, remove, _ = mirror.plan(priv(labels=["fixed-in:13.0.0"]), pub(labels=["fixed-in:13.0.1"]))
        self.assertEqual(["fixed-in:13.0.1"], add)
        self.assertEqual(["fixed-in:13.0.0"], remove)

    def test_closing_the_public_issue_closes_the_report(self) -> None:
        self.assertEqual(([], [], "completed"), mirror.plan(priv(), pub(state="CLOSED")))

    def test_not_planned_keeps_its_reason(self) -> None:
        """The app says notPlanned for this and fixed for the other, so the reason has to travel."""
        self.assertEqual(([], [], "not planned"),
                         mirror.plan(priv(), pub(state="CLOSED", reason="NOT_PLANNED")))

    def test_a_closed_report_is_reclosed_when_the_reason_changed(self) -> None:
        self.assertEqual(([], [], "completed"),
                         mirror.plan(priv(state="CLOSED", reason="NOT_PLANNED"),
                                     pub(state="CLOSED", reason="COMPLETED")))

    def test_reopening_the_public_issue_reopens_the_report(self) -> None:
        self.assertEqual(([], [], "open"), mirror.plan(priv(state="CLOSED"), pub()))

    def test_the_labels_that_are_not_ours_are_never_removed(self) -> None:
        """`bug` and `from-app` are the relay's, `published` is publish_reports'. Removing any of
        them would change the status the app shows for a reason nobody asked for."""
        add, remove, _ = mirror.plan(priv(labels=["bug", "from-app", "published"]), pub())
        self.assertEqual([], add)
        self.assertEqual([], remove)


class MirrorTest(unittest.TestCase):
    def test_a_dry_run_writes_nothing(self) -> None:
        run = Recorder()
        line = mirror.mirror("o/p", priv(), pub(state="CLOSED"), apply=False, run=run)
        self.assertEqual([], run.calls)
        self.assertIn("would", line)

    def test_applying_edits_the_private_issue_only(self) -> None:
        run = Recorder()
        mirror.mirror("o/p", priv(), pub(labels=["in-progress"]), apply=True, run=run)
        self.assertEqual(1, len(run.calls))
        self.assertEqual(["gh", "issue", "edit", "5", "-R", "o/p", "--add-label", "in-progress"],
                         run.calls[0])

    def test_closing_passes_the_reason_gh_understands(self) -> None:
        run = Recorder()
        mirror.mirror("o/p", priv(), pub(state="CLOSED", reason="NOT_PLANNED"), apply=True, run=run)
        self.assertEqual([["gh", "issue", "close", "5", "-R", "o/p", "--reason", "not planned"]],
                         run.calls)

    def test_nothing_is_written_to_the_public_repository(self) -> None:
        """The whole point of one direction: no call may name the public repository."""
        run = Recorder()
        mirror.mirror("o/p", priv(), pub(state="CLOSED", labels=["fixed-in:13.0.1"]),
                      apply=True, run=run)
        self.assertTrue(run.calls)
        for call in run.calls:
            self.assertNotIn("o/noop", call)
            self.assertIn("o/p", call)

    def test_no_comment_is_ever_written_into_the_reporter_s_thread(self) -> None:
        run = Recorder()
        for public in (pub(labels=["in-progress"]), pub(state="CLOSED"),
                       pub(state="CLOSED", reason="NOT_PLANNED")):
            mirror.mirror("o/p", priv(), public, apply=True, run=run)
        for call in run.calls:
            self.assertNotIn("comment", call)
            self.assertNotIn("--body", call)


if __name__ == "__main__":
    unittest.main()
