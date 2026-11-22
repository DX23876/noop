#!/usr/bin/env python3
"""The Android language list stays what the core declares, and a translation nobody can pick fails.

`gen_app_languages.py` writes the Android enum from `AppLanguageCatalog`. The check below is the one
that matters on every push: the committed Kotlin still matches the catalogue. The rest pin the two
rules the generator exists for, both of them real:

  * Russian was translated on Android, down to the core's own `core-l10n/ru.l10n` table, and the
    picker did not offer it. A locale in the tree with no catalogue entry is now a failure, not a
    silence.
  * Traditional Chinese is offered on Apple and has no Android strings at all. It is named in the
    generated file as left out, rather than offered and then shown in the wrong language.

Standard `unittest`, discovered by `tools-python.yml` with the other Tools/ suites.
"""

from __future__ import annotations

import importlib.util
import pathlib
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent

_spec = importlib.util.spec_from_file_location("gen_app_languages", ROOT / "Tools/gen_app_languages.py")
gen = importlib.util.module_from_spec(_spec)
assert _spec.loader is not None
_spec.loader.exec_module(gen)


class GenAppLanguagesTest(unittest.TestCase):
    def test_the_committed_kotlin_matches_the_core_catalogue(self):
        """The whole point: run the generator's own check against the tree as committed."""
        argv = sys.argv
        sys.argv = ["gen_app_languages.py", "--check"]
        try:
            exit_code = gen.main()
        finally:
            sys.argv = argv
        self.assertEqual(exit_code, 0,
                         "android/…/AppLanguage.kt no longer matches AppLanguageCatalog; "
                         "run Tools/gen_app_languages.py")

    def test_the_catalogue_is_read_and_not_empty(self):
        languages = gen.catalog()
        tags = [l.tag for l in languages]
        self.assertIn("en", tags, "English is the base language and belongs in the list")
        self.assertEqual(len(tags), len(set(tags)), f"a language is declared twice: {tags}")
        for language in languages:
            self.assertTrue(language.autonym.strip(), f"{language.tag} has no autonym")
            self.assertTrue(language.english.strip(), f"{language.tag} has no English name")
            self.assertTrue(language.case_name.isidentifier(),
                            f"{language.tag} would generate the invalid case {language.case_name!r}")

    def test_english_needs_no_qualifier_and_every_other_language_has_one(self):
        for language in gen.catalog():
            if language.tag == "en":
                self.assertIsNone(language.qualifier, "English lives in res/values, not values-en")
            else:
                self.assertIsNotNone(
                    language.qualifier,
                    f"{language.tag} names no Android resource folder, so nothing can place its UI")

    def test_a_language_without_android_strings_is_named_rather_than_offered(self):
        _, missing = gen.render(gen.catalog())
        self.assertTrue(all(l.qualifier for l in missing), "English can never be the missing one")
        for language in missing:
            self.assertFalse(
                language.strings_file.is_file(),
                f"{language.tag} has strings and was left out of the picker anyway")

    def test_every_offered_language_has_the_strings_to_show_it(self):
        # One read of the catalogue: `render` returns the very objects it left out, and a second read
        # would hand back equal-looking ones that are not the same objects.
        languages = gen.catalog()
        block, missing = gen.render(languages)
        offered = [l for l in languages if l not in missing]
        self.assertGreater(len(offered), 1, "the generated list is empty")
        for language in offered:
            self.assertTrue(language.strings_file.is_file(),
                            f"{language.tag} is offered with no {language.strings_file.name}")
            self.assertIn(f'"{language.tag}"', block)

    def test_a_translated_locale_the_catalogue_does_not_know_is_a_failure(self):
        """The Russian case, in the direction that catches it: strings nobody can pick."""
        known = {l.qualifier for l in gen.catalog() if l.qualifier}
        self.assertEqual(
            sorted(gen.android_locales() - known), [],
            "a translated locale is missing from AppLanguageCatalog, so nobody can pick it")


if __name__ == "__main__":
    unittest.main()
