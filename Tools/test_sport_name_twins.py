"""The iPhone's sport names and the Android core's must translate the same sports by the same keys.

`Strand/Data/WorkoutSource.swift` (`localizedDisplaySport`) is app code, kept there so the string catalogue extracts
its keys; `Packages/NoopCoreJNI/Sources/NoopCore/CoreSportName.swift` is the copy Android reads. Nothing else ties
them together, so a sport added to one reads English on the other phone.
"""
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent


class SportNameTwinTests(unittest.TestCase):
    def test_both_tables_list_the_same_sports_and_keys(self):
        ios = (ROOT / "Strand/Data/WorkoutSource.swift").read_text()
        body = ios[ios.index("static func localizedDisplaySport"):ios.index("default:", ios.index("static func localizedDisplaySport"))]
        apple = {}
        for m in re.finditer(r'case "([^"]+)":\s*return String\(localized: "([^"]+)"', body):
            apple[m.group(1)] = m.group(2)
        core = (ROOT / "Packages/NoopCoreJNI/Sources/NoopCore/CoreSportName.swift").read_text()
        start = core.index("= [", core.index("static let keys"))
        table = core[start:core.index("\n    ]", start)]
        android = dict(re.findall(r'"([^"]+)": "([^"]+)"', table))
        self.assertGreater(len(apple), 10, "the iPhone's table was not found; the parse is broken, not the twins")
        self.assertEqual(apple, android)


if __name__ == "__main__":
    unittest.main()
