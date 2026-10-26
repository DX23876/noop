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


if __name__ == "__main__":
    unittest.main()
