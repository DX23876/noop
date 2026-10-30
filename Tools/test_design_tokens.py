#!/usr/bin/env python3
"""Pins Tools/design_tokens.py (Android plan E-1): the token file and the Kotlin constants match the Swift design
system, and the values read are the ones the iOS app shows."""
import importlib.util
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
_spec = importlib.util.spec_from_file_location("design_tokens", ROOT / "Tools/design_tokens.py")
dt = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(dt)


class DesignTokensTests(unittest.TestCase):

    def setUp(self):
        self.tokens = dt.extract()

    def test_the_committed_files_match_the_swift_design_system(self):
        """The gate: a Swift token changed without regenerating leaves Android on the old value."""
        self.assertEqual(dt.TOKENS.read_text(), dt.tokens_json(self.tokens),
                         "Packages/StrandDesign/tokens.json is stale; run python3 Tools/design_tokens.py")
        self.assertEqual(dt.KOTLIN.read_text(), dt.kotlin(self.tokens),
                         "ForgeTokens.kt is stale; run python3 Tools/design_tokens.py")

    def test_light_and_dark_colours_are_read_as_written(self):
        self.assertEqual({"light": "D94A0AFF", "dark": "FF6A16FF"}, self.tokens["colors"]["StrandPalette.forgeEmber"])
        self.assertEqual({"light": "FFFFFFD9", "dark": "0D0E14CC"}, self.tokens["colors"]["StrandPalette.heroFill"])
        hex_only = self.tokens["colors"]["StrandPalette.onDarkPrimary"]
        self.assertEqual(hex_only["light"], hex_only["dark"], "a Color(hex:) token is the same in both appearances")

    def test_a_chart_style_colour_is_read_in_the_style_the_apps_start_with(self):
        """Health is what `StrandiOSApp` and `StrandApp` store when nothing was chosen; its Charge green, not
        Signature's (the fallback for an unknown stored value only)."""
        self.assertEqual({"light": "34C759FF", "dark": "30D158FF"}, self.tokens["colors"]["StrandPalette.chargeColor"])
        self.assertEqual({"light": "5856D6FF", "dark": "5E5CE6FF"}, self.tokens["colors"]["StrandPalette.restColor"])
        self.assertEqual({"light": "FF9500FF", "dark": "FF9F0AFF"}, self.tokens["colors"]["StrandPalette.effortColor"])

    def test_a_health_case_that_names_another_colour_is_resolved(self):
        """`case .health: return hSleepDeep` and `return restColor` take the colour they name."""
        colors = self.tokens["colors"]
        self.assertEqual(colors["StrandPalette.restColor"], colors["StrandPalette.restGlow"])
        self.assertIn("StrandPalette.sleepDeep", colors)
        self.assertIn("StrandPalette.zone5", colors)

    def test_the_chrome_pairs_are_tokens_under_their_public_name(self):
        """`NoopVisualStyle.ChromeHex` holds the canvas and text colours `StrandPalette.surfaceBase` and
        `textPrimary` forward to."""
        self.assertEqual({"light": "E7EBF3FF", "dark": "03050AFF"}, self.tokens["colors"]["NoopVisualStyle.canvas"])
        self.assertEqual({"light": "28313FCC", "dark": "E6EDFAC4"},
                         self.tokens["colors"]["NoopVisualStyle.secondaryText"])

    def test_dimensions_and_the_iphone_type_scale(self):
        self.assertEqual(22.0, self.tokens["dimensions"]["NoopMetrics.cardRadius"])
        self.assertEqual({"size": 28.0, "weight": 700, "rounded": True}, self.tokens["fonts"]["StrandFont.title1"])
        # The iPhone branch maps body to subheadline (15 pt); the macOS branch's 17 pt must not win.
        self.assertEqual(15.0, self.tokens["fonts"]["StrandFont.body"]["size"])

    def test_kotlin_colours_are_argb(self):
        self.assertEqual("0xFFD94A0A", dt.argb("D94A0AFF"))
        self.assertEqual("0xD9FFFFFF", dt.argb("FFFFFFD9"))

    def test_the_ios_branch_wins_and_chained_modifiers_join(self):
        lines = dt.source_lines("#if os(iOS)\n a = 1\n#else\n a = 2\n#endif\nx = Font.system(.title)\n    .weight(.bold)\n")
        self.assertIn(" a = 1", lines)
        self.assertNotIn(" a = 2", lines)
        self.assertIn("x = Font.system(.title).weight(.bold)", lines)


if __name__ == "__main__":
    unittest.main()
