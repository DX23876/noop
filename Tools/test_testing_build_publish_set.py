#!/usr/bin/env python3
"""What a testing build may put in front of a tester, and what is only scaffolding.

`publish` in `fork-testing-build.yml` downloads the run's artifacts and attaches everything it finds
to the public rolling prerelease. On 2026-11-22 that was `slice-arm64.tar` and `slice-x86_64.tar`
beside the installers: 353 MB of intermediate Mach-O bundles, which exist only so the `macos` job can
lipo them together, which no tester can install, and which the release text does not mention. They
are kept for a single day on purpose, and were never meant to leave the run.

So every leg that uploads an artifact has to say which of the two it is, and the shape says it: an
artifact meant for testers is named `testing-…`, and `publish` downloads that pattern and nothing
else. This file is the gate on that, because the failure mode is invisible in a green run — the build
succeeded, the release was published, and the only symptom was two files in the asset list.

Standard `unittest`, discovered by `tools-python.yml` with the other Tools/ suites.
"""

from __future__ import annotations

import pathlib
import unittest

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
WORKFLOW = ROOT / ".github/workflows/fork-testing-build.yml"

#: The prefix an artifact carries when its contents are meant for a tester.
PUBLISHED_PREFIX = "testing-"


def _steps(job: dict) -> list[dict]:
    return [s for s in job.get("steps") or [] if isinstance(s, dict)]


class TestingBuildPublishSetTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
        cls.jobs = cls.workflow["jobs"]

    def test_publish_downloads_only_the_artifacts_meant_for_testers(self):
        """A bare `download-artifact` takes the whole run, scaffolding included."""
        downloads = [
            s for s in _steps(self.jobs["publish"])
            if "download-artifact" in str(s.get("uses", ""))
        ]
        self.assertTrue(downloads, "publish no longer downloads anything to attach")
        for step in downloads:
            pattern = (step.get("with") or {}).get("pattern")
            self.assertIsNotNone(
                pattern,
                "publish downloads every artifact of the run; name the pattern it may attach")
            self.assertTrue(
                str(pattern).startswith(PUBLISHED_PREFIX),
                f"publish attaches {pattern!r}, which is wider than the published artifacts")

    def test_every_uploaded_artifact_says_whether_it_is_for_testers(self):
        """The decision belongs to the leg that makes the file, not to whoever reads the asset list.

        Either it is named for publication, or it is scaffolding and says so by not outliving the run.
        A leg that does neither has not decided, and the two are not interchangeable: a tar of a build
        tree on a release is noise, and an installer that nothing attaches is a build nobody gets.
        """
        for name, job in self.jobs.items():
            for step in _steps(job):
                if "upload-artifact" not in str(step.get("uses", "")):
                    continue
                with self.subTest(job=name):
                    artifact = str((step.get("with") or {}).get("name", ""))
                    if artifact.startswith(PUBLISHED_PREFIX):
                        continue
                    self.assertEqual(
                        str((step.get("with") or {}).get("retention-days")), "1",
                        f"{name} uploads {artifact!r}: neither named for publication nor marked as"
                        " scaffolding with retention-days: 1")

    def test_the_publish_step_refuses_a_slice_tar_outright(self):
        """The pattern is the rule; this is the backstop for whatever a future leg calls its tar."""
        attach = [
            s for s in _steps(self.jobs["publish"])
            if "slice-" in str(s.get("run", ""))
        ]
        self.assertTrue(
            attach,
            "nothing in publish would stop a macOS slice tar reaching the release a second time")
        self.assertIn("::error::", str(attach[0]["run"]),
                      "the refusal has to fail the job, not print a note in a log nobody reads")


if __name__ == "__main__":
    unittest.main()
