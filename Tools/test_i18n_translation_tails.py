#!/usr/bin/env python3
"""A translation must not end with a verbatim tail of its English source.

The shape this catches is a translation that stops mid-sentence and has the rest of the English
glued on, which is what a length-capped machine translation leaves behind::

    EN  Replace this device's data with one of your backups. This overwrites current data, so back
        up first if unsure.
    DE  Ersetze die Daten dieses Geräts durch eines deiner Backups. Dies überschreibt aktuelle
        Daten, so back up first if unsure.

Nothing else saw it. `i18n_audit.py` asks whether a key HAS a translation, and all of these do;
the Android build is happy because the XML is well formed; and a reader who does not speak English
simply loses the second half of the sentence. About sixty strings were in this state in every
Android locale (2026-11-18).

Run with::

    python3 Tools/test_i18n_translation_tails.py

Lives in `Tools/` rather than in the `i18n-coverage` workflow on purpose: this test reads PRODUCT
source (the locale files), and a path-filtered trigger that does not list them would let a later
batch move the counts without the gate ever running. `tools-python.yml` has no path filter.
"""

from __future__ import annotations

import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RES = ROOT / "android/app/src/main/res"
BASELINE = Path(__file__).resolve().parent / "i18n_tail_baseline.txt"

# A tail counts only when it is long enough to be a sentence fragment rather than a shared proper
# noun: at least four words AND at least this many characters. Both thresholds matter — "CC BY 4.0,
# Max Rubner-Institut" is four words of pure proper noun, and a cut-off clause is rarely shorter.
MIN_WORDS = 4
MIN_CHARS = 25
# Below this a translation is too short for the test to tell a tail from a borrowed term.
MIN_LENGTH = 60


def strings(path: Path) -> dict[str, str]:
    """The `<string>` entries of one values file, unescaped the way Android renders them."""
    out: dict[str, str] = {}
    for el in ET.parse(path).getroot():
        if el.tag != "string" or el.get("name") is None:
            continue
        text = "".join(el.itertext())
        out[el.get("name")] = text.replace("\\'", "'").replace('\\"', '"').replace("\\n", "\n")
    return out


def english_tail(source: str, translation: str) -> str:
    """The longest word-aligned suffix of `translation` that appears verbatim in `source`, or ""."""
    words = translation.split()
    for count in range(len(words), MIN_WORDS - 1, -1):
        candidate = " ".join(words[-count:])
        if len(candidate) >= MIN_CHARS and candidate in source:
            return candidate
    return ""


def tails(locale: Path, source: dict[str, str]) -> list[tuple[str, str]]:
    """Every (key, tail) in one locale file."""
    found = []
    for name, value in strings(locale).items():
        if name not in source or value == source[name] or len(value) < MIN_LENGTH:
            continue
        tail = english_tail(source[name], value)
        if tail:
            found.append((name, tail))
    return found


def baseline() -> dict[str, int]:
    allowed = {}
    for line in BASELINE.read_text(encoding="utf-8").splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        target, count = line.rsplit(" ", 1)
        allowed[target] = int(count)
    return allowed


class TranslationTailTests(unittest.TestCase):
    def test_no_locale_grows_its_half_translated_strings(self):
        source = strings(RES / "values/strings.xml")
        allowed = baseline()
        self.assertTrue(allowed, "the baseline file lists no locales")
        for locale in sorted(RES.glob("values-*/strings.xml")):
            target = f"{locale.parent.name}/strings.xml"
            with self.subTest(locale=target):
                self.assertIn(target, allowed,
                              f"{target} has no baseline entry; add one (counted now, ratcheting down)")
                found = tails(locale, source)
                # The message names one example, because a count alone does not tell the person
                # holding the failure which string they broke.
                example = f" e.g. {found[0][0]}: ...{found[0][1][:60]}" if found else ""
                self.assertLessEqual(
                    len(found), allowed[target],
                    f"{target}: {len(found)} translation(s) end with their English source, "
                    f"allowance is {allowed[target]}.{example}")

    def test_the_baseline_does_not_sit_above_what_is_there(self):
        """An allowance nobody lowers after a repair stops the gate from guarding that locale."""
        source = strings(RES / "values/strings.xml")
        for target, count in sorted(baseline().items()):
            locale = RES / target
            with self.subTest(locale=target):
                self.assertTrue(locale.exists(), f"{target} is in the baseline but not in the tree")
                self.assertEqual(len(tails(locale, source)), count,
                                 f"{target}: the baseline says {count}; lower it to what is left")

    def test_the_detector_sees_a_cut_off_sentence_and_not_a_shared_proper_noun(self):
        english = ("Replace this device's data with one of your backups. This overwrites current "
                   "data, so back up first if unsure.")
        cut = ("Ersetze die Daten dieses Geräts durch eines deiner Backups. Dies überschreibt "
               "aktuelle Daten, so back up first if unsure.")
        whole = ("Ersetzt die Daten dieses Geräts durch eines deiner Backups. Das überschreibt die "
                 "aktuellen Daten, sichere also vorher, wenn du unsicher bist.")
        self.assertEqual(english_tail(english, cut), "so back up first if unsure.")
        self.assertEqual(english_tail(english, whole), "")
        # Proper nouns that survive translation word for word are below the thresholds on purpose.
        names = "Source: German Nutrient Database (BLS 4.0), Max Rubner-Institut, CC BY 4.0."
        self.assertEqual(english_tail(names, "Quelle: Nährwertdatenbank, Max Rubner-Institut."), "")


if __name__ == "__main__":
    unittest.main()
