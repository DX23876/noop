"""Turning a reported problem into a public issue.

The properties under test are the promises the path makes, in the order they can be broken:

- nothing is published without the owner's label, and nothing twice;
- what crosses is a title and a summary, never the reporter's raw text, their code or their language;
- an unreadable model answer holds, it never guesses a title;
- a proposal is marked so it stays out of the reporter's own thread.
"""
from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "Tools"))

import publish_reports as pub  # noqa: E402
from moderate_suggestions import Held  # noqa: E402

BODY = ("Die Live-Herzfrequenz hört nach einer Neuverbindung auf.\n\n"
        "Code: 46HG-TGYN-F8UZ-DRT4\nLanguage: de")


def issue(number=7, body=BODY, labels=("bug", "from-app"), comments=()):
    return {"number": number, "title": "Die Live-Herzfrequenz", "body": body,
            "labels": [{"name": name} for name in labels], "comments": list(comments)}


class Recorder:
    """Stands in for `gh`, and records what would have been run."""

    def __init__(self, answers=None):
        self.calls: list[list[str]] = []
        self.answers = list(answers or [])

    def __call__(self, args, capture_output=True, text=True, check=True):
        self.calls.append(args)

        class Result:
            stdout = self.answers.pop(0) if self.answers else ""
        return Result()


class PublishReportsTest(unittest.TestCase):

    # MARK: What the owner reads

    def test_the_report_is_read_without_the_lines_the_relay_appended(self):
        self.assertEqual(pub.reported_text(BODY),
                         "Die Live-Herzfrequenz hört nach einer Neuverbindung auf.")
        self.assertEqual(pub.reported_text("Just this\n\nPublic: #12"), "Just this")
        self.assertEqual(pub.reported_text("Alone, no thread\n\nSent without a thread: …"),
                         "Alone, no thread")

    def test_a_quoted_code_line_does_not_cut_the_report_short(self):
        body = ("The alarm screen shows\nCode: 1234\nwhere it should show a time\n\n"
                "Code: 46HG-TGYN-F8UZ-DRT4\nLanguage: de")
        self.assertEqual(pub.reported_text(body),
                         "The alarm screen shows\nCode: 1234\nwhere it should show a time")

    def test_a_proposal_carries_the_relay_marker_so_the_reporter_never_sees_it(self):
        comment = pub.proposal_comment("Live heart rate stops after a reconnect", "It stops. Always.")
        self.assertTrue(comment.startswith(pub.RELAY_MARKER),
                        "the thread filters on this marker; without it the reporter reads the draft")
        self.assertIn("publish", comment)

    def test_a_proposal_is_read_back_out_of_its_own_comment(self):
        comment = pub.proposal_comment("Live heart rate stops", "One sentence. And a second.")
        self.assertEqual(pub.read_proposal([{"body": comment}]),
                         ("Live heart rate stops", "One sentence. And a second."))
        self.assertIsNone(pub.read_proposal([{"body": "something else entirely"}]))
        self.assertIsNone(pub.read_proposal([]))

    def test_the_newest_proposal_wins(self):
        old = pub.proposal_comment("Old title", "Old summary.")
        new = pub.proposal_comment("New title", "New summary.")
        self.assertEqual(pub.read_proposal([{"body": old}, {"body": new}])[0], "New title")

    # MARK: What the model may and may not decide

    def test_an_unreadable_answer_holds_rather_than_guesses(self):
        for bad in ["", "not json", "{}", '{"title": ""}', "[1, 2]", '{"title": "   "}']:
            with self.subTest(bad=bad), self.assertRaises(Held):
                pub.parse_draft(bad)

    def test_a_fenced_answer_still_parses_and_is_bounded(self):
        title, summary = pub.parse_draft(
            '```json\n{"title": "' + "T" * 300 + '", "summary": "' + "S" * 900 + '"}\n```')
        self.assertEqual(len(title), pub.MAX_TITLE)
        self.assertEqual(len(summary), pub.MAX_SUMMARY)

    def test_proposing_writes_a_comment_and_nothing_else(self):
        gh = Recorder()
        answer = '{"title": "Live heart rate stops after a reconnect", "summary": "It stops."}'
        result = pub.propose("owner/private", issue(), lambda _: answer, apply=True, run=gh)
        self.assertIn("proposed", result)
        self.assertEqual(len(gh.calls), 1)
        self.assertEqual(gh.calls[0][:3], ["gh", "issue", "comment"])
        self.assertNotIn("46HG-TGYN-F8UZ-DRT4", " ".join(gh.calls[0]), "the code never travels")

    def test_a_held_model_writes_nothing(self):
        gh = Recorder()

        def refuse(_):
            raise Held("the model could not be reached")
        result = pub.propose("owner/private", issue(), refuse, apply=True, run=gh)
        self.assertIn("held", result)
        self.assertEqual(gh.calls, [])

    # MARK: Publishing

    def test_publishing_needs_the_label_and_a_proposal(self):
        gh = Recorder()
        result = pub.publish("owner/private", "owner/noop", issue(), apply=True, run=gh)
        self.assertIn("held", result, "no proposal means nothing to publish")
        self.assertEqual(gh.calls, [])

    def test_publishing_sends_the_summary_and_never_the_report(self):
        comment = pub.proposal_comment("Live heart rate stops after a reconnect",
                                       "Live heart rate stops once the strap reconnects.")
        gh = Recorder(answers=["https://github.com/owner/noop/issues/123"])
        result = pub.publish("owner/private", "owner/noop",
                             issue(comments=[{"body": comment}]), apply=True, run=gh)
        self.assertEqual(result, "published as #123")

        created = gh.calls[0]
        self.assertEqual(created[:5], ["gh", "issue", "create", "-R", "owner/noop"])
        joined = " ".join(created)
        self.assertIn("Live heart rate stops once the strap reconnects.", joined)
        self.assertNotIn("Die Live-Herzfrequenz", joined, "the reporter's own words stay private")
        self.assertNotIn("46HG-TGYN-F8UZ-DRT4", joined, "and so does their code")

        written = " ".join(gh.calls[1])
        self.assertIn("Public: #123", written, "the private issue records where it went")
        self.assertIn("--remove-label", " ".join(gh.calls[2]))

    def test_a_report_is_never_published_twice(self):
        gh = Recorder()
        already = issue(body=BODY + "\nPublic: #99",
                        comments=[{"body": pub.proposal_comment("T", "S.")}])
        self.assertEqual(pub.publish("owner/private", "owner/noop", already, apply=True, run=gh),
                         "skipped: already #99")
        self.assertEqual(gh.calls, [])

    def test_a_dry_run_changes_nothing(self):
        gh = Recorder()
        comment = pub.proposal_comment("Title", "Summary.")
        result = pub.publish("owner/private", "owner/noop",
                             issue(comments=[{"body": comment}]), apply=False, run=gh)
        self.assertIn("would publish", result)
        self.assertEqual(gh.calls, [])

    # MARK: PRODUCT source: the workflow has to carry this, or it never runs

    def test_the_workflow_runs_this_script(self):
        workflow = (ROOT / ".github" / "workflows" / "app-feed.yml").read_text(encoding="utf-8")
        self.assertIn("Tools/publish_reports.py", workflow,
                      "a step nobody calls is a step that does not exist")
        self.assertIn("issues: write", workflow,
                      "creating the public issue needs more than the read permission")


if __name__ == "__main__":
    unittest.main()
