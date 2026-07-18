"""Tests for the #540 fix: i18n_audit.py must see UI-text literals hidden
behind if/else, when, and .let — not just literals sitting immediately after
Text(/title=/etc — without also sweeping unrelated nested composable subtrees
(the bug in the first draft of this fix, which produced 489 findings instead
of a few dozen).

Run: python3 -m unittest Tools.test_i18n_audit -v   (from the repo root)
     or: cd Tools && python3 -m unittest test_i18n_audit -v
"""

import json
import tempfile
import unittest
from pathlib import Path

import i18n_audit as ia


def literals(text: str) -> list[str]:
    """Every literal `_extract_literals` finds across the whole snippet,
    content only (offsets aren't interesting for these tests)."""
    return [lit for _offset, lit in ia._extract_literals(text, 0, len(text))]


class AndroidLiteralExtraction(unittest.TestCase):
    def test_plain_literal(self):
        self.assertEqual(literals('Text("Save")'), ["Save"])

    def test_ternary_if_else_expression(self):
        # The issue's exact reported bug (HrvSnapshotScreen.kt:290).
        self.assertEqual(literals('Text(if (saved) "Saved" else "Save")'), ["Saved", "Save"])

    def test_block_bodied_if_else(self):
        # SleepScreen.kt:2249-shaped: braces around each branch.
        text = 'Text(if (session.userEdited) { "Removes edited" } else { "Removes recorded" })'
        self.assertEqual(literals(text), ["Removes edited", "Removes recorded"])

    def test_let_as_null_coalescing_ternary(self):
        # CaffeineLog.kt:297-shaped.
        text = 'Text(estimate?.let { "About it" } ?: "Caffeine may still be active")'
        self.assertEqual(literals(text), ["About it", "Caffeine may still be active"])

    def test_when_with_subject(self):
        text = 'Text(when (stage) { "Awake" -> "Awake now" else -> "Unknown" })'
        self.assertIn("Awake now", literals(text))
        self.assertIn("Unknown", literals(text))

    def test_bare_when(self):
        text = 'Text(when { cond1 -> "a" else -> "b" })'
        self.assertEqual(literals(text), ["a", "b"])

    def test_nested_composable_slot_not_swept(self):
        # A trailing lambda that is NOT if/when/.let is a separate,
        # independently-composed subtree (the 489-finding regression this
        # fix must not reintroduce) — nothing should be found INSIDE it from
        # here; the nested Text(...) is discovered on its own, separate pass.
        text = 'AlertDialog(text = { Column { Text("Unrelated deep content") } })'
        kwarg_start = text.index("{ Column")
        span_end = ia._argument_span_end(text, text.index("=", text.index("text")) + 1)
        self.assertEqual(literals(text[kwarg_start:span_end]), [])

    def test_plus_concatenation_skipped(self):
        # uiString(R.string.x) + "hardcoded suffix" is a real, but explicitly
        # DIFFERENT and out-of-scope bug (partial localization via an
        # engineered prefix) — tracked separately, not by this scanner.
        text = 'Text(uiString(R.string.x) + "hardcoded suffix")'
        self.assertEqual(literals(text), [])

    def test_plus_concatenation_does_not_swallow_a_real_conditional(self):
        # LiveScreen.kt:1068-shaped: the first branch is a real, standalone
        # conditional literal; only the +-joined unit-suffix is excluded.
        text = 'Text(if (empty) "Waiting." else "Recent: " + values.joinToString() + " ms")'
        self.assertEqual(literals(text), ["Waiting.", "Recent: "])

    def test_string_template_interpolation_not_corrupted(self):
        # MindSection.kt:167-shaped pluralization idiom: a nested literal
        # inside ${...} must not be mistaken for the end of the outer one.
        text = 'Text("$left more ${if (left == 1) "day" else "days"} to go.")'
        self.assertEqual(literals(text), ['$left more ${if (left == 1) "day" else "days"} to go.'])


class MaskComments(unittest.TestCase):
    def test_line_comment_blanked(self):
        text = 'val x = 1 // "Take over this ring?"\nText("Real")'
        masked = ia._mask_comments(text)
        self.assertNotIn("Take over", masked)
        self.assertIn('Text("Real")', masked)
        self.assertEqual(len(masked), len(text))  # offsets/line numbers preserved

    def test_block_comment_blanked(self):
        text = 'Text(/* "fake" */ "Real")'
        masked = ia._mask_comments(text)
        self.assertNotIn("fake", masked)
        self.assertIn("Real", masked)

    def test_comment_marker_inside_string_not_treated_as_comment(self):
        text = 'Text("http://example.com // not a comment")'
        masked = ia._mask_comments(text)
        self.assertIn("not a comment", masked)


