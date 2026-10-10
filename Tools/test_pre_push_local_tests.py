#!/usr/bin/env python3
"""Pins when .githooks/pre-push demands a Tools/local-tests.sh stamp.

No CI runs StrandTests or the package tests on a push, so this hook is the only thing standing between
an untested app change and main. A hook nobody has seen refuse anything is not known to work, so each
case here runs the real script against a throwaway repository with a fabricated push line. The CI
half of the hook is switched off with NOOP_ALLOW_RED_MAIN=1, so no network or `gh` is needed.

Standard `unittest`, discovered by `tools-python.yml` alongside the other Tools/ suites.
"""

from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

HOOK = Path(__file__).resolve().parent.parent / ".githooks" / "pre-push"
ZERO = "0" * 40


class PrePushLocalTestsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self.tmp.name)
        self.env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.invalid",
                    "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.invalid",
                    "NOOP_ALLOW_RED_MAIN": "1"}
        self.git("init", "-q", "-b", "main")
        self.git("config", "core.hooksPath", "/dev/null")
        self.base = self.commit({"README.md": "base\n"})

    def tearDown(self):
        self.tmp.cleanup()

    def git(self, *args: str) -> str:
        return subprocess.run(["git", *args], cwd=self.repo, env=self.env, check=True,
                              capture_output=True, text=True).stdout.strip()

    def commit(self, files: dict[str, str]) -> str:
        for name, text in files.items():
            path = self.repo / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
            self.git("add", name)
        self.git("commit", "-q", "-m", "change")
        return self.git("rev-parse", "HEAD")

    def push(self, local: str, remote: str, **extra_env: str) -> subprocess.CompletedProcess:
        line = f"refs/heads/main {local} refs/heads/main {remote}\n"
        return subprocess.run(["bash", str(HOOK), "origin"], cwd=self.repo, input=line, text=True,
                              env={**self.env, **extra_env}, capture_output=True)

    def stamp(self, sha: str) -> None:
        tree = self.git("rev-parse", f"{sha}^{{tree}}")
        stamps = Path(self.git("rev-parse", "--git-common-dir"))
        stamps = (self.repo / stamps) if not stamps.is_absolute() else stamps
        with open(stamps / "noop-local-tests", "a") as f:
            f.write(f"{tree} 2026-10-10T00:00:00Z app\n")

    def test_docs_only_push_needs_no_stamp(self):
        head = self.commit({"docs/x.md": "doc\n"})
        self.assertEqual(self.push(head, self.base).returncode, 0)

    def test_app_change_without_stamp_is_refused(self):
        head = self.commit({"Strand/App/A.swift": "let a = 1\n"})
        result = self.push(head, self.base)
        self.assertEqual(result.returncode, 1)
        self.assertIn("Tools/local-tests.sh", result.stderr)

    def test_package_and_project_changes_need_a_stamp(self):
        pkg = self.commit({"Packages/WhoopStore/Sources/WhoopStore/X.swift": "let x = 1\n"})
        self.assertEqual(self.push(pkg, self.base).returncode, 1)
        proj = self.commit({"project.yml": "name: x\n"})
        self.assertEqual(self.push(proj, pkg).returncode, 1)

    def test_stamp_for_the_pushed_tree_lets_it_through(self):
        head = self.commit({"StrandiOS/App/B.swift": "let b = 1\n"})
        self.stamp(head)
        self.assertEqual(self.push(head, self.base).returncode, 0)

    def test_stamp_for_another_tree_does_not_count(self):
        first = self.commit({"Strand/App/A.swift": "let a = 1\n"})
        self.stamp(first)
        second = self.commit({"Strand/App/A.swift": "let a = 2\n"})
        self.assertEqual(self.push(second, self.base).returncode, 1)

    def test_deliberate_skip(self):
        head = self.commit({"NOOPWatch/C.swift": "let c = 1\n"})
        self.assertEqual(self.push(head, self.base, NOOP_SKIP_LOCAL_TESTS="1").returncode, 0)

    def test_new_branch_and_deletion_are_not_checked(self):
        head = self.commit({"Strand/App/A.swift": "let a = 1\n"})
        self.assertEqual(self.push(head, ZERO).returncode, 0)
        self.assertEqual(self.push(ZERO, head).returncode, 0)


if __name__ == "__main__":
    unittest.main()
