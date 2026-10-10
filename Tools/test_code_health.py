#!/usr/bin/env python3
"""Pins the measuring rules of code_health.py.

The code-health report compares each run against the previous one, so a silent change in how a line
or a type is counted would show up as a trend that never happened. These tests fix the rules on small
Swift snippets; a deliberate rule change has to update them and bump METHOD_VERSION together.

Standard `unittest`, discovered by `tools-python.yml` alongside the other Tools/ suites. No git needed.
"""

from __future__ import annotations

import unittest

import code_health as ch


def swift(path: str, src: str) -> ch.SwiftFile:
    return ch.SwiftFile(path, src)


class LexerTests(unittest.TestCase):
    def test_comments_are_not_code_lines(self):
        src = "// header\n\nlet a = 1 // trailing\n/* block\n still block */\nlet b = 2\n"
        masked, lines = ch.scan_swift(src)
        self.assertEqual(lines, {3, 6})
        self.assertNotIn("header", masked)
        self.assertNotIn("block", masked)
        self.assertEqual(len(masked), len(src))

    def test_nested_block_comment(self):
        _, lines = ch.scan_swift("/* a /* b */ still */\nlet x = 1\n")
        self.assertEqual(lines, {2})

    def test_strings_are_blanked_but_count_as_code(self):
        src = 'let s = "{ not a brace // not a comment }"\nlet t = """\n  { inside }\n  """\n'
        masked, lines = ch.scan_swift(src)
        self.assertNotIn("{", masked)
        self.assertEqual(lines, {1, 2, 3, 4})

    def test_interpolation_with_nested_string(self):
        masked, _ = ch.scan_swift('let s = "a \\(f("}")) b"\nstruct A {}\n')
        self.assertEqual(masked.count("{"), 1)
        self.assertEqual(masked.count("}"), 1)

    def test_raw_string_keeps_quotes_inside(self):
        masked, _ = ch.scan_swift('let r = #"say "hi" { "#\nstruct B {}\n')
        self.assertEqual(masked.count("{"), 1)

    def test_escaped_quote(self):
        masked, _ = ch.scan_swift('let e = "a \\" {"\nstruct C {}\n')
        self.assertEqual(masked.count("{"), 1)


class DeclarationTests(unittest.TestCase):
    def test_types_extensions_and_nesting(self):
        f = swift("Strand/A.swift", (
            "import struct Foundation.Date\n"
            "final class Model: ObservableObject {\n"
            "    @Published var a = 1\n"
            "    class func make() -> Model { Model() }\n"
            "    struct Inner { let x = 1 }\n"
            "}\n"
            "extension Model {\n"
            "    func go() {}\n"
            "}\n"
            "struct Screen<T: Equatable>: View where T: Hashable {\n"
            "    var body: some View { Text(\"\") }\n"
            "}\n"))
        names = [(d["kind"], d["qualified"]) for d in f.decls]
        self.assertEqual(names, [("class", "Model"), ("struct", "Model.Inner"), ("extension", "Model"),
                                 ("struct", "Screen")])
        types = ch.analyse_types([f])
        self.assertEqual(types["Model"]["blocks"], 2)
        self.assertEqual(types["Model"]["code"], 5 + 3)
        self.assertTrue(types["Model"]["observable_object"])
        self.assertTrue(types["Screen"]["is_view"])
        self.assertFalse(types["Model"]["is_view"])

    def test_inheritance_clause(self):
        self.assertEqual(ch.inheritance("<T: P>: View, Sendable where T: Q "), ["View", "Sendable"])
        self.assertEqual(ch.inheritance(" "), [])
        self.assertEqual(ch.inheritance(": SwiftUI.View"), ["SwiftUI.View"])

    def test_view_modifier_is_not_a_view(self):
        f = swift("Strand/M.swift", "struct Glow: ViewModifier {\n func body(content: Content) -> some View { content }\n}\n")
        self.assertFalse(ch.analyse_types([f])["Glow"]["is_view"])


