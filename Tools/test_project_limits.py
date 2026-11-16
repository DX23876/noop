"""The lengths a report, a reply and a wish may have.

One fact, written down three times: in the core (`ProjectService`), in the Android screens, and in the
relay's own source. The core is the authority and Kotlin only draws, so a bump in the core that nobody
carries into Kotlin is invisible until somebody types 2001 characters into a field that accepts them
and a service that does not. Nothing at runtime can notice that, which is why it is asserted here,
against the product source rather than against a copy kept in this file.

The relay is checked only when it is present: it lives in its own repository and is absent in CI.
"""
from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def swift_limits() -> dict[str, int]:
    found: dict[str, int] = {}
    for rel, names in [("Packages/StrandCore/Sources/StrandCore/ProjectReport.swift",
                        ["maximumReport", "maximumReply"]),
                       ("Packages/StrandCore/Sources/StrandCore/ProjectService.swift",
                        ["maximumSuggestion"])]:
        text = (ROOT / rel).read_text(encoding="utf-8")
        for name in names:
            match = re.search(rf"static let {name}\s*=\s*(\d+)", text)
            assert match, f"{name} is no longer declared in {rel}"
            found[name] = int(match.group(1))
    return found


def kotlin_limits() -> dict[str, int]:
    found: dict[str, int] = {}
    for rel, names in [("android/app/src/main/java/com/noop/ui/forge/ForgeProjectReport.kt",
                        ["MAX_REPORT", "MAX_REPLY"]),
                       ("android/app/src/main/java/com/noop/ui/forge/ForgeRoadmap.kt",
                        ["MAX_SUGGESTION"])]:
        path = ROOT / rel
        if not path.exists():
            continue
        text = path.read_text(encoding="utf-8")
        for name in names:
            match = re.search(rf"const val {name}\s*=\s*(\d+)", text)
            assert match, f"{name} is no longer declared in {rel}"
            found[name] = int(match.group(1))
    return found


def relay_limits() -> dict[str, int]:
    path = ROOT / "backlog/noop-relay/src/worker.js"
    if not path.exists():
        return {}
    text = path.read_text(encoding="utf-8")
    found = {}
    for name in ["MAX_REPORT", "MAX_REPLY", "MAX_SUGGESTION"]:
        match = re.search(rf"const {name}\s*=\s*(\d+)", text)
        if match:
            found[name] = int(match.group(1))
    return found


PAIRS = [("maximumReport", "MAX_REPORT"), ("maximumReply", "MAX_REPLY"),
         ("maximumSuggestion", "MAX_SUGGESTION")]


class ProjectLimitsTest(unittest.TestCase):

    def test_android_accepts_exactly_what_the_core_does(self):
        core, kotlin = swift_limits(), kotlin_limits()
        if not kotlin:
            self.skipTest("no android tree here")
        for swift_name, kotlin_name in PAIRS:
            self.assertEqual(core[swift_name], kotlin[kotlin_name],
                             f"{kotlin_name} must follow {swift_name}: a field that accepts more "
                             "than the service does is a send that fails after the typing")

    def test_the_relay_refuses_exactly_what_the_apps_allow(self):
        relay = relay_limits()
        if not relay:
            self.skipTest("the relay is its own repository and is not checked out here")
        core = swift_limits()
        for swift_name, relay_name in PAIRS:
            self.assertEqual(core[swift_name], relay[relay_name],
                             f"{relay_name} and {swift_name} disagree")


if __name__ == "__main__":
    unittest.main()
