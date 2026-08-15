#!/usr/bin/env python3
"""What `appchangelog-gen.py` still has to get right, now that it emits Swift only.

The file used to pin #878 — the generated ANDROID What's New title had to be a resource reference
rather than a literal, or the i18n gate red-checked every open PR. That arm went with the Android
tree on 2026-08-14, and these tests went with it in the wrong direction: they kept calling
`acg.kt_block` and reading `android/app/src/main/res/values/strings.xml`, so `Tools Python CI` has
been red on every push since, on 13 errors that say nothing about the generator.

What survives is the part that was never Android-specific and is still worth pinning: the emitted
Swift block, and `apply()`'s refresh behaviour. That one had a real bug — it skipped an entry that
already existed while the writer ran anyway, so an edited headline left the card showing the previous
one with nothing failing.
"""
import importlib.util
import pathlib
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
_spec = importlib.util.spec_from_file_location("acg", ROOT / "Tools/appchangelog-gen.py")
acg = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(acg)

TITLE = ("Battery saver quiets the gauges, translated Android notifications, "
         "and instant chart loads")


class EmittedBlockTests(unittest.TestCase):

    WN = {"title": TITLE, "date": "July 2026", "items": ["**One.** A thing."]}

    def test_swift_title_is_a_literal(self):
        """`WhatsNewView` renders the title through `LocalizedStringKey`, so the English text IS the
        catalog key — it has to arrive here verbatim, not as a reference to anything."""
        self.assertIn(f'title: "{TITLE}"', acg.sw_block("9.2.1", self.WN))

    def test_items_stay_literals(self):
        """Items are long-form prose, keyed by their English text for the same reason as the title."""
        self.assertIn('"**One.** A thing."', acg.sw_block("9.2.1", self.WN))

    def test_version_and_date_are_carried_through(self):
        block = acg.sw_block("9.2.1", self.WN)
        self.assertIn('version: "9.2.1"', block)
        self.assertIn('date: "July 2026"', block)

    def test_a_quote_in_the_prose_is_escaped(self):
        """An unescaped `"` in an item would not compile, and the notes are written by hand."""
        wn = dict(self.WN, items=['**Fixed:** it read "+33.4°" before.'])
        self.assertIn(r'\"+33.4°\"', acg.sw_block("9.2.1", wn))


class TitleRefreshTests(unittest.TestCase):
    """Re-running after editing the headline must update the entry, not leave it stale."""

    HEAD = ("enum AppChangelog {\n"
            '    static let currentVersion = "0.0.0"\n'
            "    static let releases: [Release] = [\n")
    TAIL = "    ]\n}\n"
    ANCHOR = "static let releases: [Release] = [\n"
    CONST_RE = r'(static let currentVersion = ")[^"]*(")'

    ENTRY = ('        Release(\n'
             '            version: "9.9.9",\n'
             '            title: "The old headline",\n'
             '            date: "July 2026",\n'
             '        ),\n')

    def _file(self, body):
        f = tempfile.NamedTemporaryFile("w", suffix=".swift", delete=False)
        f.write(self.HEAD + body + self.TAIL)
        f.close()
        return pathlib.Path(f.name)

    def test_existing_entry_gets_its_title_updated(self):
        path = self._file(self.ENTRY)
        acg.apply(path, self.ANCHOR, "IGNORED", "9.9.9",
                  self.CONST_RE, r'\g<1>9.9.9\g<2>', title_line='title: "The new headline",')
        out = path.read_text()
        self.assertIn("The new headline", out)
        self.assertNotIn("The old headline", out)
        path.unlink()

    def test_it_does_not_duplicate_the_entry(self):
        path = self._file(self.ENTRY)
        acg.apply(path, self.ANCHOR, "SHOULD_NOT_APPEAR", "9.9.9",
                  self.CONST_RE, r'\g<1>9.9.9\g<2>', title_line='title: "The new headline",')
        out = path.read_text()
        self.assertEqual(1, out.count('version: "9.9.9"'))
        self.assertNotIn("SHOULD_NOT_APPEAR", out)
        path.unlink()

    def test_unchanged_title_is_left_alone(self):
        """Asserting the title line rather than the whole file, because `apply()` legitimately
        rewrites the version constant on every run."""
        same = 'title: "The old headline",'
        path = self._file(self.ENTRY)
        acg.apply(path, self.ANCHOR, "IGNORED", "9.9.9",
                  self.CONST_RE, r'\g<1>9.9.9\g<2>', title_line=same)
        out = path.read_text()
        self.assertEqual(1, out.count(same))
        self.assertEqual(1, out.count('version: "9.9.9"'))
        self.assertIn('static let currentVersion = "9.9.9"', out)   # the constant DOES move
        path.unlink()

    def test_a_new_version_is_prepended_above_the_existing_one(self):
        """Newest first: the card reads top-down, and the release list is the order it shows."""
        path = self._file(self.ENTRY)
        acg.apply(path, self.ANCHOR, '        Release(\n            version: "10.0.0",\n        ),\n',
                  "10.0.0", self.CONST_RE, r'\g<1>10.0.0\g<2>')
        out = path.read_text()
        self.assertLess(out.index('version: "10.0.0"'), out.index('version: "9.9.9"'))
        path.unlink()


class FrontMatterTests(unittest.TestCase):

    def test_notes_without_front_matter_are_refused(self):
        """A release file with no `whatsnew:` block has nothing to generate from, and guessing would
        put an empty card in front of every user."""
        f = tempfile.NamedTemporaryFile("w", suffix=".md", delete=False)
        f.write("# NOOP v9.9.9\n\nNo front matter here.\n")
        f.close()
        with self.assertRaises(SystemExit):
            acg.frontmatter(pathlib.Path(f.name))
        pathlib.Path(f.name).unlink()

    def test_the_shipping_release_file_parses(self):
        """The real 10.1.0 notes, so a hand-edit that breaks the block is caught here rather than at
        release time."""
        wn = acg.frontmatter(ROOT / "docs/fork/releases/v10.1.0.md")
        self.assertTrue(wn["title"])
        self.assertTrue(wn["items"])


if __name__ == "__main__":
    unittest.main()
