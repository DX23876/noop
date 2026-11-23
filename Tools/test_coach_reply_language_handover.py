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
TOOLS = ROOT / "Strand/AI/CoachTools.swift"
PROPOSAL = ROOT / "Strand/AI/PlanProposal.swift"
CATALOG = ROOT / "Packages/StrandCore/Sources/StrandCore/AppLanguageCatalog.swift"

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

    def test_the_coach_knows_every_language_the_core_offers(self):
        """The drift that hid Polish: both pickers offered it, the coach had no case, nobody failed.

        `CoachLanguagePromptTests` asserts the same thing where the types are, and it runs only under
        `xcodebuild` on macOS. This runs on every push.
        """
        offered = re.findall(r'\.init\(tag: "([^"]+)"', CATALOG.read_text(encoding="utf-8"))
        self.assertGreater(len(offered), 5, "premise: the core's language list was found")
        # Every quoted language subtag the resolver decides on, however the cases are grouped.
        reply = REPLY.read_text(encoding="utf-8")
        cases = re.findall(r'^\s*case (.+?):', reply, re.M)
        known = {code for line in cases for code in re.findall(r'"([a-z]{2})"', line)}
        for tag in offered:
            with self.subTest(language=tag):
                self.assertIn(tag.split("-")[0], known,
                              f"the core offers {tag} and the coach would answer in English")

    def test_the_coach_takes_a_languages_name_from_the_core(self):
        """The second list of names, which drifted: Polish was in one of them and not the other."""
        reply = REPLY.read_text(encoding="utf-8")
        self.assertIn("AppLanguageCatalog.language(appleCatalogCode:", reply,
                      "the resolver names languages itself again instead of asking the catalogue")
        self.assertNotRegex(
            reply, r'englishName: "(?!English")',
            "a language is named in the resolver; the catalogue is where names live")


    def test_the_clause_covers_what_the_model_writes_into_tools(self):
        """A tool argument is not a reply, and the model read the clause that way.

        The chat answered a Spanish wearer in Spanish while the card above it said "Zone 2 ride
        (easy), 45 min in Zone 2": the session's name and rationale are written into `propose_plan`,
        and nothing told the model those are read by a person too (reported 2026-11-23).
        """
        reply = REPLY.read_text(encoding="utf-8")
        clause = reply[reply.index("var promptClause"):]
        self.assertIn("tool", clause.lower(),
                      "the clause speaks only about replies, so tool text goes out in English")
        # And it is said ONCE. A schema that repeats it is the drift that left every other tool silent.
        tools = TOOLS.read_text(encoding="utf-8")
        self.assertNotIn("in the user's language", tools,
                         "a tool schema names the language itself; the clause is where that is said")

    def test_a_proposed_session_carries_a_language_free_kind(self):
        """What the wearer reads may be translated; what the app matches on may not.

        `PlanWorkoutMatcher` recognises the session someone actually did by word fragments in the
        proposal's name, English with a few German ones. Once the name follows the wearer's language,
        that is the difference between a completed session and one the app records as never happened.
        """
        proposal = PROPOSAL.read_text(encoding="utf-8")
        self.assertIn("enum SportFamily", proposal,
                      "a proposal's activity is free text only, so its language decides whether it matches")
        self.assertIn("var sportFamily: SportFamily?", proposal,
                      "the family is not stored, so it cannot be read back when the workout lands")
        tools = TOOLS.read_text(encoding="utf-8")
        self.assertIn('"sport_family"', tools, "propose_plan does not ask for the family")
        self.assertIn('"required": ["sport", "sport_family", "intent"]', tools,
                      "the family is optional for the model, so it will be omitted")

    def test_the_line_the_model_reads_is_not_translated(self):
        """The other half: `contextSummary()` feeds the model and stored memory.

        Translating it would make a remembered session read differently to the coach every time the
        wearer changed the app's language.
        """
        proposal = PROPOSAL.read_text(encoding="utf-8")
        context = proposal[proposal.index("func contextSummary()"):]
        self.assertIn("englishStem()", context.split("\n    }")[0],
                      "contextSummary builds on the translated line; the model's copy must not move")


if __name__ == "__main__":
    unittest.main()
