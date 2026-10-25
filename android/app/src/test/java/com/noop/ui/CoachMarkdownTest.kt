package com.noop.ui

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Inline-parser cases for the dependency-free Coach Markdown renderer (#149). Verifies the visible
 * text is correct and the right spans are applied — and, crucially, that an UNTERMINATED marker is
 * emitted literally so a stray `*` never eats the rest of a reply.
 */
class CoachMarkdownTest {

    @Test fun plainTextHasNoSpans() {
        val a = parseInline("recovery is 72% today", Color.Unspecified)
        assertEquals("recovery is 72% today", a.text)
        assertTrue(a.spanStyles.isEmpty())
    }

    @Test fun boldStripsMarkersAndBolds() {
        val a = parseInline("push **hard** today", Color.Unspecified)
        assertEquals("push hard today", a.text)
        val s = a.spanStyles.single()
        assertEquals(FontWeight.Bold, s.item.fontWeight)
        assertEquals("hard", a.text.substring(s.start, s.end))
    }

    @Test fun italicAndCode() {
        val it = parseInline("keep it *easy*", Color.Unspecified)
        assertEquals("keep it easy", it.text)
        assertEquals(FontStyle.Italic, it.spanStyles.single().item.fontStyle)

        val code = parseInline("run `zone2` only", Color.Unspecified)
        assertEquals("run zone2 only", code.text)
        assertTrue(code.spanStyles.single().item.fontFamily != null)
    }

    @Test fun unterminatedMarkerIsLiteral() {
        val a = parseInline("a 3*4 set and **bold here", Color.Unspecified)
        // No closing marker, so nothing is consumed as a style — markers stay literal.
        assertEquals("a 3*4 set and **bold here", a.text)
        assertTrue(a.spanStyles.isEmpty())
    }

    @Test fun multipleBoldsInOneLine() {
        val a = parseInline("**HRV** up, **RHR** down", Color.Unspecified)
        assertEquals("HRV up, RHR down", a.text)
        assertEquals(2, a.spanStyles.size)
    }

    // --- GFM pipe tables (Android twin of the iOS/macOS MarkdownUI table; #132 roadmap) ---

    @Test fun parsesSimplePipeTable() {
        val lines = listOf(
            "| Metric | Value |",
            "| --- | --- |",
            "| HRV | 72 |",
            "| RHR | 48 |",
        )
        val (table, next) = parseTable(lines, 0)!!
        assertEquals(listOf("Metric", "Value"), table.header)
        assertEquals(listOf(listOf("HRV", "72"), listOf("RHR", "48")), table.rows)
        assertEquals(4, next)
    }

    @Test fun notATableWithoutDelimiterRow() {
        // A prose line that merely contains a pipe must NOT be eaten as a table.
        val lines = listOf("see the strap | charger combo", "next line")
        assertNull(parseTable(lines, 0))
    }

    @Test fun tableStopsAtBlankLineAndKeepsRawCellMarkdown() {
        val lines = listOf(
            "| A | B |",
            "|---|---|",
            "| **bold** | x |",
            "",
            "after",
        )
        val (table, next) = parseTable(lines, 0)!!
        assertEquals(listOf("A", "B"), table.header)
        // Raw cell text is kept; the renderer applies parseInline so **bold** still bolds.
        assertEquals(listOf(listOf("**bold**", "x")), table.rows)
        assertEquals(3, next)
    }

    @Test fun toleratesMissingOuterPipes() {
        // GFM allows tables without leading/trailing pipes.
        val lines = listOf(
            "Metric | Value",
            "--- | ---",
            "HRV | 72",
        )
        val (table, next) = parseTable(lines, 0)!!
        assertEquals(listOf("Metric", "Value"), table.header)
        assertEquals(listOf(listOf("HRV", "72")), table.rows)
        assertEquals(3, next)
    }
}
