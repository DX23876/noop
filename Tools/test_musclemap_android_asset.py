import json
import unittest

import musclemap_android_asset as asset


class MuscleMapAndroidAssetTests(unittest.TestCase):
    def test_committed_asset_matches_the_swift_outlines(self):
        self.assertEqual(asset.ASSET.read_text(encoding="utf-8"), asset.generate(),
                         "run python3 Tools/musclemap_android_asset.py after changing the MuscleMap outlines")

    def test_every_figure_has_muscles_and_known_slugs(self):
        doc = json.loads(asset.generate())
        slugs = set(asset.slug_raw_values().values())
        for gender in ("male", "female"):
            for side in ("front", "back"):
                parts = doc[gender][side]["parts"]
                self.assertGreater(len(parts), 10)
                self.assertTrue(all(p["slug"] in slugs for p in parts))
                self.assertTrue(all(p.get("common") or p.get("left") or p.get("right") for p in parts))

    def test_packed_arc_flags_are_split_from_the_next_number(self):
        self.assertEqual(asset.normalized("M1 2a910.025 910.025 0 0136.94-.25z"),
                         "M 1 2 a 910.025 910.025 0 0 1 36.94 -.25 z")
        self.assertEqual(asset.normalized("m0 0a.62.61 25.9 01-.36-1.03 1 1 0 1 1 2 2"),
                         "m 0 0 a .62 .61 25.9 0 1 -.36 -1.03 1 1 0 1 1 2 2")

    def test_numbers_keep_their_text(self):
        self.assertEqual(asset.normalized("M1e-3.5L-.5.25 3,4"), "M 1e-3 .5 L -.5 .25 3 4")

    def test_a_malformed_path_is_refused(self):
        with self.assertRaises(ValueError):
            asset.normalized("M1 2a1 1 0 2 1 3 4")
        with self.assertRaises(ValueError):
            asset.normalized("M1 2 3")

    def test_no_arc_in_the_asset_packs_its_flags(self):
        # Android's PathParser reads "0136.94" as one number; every flag must stand alone.
        doc = json.loads(asset.ASSET.read_text(encoding="utf-8"))
        for gender in ("male", "female"):
            for side in ("front", "back"):
                for part in doc[gender][side]["parts"]:
                    for key in ("common", "left", "right"):
                        for d in part.get(key, []):
                            self.assertEqual(d, asset.normalized(d), part["slug"])


if __name__ == "__main__":
    unittest.main()