class FanoutTests(unittest.TestCase):
    def test_observable_object_observers(self):
        model = swift("Strand/Store.swift", (
            "final class Store: ObservableObject {\n  @Published var a = 0\n  @Published var b = 0\n}\n"))
        views = swift("Strand/Views.swift", (
            "struct One: View {\n  @EnvironmentObject var store: Store\n  var body: some View { EmptyView() }\n}\n"
            "struct Two: View {\n  @StateObject private var store = Store()\n  var body: some View { EmptyView() }\n}\n"
            "struct Three: View {\n  @ObservedObject var s: Store\n  @ObservedObject var t: Store\n"
            "  var body: some View { EmptyView() }\n}\n"))
        types = ch.analyse_types([model, views])
        oo, ob = ch.analyse_fanout([model, views], types)
        self.assertEqual(ob, [])
        row = oo[0]
        self.assertEqual((row["name"], row["published"], row["observers"], row["sites"]), ("Store", 2, 3, 4))

    def test_observable_macro_observers(self):
        model = swift("Strand/Obs.swift", (
            "@Observable\n@MainActor\nfinal class Feed {\n  var a = 0\n  var b: Int { a + 1 }\n"
            "  @ObservationIgnored var c = 0\n  func f() { var local = 1; local += 1 }\n}\n"))
        views = swift("Strand/FeedViews.swift", (
            "struct A: View {\n  @Environment(Feed.self) private var feed\n  var body: some View { EmptyView() }\n}\n"
            "struct B: View {\n  @State private var feed = Feed()\n  var body: some View { EmptyView() }\n}\n"
            "struct C: View {\n  @Bindable var feed: Feed\n  var body: some View { EmptyView() }\n}\n"
            "struct D: View {\n  let feed: Feed\n  var body: some View { EmptyView() }\n}\n"))
        types = ch.analyse_types([model, views])
        _, ob = ch.analyse_fanout([model, views], types)
        row = ob[0]
        self.assertEqual(row["name"], "Feed")
        self.assertEqual(row["vars_estimate"], 1)
        self.assertEqual((row["env"], row["state"], row["bindable"], row["property"], row["observers"]),
                         (1, 1, 1, 1, 4))


class PathAndRiskTests(unittest.TestCase):
    def test_product_paths(self):
        self.assertTrue(ch.is_product_swift("Strand/App/AppModel.swift"))
        self.assertTrue(ch.is_product_swift("Packages/WhoopStore/Sources/WhoopStore/Reads.swift"))
        self.assertFalse(ch.is_product_swift("Packages/WhoopStore/Tests/WhoopStoreTests/X.swift"))
        self.assertFalse(ch.is_product_swift("StrandTests/FooTests.swift"))
        self.assertFalse(ch.is_product_swift("Tools/SleepBench/main.swift"))
        self.assertFalse(ch.is_product_swift("Vendor/Nomic/x.swift"))
        self.assertFalse(ch.is_product_swift("Packages/WhoopStore/Package.swift"))
        self.assertTrue(ch.is_test_path("StrandiOSTests/A.swift"))

    def test_risk_markers_ignore_comments_and_strings(self):
        f = swift("Strand/R.swift", (
            "let a = try! x()\nlet b = y as! Z\nfatalError(\"no\")\n"
            "// try! in a comment\nlet s = \"as! in a string\"\n"))
        self.assertEqual(ch.analyse_risk([f]),
                         [{"file": "Strand/R.swift", "try!": 1, "as!": 1, "fatalError": 1, "total": 3}])

    def test_deliberate_deletions(self):
        self.assertIsNotNone(ch.deliberate_reason("android/app/src/Main.kt"))
        self.assertIsNotNone(ch.deliberate_reason("Tools/parity_ledger.py"))
        self.assertIsNone(ch.deliberate_reason("Strand/Screens/TrainingLoadCard.swift"))


class GitParsingTests(unittest.TestCase):
    def test_name_only_log_counts_each_commit_once(self):
        log = "\x00\n\na.swift\nb.swift\n\x00\n\na.swift\na.swift\n"
        self.assertEqual(ch.parse_name_only_log(log), {"a.swift": 2, "b.swift": 1})

    def test_name_status_and_numstat(self):
        self.assertEqual(ch.parse_name_status("M\tx.swift\nD\tandroid/a.kt\n"),
                         {"x.swift": "M", "android/a.kt": "D"})
        self.assertEqual(ch.parse_numstat("3\t4\tx.swift\n-\t-\timg.png\n"), {"x.swift": 7, "img.png": 0})


