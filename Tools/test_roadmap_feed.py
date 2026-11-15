"""The in-app Roadmap page's two data files: the hand-written roadmap and the generated issue feed.

Two kinds of assertion live here on purpose:

- about the SCANNERS (`check_roadmap`, `build_app_feed`): every rule has a case that fails without it;
- about the PRODUCT source: the roadmap file that actually ships must pass its own checker, and every
  icon in it must exist in the Android icon map. That is the half a path filter would silence, so it
  belongs in the `tools-python` suite, which has no path filter and runs on every push.
"""
from __future__ import annotations

import json
import sys
import unittest
from datetime import datetime, timezone
from pathlib import Path
from tempfile import TemporaryDirectory

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "Tools"))

import build_app_feed as feed  # noqa: E402
import check_roadmap as roadmap  # noqa: E402
import moderate_suggestions as moderate  # noqa: E402

NOW = datetime(2026, 11, 15, 12, 0, tzinfo=timezone.utc)


def item(**overrides) -> dict:
    base = {"id": "a-thing", "phase": "next", "title": "A thing", "line": "What it brings you.",
            "icon": "sparkles", "area": "app"}
    base.update(overrides)
    return base


def doc(*items: dict) -> dict:
    return {"schema": 1, "items": list(items)}


def issue(**overrides) -> dict:
    base = {"number": 1, "title": "Sync stops", "labels": [{"name": "bug"}], "state": "OPEN",
            "stateReason": None, "createdAt": "2026-11-10T09:00:00Z", "closedAt": None}
    base.update(overrides)
    return base


class RoadmapCheckerTest(unittest.TestCase):
    def test_a_clean_file_has_no_findings(self):
        self.assertEqual(roadmap.check(doc(item())), [])

    def test_duplicate_id_is_a_finding(self):
        findings = roadmap.check(doc(item(), item(title="Another")))
        self.assertTrue(any("appears twice" in f for f in findings), findings)

    def test_unknown_phase_and_area_are_findings(self):
        findings = roadmap.check(doc(item(phase="soon", area="mind")))
        self.assertTrue(any("phase 'soon'" in f for f in findings), findings)
        self.assertTrue(any("area 'mind'" in f for f in findings), findings)

    def test_unknown_field_is_a_finding(self):
        self.assertTrue(any("unknown field" in f for f in roadmap.check(doc(item(eta="soon")))))

    def test_over_long_title_is_a_finding(self):
        findings = roadmap.check(doc(item(title="x" * (roadmap.MAX_TITLE + 1))))
        self.assertTrue(any("characters" in f for f in findings), findings)

    def test_markdown_and_urls_are_findings(self):
        self.assertTrue(any("markdown" in f for f in roadmap.check(doc(item(line="see [here](x)")))))
        self.assertTrue(any("URL" in f for f in roadmap.check(doc(item(line="see https://x.test")))))

    def test_missing_required_field_is_a_finding(self):
        broken = item()
        del broken["icon"]
        self.assertTrue(any("icon is missing" in f for f in roadmap.check(doc(broken))))

    def test_since_belongs_to_a_now_item(self):
        self.assertEqual(roadmap.check(doc(item(phase="now", since="2026-11-01"))), [])
        findings = roadmap.check(doc(item(phase="next", since="2026-11-01")))
        self.assertTrue(any("phase 'now' item only" in f for f in findings), findings)

    def test_a_lost_id_is_a_finding_unless_allowed(self):
        findings = roadmap.check(doc(item(id="kept")), previous_ids={"kept", "dropped"})
        self.assertTrue(any("dropped" in f and "Votes hang" in f for f in findings), findings)
        self.assertEqual(roadmap.check(doc(item(id="kept")), previous_ids={"kept", "dropped"},
                                       allow_removals=True), [])

    def test_an_icon_without_an_android_counterpart_is_a_finding(self):
        findings = roadmap.check(doc(item(icon="wand.and.stars")), icons={"sparkles"})
        self.assertTrue(any("no Android counterpart" in f for f in findings), findings)
        self.assertEqual(roadmap.check(doc(item(icon="sparkles")), icons={"sparkles"}), [])

    def test_the_shipped_roadmap_passes_its_own_checker(self):
        data = roadmap.load(roadmap.ROADMAP)
        self.assertEqual(roadmap.check(data, icons=roadmap.android_icons()), [])

    def test_the_shipped_roadmap_has_an_android_icon_for_every_item(self):
        icons = roadmap.android_icons()
        if icons is None:
            self.skipTest("the Android Roadmap screen does not exist yet")
        used = {i["icon"] for i in roadmap.load(roadmap.ROADMAP)["items"]}
        self.assertEqual(used - icons, set(), "icons the Android screen cannot draw")


def released(number=12, title="A dark mode for the charts", body=None, labels=("public",),
             comments=()) -> dict:
    return {"number": number, "title": title,
            "body": body if body is not None else f"{title}\nIt would help at night.",
            "labels": [{"name": n} for n in labels],
            "comments": [{"author": {"login": a}, "body": b} for a, b in comments]}