class FormatSpecExclusion(unittest.TestCase):
    def test_pure_format_spec_excluded(self):
        self.assertFalse(ia.is_probably_ui_text("%.1f"))
        self.assertFalse(ia.is_probably_ui_text("%02d"))
        self.assertFalse(ia.is_probably_ui_text("%+.2f"))

    def test_format_spec_with_real_text_kept(self):
        self.assertTrue(ia.is_probably_ui_text("%.1f br/min"))


class ScanAndroidEndToEnd(unittest.TestCase):
    """Exercises scan_android() against real files on disk (its actual
    contract), not just the pure-function helpers above."""

    def setUp(self):
        # Must live under ia.ROOT: scan_android() reports paths via
        # `path.relative_to(ROOT)`, which raises for anything outside it.
        self.tmp = tempfile.TemporaryDirectory(dir=ia.ROOT)
        self.addCleanup(self.tmp.cleanup)
        self.ui_dir = Path(self.tmp.name) / "ui"
        self.ui_dir.mkdir()
        self._orig_dirs = ia.ANDROID_DIRS
        ia.ANDROID_DIRS = [self.ui_dir]
        self.addCleanup(setattr, ia, "ANDROID_DIRS", self._orig_dirs)

    def write(self, name: str, content: str) -> None:
        (self.ui_dir / name).write_text(content, encoding="utf-8")

    def test_conditional_literal_found(self):
        self.write("Screen.kt", 'Text(if (saved) "Saved" else "Save")')
        found = {lit for _p, _l, lit in ia.scan_android()}
        self.assertEqual(found, {"Saved", "Save"})

    def test_alert_dialog_kwarg_conditional_found(self):
        self.write(
            "Screen.kt",
            'AlertDialog(onDismissRequest = {}, title = { Text(if (x) "A" else "B") })',
        )
        found = {lit for _p, _l, lit in ia.scan_android()}
        self.assertEqual(found, {"A", "B"})

    def test_local_val_declaration_not_scanned_as_kwarg(self):
        # `val text = when { ... }` is a local declaration, not a composable
        # kwarg — ANDROID_KWARG_PATTERN's `text=` must not treat its `when`
        # branch match-keys as UI-text findings.
        self.write(
            "Screen.kt",
            'val text = when (stage) {\n    "Awake" -> "Awake now"\n    else -> "Unknown"\n}\n',
        )
        found = {lit for _p, _l, lit in ia.scan_android()}
        self.assertEqual(found, set())

    def test_no_explosion_from_nested_slot_lambda(self):
        # The 489-finding regression guard: a huge, unrelated nested
        # composable subtree inside a title=/text= slot must not get swept.
        self.write(
            "Wizard.kt",
            "AlertDialog(\n"
            "    onDismissRequest = {},\n"
            "    text = {\n"
            "        Column {\n"
            '            Text("First deep child")\n'
            '            Text("Second deep child")\n'
            "        }\n"
            "    },\n"
            ")",
        )
        found = [lit for _p, _l, lit in ia.scan_android()]
        # Both literals are still found — but because the file-wide scan
        # reaches each nested Text(...) call directly, not because the
        # outer AlertDialog's text= span was swept.
        self.assertEqual(sorted(found), ["First deep child", "Second deep child"])


class Baseline(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self._orig_path = ia.BASELINE_PATH
        ia.BASELINE_PATH = Path(self.tmp.name) / "baseline.json"
        self.addCleanup(setattr, ia, "BASELINE_PATH", self._orig_path)

    def test_missing_baseline_is_empty(self):
        self.assertEqual(ia.load_baseline(), {"android": set(), "ios": set()})

    def test_round_trip(self):
        ia.BASELINE_PATH.write_text(
            json.dumps({"android": [["Screen.kt", "Old"]], "ios": []}), encoding="utf-8"
        )
        baseline = ia.load_baseline()
        self.assertEqual(baseline["android"], {("Screen.kt", "Old")})
        self.assertEqual(baseline["ios"], set())

    def test_baseline_keyed_by_path_and_literal_not_line(self):
        # A baseline entry must keep suppressing a finding whose line number
        # shifted from an unrelated edit elsewhere in the same file.
        ia.BASELINE_PATH.write_text(
            json.dumps({"android": [["Screen.kt", "Save"]], "ios": []}), encoding="utf-8"
        )
        baseline = ia.load_baseline()
        finding = ("Screen.kt", 999, "Save")  # line number drifted
        self.assertIn((finding[0], finding[2]), baseline["android"])


if __name__ == "__main__":
    unittest.main()
