"""The Settings page reads `LiveState` without watching it, so a fact it prints must pass the gate.

`SettingsLiveFacts` lists what runs the page's body again. A new `live.x` on the page that is missing from the
list would still compile and would then show a stale value until something else moved, so the list is held
against the page here.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
PAGE = REPO_ROOT / "Strand/Screens/SettingsView.swift"
FACTS = REPO_ROOT / "Strand/Screens/SettingsLiveFacts.swift"

# Worked out from facts already on the list (connected, bonded, encryptedBond), or read only when a button is pressed.
NOT_ON_THE_LIST = {
    "connectionStatusLabel",
    "connectionStatusIsActive",
    "connectionStatusIsIdle",
    "exportableLogText",
}


class SettingsLiveFactsTest(unittest.TestCase):
    def test_every_live_read_on_the_page_passes_the_gate(self) -> None:
        page = PAGE.read_text(encoding="utf-8")
        code = "\n".join(line.split("//")[0] for line in page.splitlines())
        reads = set(re.findall(r"\blive\.([a-z]\w*)", code))
        self.assertGreater(len(reads), 10, "found almost no live reads; the page must have moved")
        listed = set(re.findall(r"^    let (\w+):", FACTS.read_text(encoding="utf-8"), re.M))
        self.assertEqual(
            reads - listed - NOT_ON_THE_LIST,
            set(),
            "the Settings page reads these from LiveState but SettingsLiveFacts does not list them, "
            "so they would go stale on screen",
        )

    def test_the_page_watches_neither_model_nor_live_directly(self) -> None:
        page = PAGE.read_text(encoding="utf-8")
        start = page.index("private struct SettingsPageContent")
        end = page.index("\nstruct SettingsPageDestination")
        content = page[start:end]
        self.assertNotRegex(content, r"@(EnvironmentObject|ObservedObject)\s+(private\s+)?var\s+(model|live)\b")
        self.assertIn(".equatable()", page[:start], "without it SwiftUI takes the page's StateObject closure for a change")


if __name__ == "__main__":
    unittest.main()