class SuggestionsTest(unittest.TestCase):
    def test_only_released_suggestions_reach_the_file(self):
        rows = feed.suggestions([released(), released(number=13, labels=("needs-you",))], owner="DX23876")
        self.assertEqual([r["id"] for r in rows], ["s-12"])

    def test_the_detail_is_the_body_after_the_title_line(self):
        rows = feed.suggestions([released()], owner="DX23876")
        self.assertEqual(rows[0]["title"], "A dark mode for the charts")
        self.assertEqual(rows[0]["detail"], "It would help at night.")

    def test_the_reply_is_the_owners_latest_comment_and_nobody_elses(self):
        rows = feed.suggestions([released(comments=(("someone", "me too"),
                                                    ("DX23876", "Planned for the next release."),
                                                    ("other", "when?")))], owner="DX23876")
        self.assertEqual(rows[0]["reply"], "Planned for the next release.")

    def test_without_an_owner_comment_there_is_no_reply_field(self):
        rows = feed.suggestions([released(comments=(("someone", "me too"),))], owner="DX23876")
        self.assertNotIn("reply", rows[0])

    def test_a_label_carries_the_status_and_the_roadmap_link(self):
        rows = feed.suggestions([released(labels=("public", "planned", "roadmap:charge-baseline"))],
                                owner="DX23876")
        self.assertEqual(rows[0]["status"], "planned")
        self.assertEqual(rows[0]["roadmap"], "charge-baseline")

    def test_markup_and_links_are_stripped_from_the_detail_too(self):
        # The relay opens the issue with the first line as its title, so that line is not detail.
        rows = feed.suggestions([released(body="A dark mode for the charts\n"
                                               "see [here](https://x.test) and *bold*")],
                                owner="DX23876")
        self.assertEqual(rows[0]["detail"], "see here and bold")

    def test_a_body_that_does_not_repeat_the_title_keeps_all_of_itself(self):
        rows = feed.suggestions([released(body="Something else entirely.")], owner="DX23876")
        self.assertEqual(rows[0]["detail"], "Something else entirely.")

    def test_hidden_wins_over_released(self):
        self.assertEqual(feed.suggestions([released(labels=("public", "hide-in-app"))], owner="x"), [])


class ModerationTest(unittest.TestCase):
    CLEAN = '{"insulting": false, "personal_data": false, "spam": false, "off_topic": false,' \
            ' "duplicate_of": null}'

    def test_a_clean_suggestion_is_released_without_the_owner(self):
        self.assertEqual(moderate.judge("a dark mode", [], lambda _: self.CLEAN), ("release", None))

    def test_each_flag_holds_it_with_a_reason(self):
        for flag, reason in (("insulting", "insulting or hateful"), ("personal_data", "carries personal data"),
                             ("spam", "spam"), ("off_topic", "not about this app")):
            answer = json.loads(self.CLEAN)
            answer[flag] = True
            verdict, said = moderate.judge("x", [], lambda _, a=answer: json.dumps(a))
            self.assertEqual((verdict, said), ("hold", reason))

    def test_a_duplicate_is_merged_into_the_known_one(self):
        answer = json.loads(self.CLEAN)
        answer["duplicate_of"] = "s-12"
        verdict, target = moderate.judge("x", [{"id": "s-12", "title": "dark mode"}],
                                         lambda _: json.dumps(answer))
        self.assertEqual((verdict, target), ("duplicate", "s-12"))

    def test_a_duplicate_of_something_unknown_is_not_merged(self):
        answer = json.loads(self.CLEAN)
        answer["duplicate_of"] = "s-999"
        self.assertEqual(moderate.judge("x", [], lambda _: json.dumps(answer))[0], "release")

    def test_every_failure_holds_rather_than_releases(self):
        def raises(_):
            raise moderate.Held("no model key is configured")
        for ask in (lambda _: "not json", lambda _: '{"insulting": "maybe"}', lambda _: "", raises):
            verdict, reason = moderate.judge("x", [], ask)
            self.assertEqual(verdict, "hold", reason)

    def test_json_in_a_code_fence_still_parses(self):
        fenced = "```json\n" + self.CLEAN + "\n```"
        self.assertEqual(moderate.judge("x", [], lambda _: fenced), ("release", None))

    def test_text_longer_than_the_app_allows_never_reaches_the_model(self):
        def never(_):
            raise AssertionError("the model must not be asked")
        self.assertEqual(moderate.judge("x" * 501, [], never)[0], "hold")

    def test_applying_a_verdict_only_calls_gh(self):
        calls = []
        moderate.apply("o/r", 7, "release", None, run=lambda cmd, check: calls.append(cmd))
        self.assertEqual(calls[0][:4], ["gh", "issue", "edit", "7"])
        self.assertIn("public", calls[0][-1])


