"""Guards against Swift standard-library APIs that only exist on iOS 26 while the app ships to iOS 17.

`EnumeratedSequence` became a `RandomAccessCollection` in the iOS 26 runtime. The compiler accepts
`ForEach(items.enumerated(), ...)` with a deployment target of iOS 17, but on iOS 17 and 18 the
conformance is missing at run time and the view crashes as soon as it renders. That is how the Settings
landing page closed the app on iOS 18 in 12.0.1 and 12.1.0. Wrap the sequence in `Array(...)` instead.
"""

from __future__ import annotations

import os
import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
APP_ROOTS = ["Strand", "StrandiOS", "StrandiOSShared", "StrandiOSWidgets", "NOOPWatch", "NOOPWatchComplications", "Packages"]
SKIP_DIRS = {".build", ".swiftpm", "DerivedData", "build"}

# A SwiftUI collection view whose data argument is a bare `.enumerated()` call. Spans line breaks so a
# multi-line `ForEach(\n    items.enumerated(),` is caught too.
BARE_ENUMERATED = re.compile(r"\b(ForEach|List|Table)\(\s*(?!Array\()[\w.\[\]()]*?\.enumerated\(\)\s*[,)]")


def swift_sources() -> list[Path]:
    files: list[Path] = []
    for root in APP_ROOTS:
        for directory, subdirs, names in os.walk(REPO_ROOT / root):
            subdirs[:] = [d for d in subdirs if d not in SKIP_DIRS]
            files.extend(Path(directory) / n for n in names if n.endswith(".swift"))
    return files


class IOSBackDeploymentTests(unittest.TestCase):
    def test_pattern_matches_the_crashing_shape(self) -> None:
        self.assertIsNotNone(BARE_ENUMERATED.search("ForEach(pages.enumerated(), id: \\.element.id) {"))
        self.assertIsNotNone(BARE_ENUMERATED.search("ForEach(\n    model.rows.enumerated(),\n    id: \\.offset"))
        self.assertIsNone(BARE_ENUMERATED.search("ForEach(Array(pages.enumerated()), id: \\.element.id) {"))
        self.assertIsNone(BARE_ENUMERATED.search("for (index, page) in pages.enumerated() {"))

    def test_no_foreach_over_bare_enumerated_sequence(self) -> None:
        sources = swift_sources()
        self.assertGreater(len(sources), 100, "found too few Swift files; the scan roots are wrong, not the code")
        offenders = []
        for path in sources:
            text = path.read_text(encoding="utf-8", errors="replace")
            for match in BARE_ENUMERATED.finditer(text):
                line = text.count("\n", 0, match.start()) + 1
                offenders.append(f"{path.relative_to(REPO_ROOT)}:{line}")
        self.assertEqual(
            offenders,
            [],
            "ForEach/List/Table over a bare .enumerated() crashes on iOS 17/18 "
            "(EnumeratedSequence is a Collection only from iOS 26). Wrap it in Array(...).",
        )

    def test_settings_view_does_not_read_open_url(self) -> None:
        # On iOS 17.5 a SettingsView that read @Environment(\.openURL) was re-evaluated about a hundred
        # times a second once a page was pushed above the hub, with openURL named as the change, and the
        # app froze on the first tap of any Settings row. The read lives in UpdateDownloadButton instead.
        text = (REPO_ROOT / "Strand/Screens/SettingsView.swift").read_text(encoding="utf-8")
        reads = [m.start() for m in re.finditer(r"@Environment\(\\\.openURL\)", text)]
        button = text.find("private struct UpdateDownloadButton")
        self.assertGreater(button, 0, "UpdateDownloadButton is gone; find where the Download button reads openURL")
        self.assertEqual(
            [r for r in reads if r < button],
            [],
            "SettingsView reads @Environment(\\.openURL) again; on iOS 17/18 that froze every Settings page. "
            "Read it in a small child view such as UpdateDownloadButton.",
        )


if __name__ == "__main__":
    unittest.main()
