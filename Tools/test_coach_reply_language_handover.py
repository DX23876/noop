#!/usr/bin/env python3
"""The coach's reply language is one fact, and on Android only the host knows it.

A Spanish wearer with the app set to Spanish was answered in English by the coach, with every line of
UI around it in Spanish (reported 2026-11-22). The coach's clause comes from `CoachReplyLanguage`,
which asked `Bundle.main.preferredLocalizations`. On Apple that is the app's own language choice. On
Android it describes an executable with no localizations in it, so it answered English for everybody,
and nothing in Kotlin handed the real language in. The core's translation table went a different way
entirely, keyed by English source text, saying nothing about which language it holds, which is why
the UI was right and the coach was wrong.

Two readouts of one fact that could disagree, which `AGENTS.md` puts first among the hard rules. The
repair is the shape it asks for: the host names the language on the SAME call that installs the
table, and both readers take it from there. This file is the gate, because nothing else can see it:
the Android path is `#if os(Android)` and no test on either platform executes it, the Swift tests run
on macOS and the Kotlin tests have no Swift core.

Standard `unittest`, discovered by `tools-python.yml` with the other Tools/ suites.
"""

from __future__ import annotations

import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent

SHADOW = ROOT / "android/app/src/main/java/com/noop/core/CoreShadow.kt"
CALL = ROOT / "Packages/NoopCoreJNI/Sources/NoopCore/CoreCall.swift"
SHIM = ROOT / "Packages/NoopCoreJNI/Sources/NoopCore/AndroidLocalizationShim.swift"
REPLY = ROOT / "Strand/AI/CoachReplyLanguage.swift"
APP_LANGUAGE = ROOT / "Strand/App/AppLanguage.swift"

#: The two ops that hand the core its language: once at startup, once when Settings changes it.
LANGUAGE_OPS = ("core.setResources", "core.setLanguage")


class CoachReplyLanguageHandoverTest(unittest.TestCase):
    def test_android_names_its_language_on_every_call_that_sets_one(self):
        """Including English, which ships no table: "no table" and "never told" must differ."""
        kotlin = SHADOW.read_text(encoding="utf-8")
        for op in LANGUAGE_OPS:
            with self.subTest(op=op):
                self.assertIn(f'"{op}"', kotlin, f"{op} is no longer called from CoreShadow")
                # The `lang` argument has to be built in the same block that makes this call, not left
                # to a caller that may or may not remember.
                head = kotlin[: kotlin.index(f'"{op}"')]
                block = head[head.rindex("fun ") :]
                self.assertIn('put("lang"', block,
                              f"{op} is sent without the wearer's language")

    def test_the_tag_comes_from_one_resolver_shared_with_the_table(self):
        kotlin = SHADOW.read_text(encoding="utf-8")
        self.assertIn("fun languageTag(", kotlin,
                      "the language is resolved per call site again; one resolver, one answer")
        # The table lookup must read that same resolver rather than asking the preferences itself.
        table = kotlin[kotlin.index("private fun localizationFile("):]
        self.assertIn("languageTag(context)", table[: table.index("\n    }")],
                      "the table resolves the language by itself and can disagree with the coach")

    def test_the_core_stores_what_the_host_named_and_cannot_be_given_a_table_without_it(self):
        shim = SHIM.read_text(encoding="utf-8")
        self.assertRegex(
            shim, r"static func load\(_ url: URL\?, language: String\?\)",
            "the core can be handed a table without being told which language it is")
        self.assertIn("static var language: String?", shim,
                      "the core keeps no language for its readers to ask for")
        call = CALL.read_text(encoding="utf-8")
        for op in LANGUAGE_OPS:
            with self.subTest(op=op):
                self.assertIn(f'"{op}"', call)
        self.assertEqual(
            call.count('language: args["lang"] as? String'), len(LANGUAGE_OPS),
            "an op installs the table without passing the language through")

    def test_the_coach_reads_the_hosts_language_on_android(self):
        reply = REPLY.read_text(encoding="utf-8")
        android = reply[reply.index("#if os(Android)"): reply.index("#else")]
        self.assertIn("CoreLocalization.language", android,
                      "the Android coach resolves its reply language by itself again")
        self.assertIn("Bundle.main.preferredLocalizations", reply.split("#else")[1],
                      "Apple must keep reading its own bundle, where that IS the app's language")

    def test_the_coach_knows_every_language_settings_offers(self):
        """The drift that hid Polish: Settings offered it, the coach had no case, nobody failed.

        `CoachLanguagePromptTests` asserts the same thing where the types are, and it runs only under
        `xcodebuild` on macOS. This runs on every push.
        """
        offered = re.findall(r'case \w+ = "([^"]+)"', APP_LANGUAGE.read_text(encoding="utf-8"))
        self.assertGreater(len(offered), 5, "premise: the app's language list was found")
        known = re.findall(r'case "([a-z]{2})":', REPLY.read_text(encoding="utf-8"))
        for tag in offered:
            with self.subTest(language=tag):
                self.assertIn(tag.split("-")[0], known,
                              f"Settings offers {tag} and the coach would answer in English")


if __name__ == "__main__":
    unittest.main()