class DocDriftTests(unittest.TestCase):
    MAIN = {"Strand/App/AppModel.swift", "docs/fork/decisions.md", "StrandiOS/App/RootTabView.swift"}
    UP = {"android/app/src/Foo.kt", "Tools/parity_ledger.py", "Strand/Old.swift", "docs/fork/decisions.md"}

    def drift(self, text, doc="docs/fork/x.md", kotlin=frozenset(), ignored=frozenset()):
        return ch.analyse_doc_drift({doc: text}, swift_words={"AppModel", "RootTabView"},
                                    declared={"AppModel"}, main_paths=self.MAIN, upstream_paths=self.UP,
                                    kotlin_words=set(kotlin), is_ignored=lambda p: p in ignored)

    def test_verdicts(self):
        text = ("`Strand/App/AppModel.swift` `AppModel.swift:12` `Strand/Old.swift` `Gone.swift` "
                "`Tools/parity_ledger.py` `Foo.kt` `AppModel.shared` `GoneView` `KotlinThing` "
                "`Settings` `groue/GRDB.swift` `vX.Y.Z.md` `Config/Secret.xcconfig` `StrandiOS`\n"
                "```\n`InsideFence`\n```\n")
        found = {(d["ref"], d["verdict"]) for d in self.drift(text, kotlin={"KotlinThing"},
                                                               ignored={"Config/Secret.xcconfig"})}
        self.assertEqual(found, {("Strand/Old.swift", "deleted-in-fork"), ("Gone.swift", "missing"),
                                 ("Tools/parity_ledger.py", "deliberate"), ("Foo.kt", "android"),
                                 ("GoneView", "missing"), ("KotlinThing", "android")})

    def test_owner(self):
        self.assertEqual(self.drift("`GoneView`", doc="docs/BUILD.md")[0]["owner"], "fork")
        self.assertEqual(ch.analyse_doc_drift({"docs/BUILD.md": "`GoneView`"}, set(), set(), self.MAIN,
                                              self.UP | {"docs/BUILD.md"}, set())[0]["owner"], "upstream")

    def test_scope(self):
        self.assertTrue(ch.is_doc_in_scope("docs/fork/decisions.md"))
        self.assertFalse(ch.is_doc_in_scope("docs/CHANGELOG.md"))
        self.assertFalse(ch.is_doc_in_scope("docs/fork/releases/v12.0.1.md"))
        self.assertFalse(ch.is_doc_in_scope("docs/fork/code-health/2026-10-10.md"))
        self.assertFalse(ch.is_doc_in_scope("README.md"))


class DecisionTests(unittest.TestCase):
    def test_rows_sections_and_signals(self):
        text = ("| Date | Decision | Why |\n|---|---|---|\n"
                "| 2026-07-23 | Parity contract is **retired** | No Android |\n"
                "| 2026-07-24 | Keep tiles separate | risky |\n"
                "### 2026-10-06 — Bidirectional sync\n")
        rows = ch.parse_decisions(text)
        self.assertEqual([(r["date"], r["kind"], r["signals"]) for r in rows],
                         [("2026-07-23", "row", ["retired"]), ("2026-07-24", "row", []),
                          ("2026-10-06", "section", [])])


class TrendTests(unittest.TestCase):
    def result(self, method=ch.METHOD_VERSION, files=1):
        r = {"meta": {"method_version": method, "run_date": "2026-10-10", "ref": "main", "ref_sha": "a" * 40,
                      "ref_date": "2026-10-10T10:00:00+02:00", "window_days": 60},
             "files": [{"path": "Strand/A.swift", "code": 600, "physical": 700}] * files,
             "types": [], "views": [], "fork_commits": 3, "hotspots": [], "observable_objects": [],
             "observable_classes": [], "test_gaps": {"types": [], "files": []}, "risk": [], "upstream": None,
             "doc_drift": [], "decisions": []}
        r["headline"] = ch.headline(r)
        return r

    def test_delta_against_previous(self):
        md = ch.render_markdown(self.result(files=2), self.result(files=1))
        self.assertIn("| Produkt-Swift-Dateien | 1 | 2 | +1 |", md)
        self.assertIn("| Codezeilen gesamt | 600 | 1200 | +600 |", md)

    def test_method_change_is_not_compared(self):
        md = ch.render_markdown(self.result(), self.result(method=ch.METHOD_VERSION - 1))
        self.assertIn("Nicht vergleichbar", md)
        self.assertNotIn("| vorher |", md)

    def test_baseline(self):
        self.assertIn("Baseline", ch.render_markdown(self.result(), None))


if __name__ == "__main__":
    unittest.main()