class AppFeedTest(unittest.TestCase):
    def test_open_bug_is_reported_and_in_progress_is_working(self):
        built = feed.build([issue(number=5), issue(number=6, labels=[{"name": "bug"},
                                                                    {"name": "in-progress"}])], now=NOW)
        self.assertEqual([(i["n"], i["status"]) for i in built["issues"]],
                         [(6, "working"), (5, "reported")])
        self.assertEqual(built["counts"], {"reported": 1, "working": 1, "fixed": 0})

    def test_non_bug_and_hidden_issues_never_reach_the_file(self):
        built = feed.build([issue(number=7, labels=[{"name": "enhancement"}]),
                            issue(number=8, labels=[{"name": "bug"}, {"name": "hide-in-app"}])], now=NOW)
        self.assertEqual(built["issues"], [])

    def test_closed_as_completed_becomes_fixed_with_its_version(self):
        built = feed.build([issue(number=9, state="CLOSED", stateReason="COMPLETED",
                                  closedAt="2026-11-14T08:00:00Z",
                                  labels=[{"name": "bug"}, {"name": "fixed-in:2.1.1"}])], now=NOW)
        self.assertEqual(built["fixed"], [{"n": 9, "title": "Sync stops", "status": "fixed",
                                           "closed": "2026-11-14", "fixedIn": "2.1.1"}])

    def test_not_planned_shows_for_thirty_days_then_goes_quiet(self):
        recent = issue(number=10, state="CLOSED", stateReason="NOT_PLANNED",
                       closedAt="2026-11-01T08:00:00Z")
        old = issue(number=11, state="CLOSED", stateReason="NOT_PLANNED",
                    closedAt="2026-09-01T08:00:00Z")
        built = feed.build([recent, old], now=NOW)
        self.assertEqual([i["n"] for i in built["decided"]], [10])
        self.assertEqual(built["fixed"], [])

    def test_only_the_five_most_recent_fixes_are_kept(self):
        issues = [issue(number=20 + n, state="CLOSED", stateReason="COMPLETED",
                        closedAt=f"2026-11-{n + 1:02d}T08:00:00Z") for n in range(8)]
        built = feed.build(issues, now=NOW)
        self.assertEqual([i["n"] for i in built["fixed"]], [27, 26, 25, 24, 23])

    def test_titles_lose_markup_links_and_control_characters(self):
        self.assertEqual(feed.sanitise("see [the log](https://x.test) \u0007now"), "see the log now")
        self.assertEqual(feed.sanitise("`sync` *stops*"), "sync stops")
        self.assertEqual(feed.sanitise("visit https://evil.test/path for the fix"), "visit for the fix")

    def test_a_long_title_is_truncated_rather_than_wrapped_forever(self):
        out = feed.sanitise("x" * 200)
        self.assertEqual(len(out), feed.MAX_TITLE)
        self.assertTrue(out.endswith("…"))

    def test_an_issue_body_never_reaches_the_file(self):
        built = feed.build([issue(number=12, body="my mail is a@b.test and my token is x")], now=NOW)
        self.assertNotIn("a@b.test", json.dumps(built))
        self.assertEqual(set(built["issues"][0]), {"n", "title", "status", "opened"})

    def test_rendering_is_deterministic_and_only_generated_moves(self):
        first = feed.build([issue()], now=NOW)
        later = feed.build([issue()], now=NOW.replace(hour=18))
        self.assertNotEqual(first["generated"], later["generated"])
        with TemporaryDirectory() as tmp:
            path = Path(tmp) / "app-feed.json"
            path.write_text(feed.render(first), encoding="utf-8")
            self.assertTrue(feed.unchanged(later, path))
            self.assertFalse(feed.unchanged(feed.build([issue(number=99)], now=NOW), path))
            self.assertEqual(feed.render(first), feed.render(feed.build([issue()], now=NOW)))

    def test_the_service_field_is_absent_until_there_is_a_service(self):
        self.assertIsNone(feed.build([issue()], now=NOW)["service"])
        self.assertEqual(feed.build([issue()], now=NOW, service="https://x.workers.dev")["service"],
                         "https://x.workers.dev")

    def test_an_unusable_service_address_fails_the_run_instead_of_shipping(self):
        """The app drops a bad address without a word, so the generator is where it must be noticed."""
        self.assertIsNone(feed.service_url(None))
        self.assertIsNone(feed.service_url("   "))
        self.assertEqual(feed.service_url(" https://x.workers.dev/ "), "https://x.workers.dev")
        for bad in ("http://x.workers.dev", "x.workers.dev", "https:///v1",
                    "https://user:pw@x.workers.dev", "https://x.workers.dev?k=1",
                    "https://x.workers.dev#f"):
            with self.subTest(bad=bad), self.assertRaises(SystemExit):
                feed.service_url(bad)

    def test_the_workflow_hands_the_service_address_to_the_generator(self):
        """PRODUCT source: the job rewrites the feed on every issue event, so an address that only sat
        in the committed file would be dropped at the next run. Losing this argument is exactly the
        change that invalidates the service field, and nothing else in the suite would see it."""
        workflow = (ROOT / ".github" / "workflows" / "app-feed.yml").read_text(encoding="utf-8")
        self.assertIn("--service \"${NOOP_SERVICE}\"", workflow)
        self.assertIn("NOOP_SERVICE: ${{ vars.NOOP_SERVICE }}", workflow)


if __name__ == "__main__":
    unittest.main()
