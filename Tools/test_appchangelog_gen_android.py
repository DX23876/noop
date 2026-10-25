#!/usr/bin/env python3
"""The Android arm of `appchangelog-gen.py`, restored with the Android tree (Android plan D-7).

Ported from ryanbr's test file at the merge base: the #878 title key scheme, Android resource escaping,
the Kotlin block and the locale directories a title is written to. The Swift side keeps its own tests in
`test_appchangelog_gen.py`.
"""
import hashlib
import importlib.util
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
_spec = importlib.util.spec_from_file_location("acg", ROOT / "Tools/appchangelog-gen.py")
acg = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(acg)

# The 9.2.1 headline and the key it actually ships under, copied from values/strings.xml.
SHIPPED_TITLE = ("Battery saver quiets the gauges, translated Android notifications, "
                 "and instant chart loads")
SHIPPED_KEY = "l10n_app_changelog_battery_saver_quiets_the_gauges_translated_bdbe8650"


class TitleKeyTests(unittest.TestCase):

    def test_reproduces_a_key_that_is_actually_shipping(self):
        """Pinned against the real artifact, not against the function's own output."""
        self.assertEqual(SHIPPED_KEY, acg.title_key(SHIPPED_TITLE))

    def test_that_key_really_is_in_strings_xml(self):
        """If someone renames the key in the resources, this test's premise is gone — say so loudly
        rather than keep asserting against a string nothing uses."""
        xml = (ROOT / "android/app/src/main/res/values/strings.xml").read_text()
        self.assertIn(f'name="{SHIPPED_KEY}"', xml)

    def test_editing_the_title_mints_a_new_key(self):
        """The hash covers the exact title, so a reworded headline cannot silently inherit the old
        key — and with it, translations of different words."""
        self.assertNotEqual(acg.title_key(SHIPPED_TITLE), acg.title_key(SHIPPED_TITLE + " and more"))

    def test_slug_is_six_words_and_hash_is_eight_hex(self):
        key = acg.title_key("One two three four five six seven eight")
        self.assertTrue(key.startswith("l10n_app_changelog_one_two_three_four_five_six_"))
        self.assertRegex(key.rsplit("_", 1)[-1], r"^[0-9a-f]{8}$")

    def test_hash_is_of_the_title_text_itself(self):
        t = "Anything at all"
        self.assertTrue(acg.title_key(t).endswith(hashlib.sha1(t.encode()).hexdigest()[:8]))


class EscapingTests(unittest.TestCase):

    def test_apostrophe_is_backslashed_for_android(self):
        """An unescaped ' in a resource value is an aapt2 error, and release titles have them."""
        self.assertEqual(r"L\'économiseur", acg.esc_xml("L'économiseur"))

    def test_xml_entities(self):
        self.assertEqual("a &amp; b &lt;c&gt;", acg.esc_xml("a & b <c>"))

    def test_ampersand_is_escaped_before_the_others(self):
        """Escaping & last would double-escape the entities introduced by < and >."""
        self.assertEqual("&lt;a&gt; &amp; &lt;b&gt;", acg.esc_xml("<a> & <b>"))


class AndroidBlockTests(unittest.TestCase):

    WN = {"title": SHIPPED_TITLE, "date": "July 2026", "items": ["**One.** A thing."]}

    def test_kotlin_title_is_a_resource_reference(self):
        block = acg.kt_block("9.2.1", self.WN)
        self.assertIn(f"title = uiString(R.string.{SHIPPED_KEY})", block)

    def test_kotlin_title_is_not_a_literal(self):
        """The regression itself: `title = "…"` is what fails the gate."""
        block = acg.kt_block("9.2.1", self.WN)
        self.assertNotRegex(block, r'title\s*=\s*"')

    def test_items_stay_literals(self):
        self.assertIn('"**One.** A thing."', acg.kt_block("9.2.1", self.WN))


class LocaleTargetTests(unittest.TestCase):

    def test_focus_locales_match_the_resource_dirs_on_disk(self):
        """A renamed or added locale dir must not leave the generator writing into nowhere."""
        for loc, d in acg.LOCALE_DIRS.items():
            self.assertTrue((ROOT / "android/app/src/main/res" / d / "strings.xml").is_file(),
                            f"{loc} -> {d}/strings.xml is missing")

    def test_locale_dirs_match_the_res_directories(self):
        """And the OTHER direction, which is the one that has actually gone wrong twice.

        The test above only asserts that every entry points at a real directory, so ADDING a locale
        breaks nothing: `title_locales` for it is accepted, silently dropped, and those readers get the
        English card. Polish shipped in #1250 and was noticed at v10.1.0; Russian shipped in #1872 and
        would have repeated it in the release that introduced Russian.

        Only language directories count. Android config qualifiers (`values-night`, `values-w600dp`)
        live beside them and are not locales, so the match is on a language tag shape rather than on
        "anything after the dash".
        """
        res = ROOT / "android/app/src/main/res"
        on_disk = {
            d.name for d in res.iterdir()
            if d.is_dir() and re.fullmatch(r"values-[a-z]{2}(-r[A-Z]{2})?", d.name)
            and (d / "strings.xml").is_file()
        }
        declared = {d for loc, d in acg.LOCALE_DIRS.items() if loc != "en"}
        missing = sorted(on_disk - declared)
        self.assertEqual(
            [], missing,
            f"locale dir(s) with no LOCALE_DIRS entry: {missing}. A `title_locales` entry for them "
            f"would be accepted and dropped, and those readers would see the English card.",
        )

    def test_english_source_is_the_values_dir(self):
        self.assertEqual("values", acg.LOCALE_DIRS["en"])


if __name__ == "__main__":
    unittest.main()
