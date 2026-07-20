package com.noop.testcentre

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Twin of the Swift ReportReviewGateTests: the mandatory, non-skippable review gate (spec sections
 * 9, 12). A fresh or cancelled gate never clears; only an explicit confirm clears; the preview shows
 * the report.txt the user is about to share.
 */
class ReportReviewGateTest {

    private fun sampleEntries(): List<Pair<String, ByteArray>> =
        listOf("report.txt" to "NOOP strap log\nline 1\nline 2".toByteArray())

    @Test
    fun freshGateIsNotCleared() {
        assertFalse(ReportReviewGate(sampleEntries()).isCleared)
    }

    @Test
    fun previewShowsTheReportText() {
        val gate = ReportReviewGate(sampleEntries())
        assertTrue(gate.previewText.contains("line 1"))
        assertTrue(gate.previewText.contains("line 2"))
    }

    @Test
    fun confirmClearsAndCancelDoesNot() {
        val gate = ReportReviewGate(sampleEntries())
        gate.cancel()
        assertFalse(gate.isCleared)
        gate.confirm()
        assertTrue(gate.isCleared)
    }

    // #570 parity: the large raw-capture stream is excluded from the inline preview (never laid out) but is
    // NAMED in the "attached" note, so the review stays honest about the whole bundle.
    @Test
    fun rawCaptureIsExcludedFromInlineButNamed() {
        val gate = ReportReviewGate(listOf(
            "report.txt" to "the report body".toByteArray(),
            "raw-capture.jsonl" to "{\"hex\":\"deadbeef\"}".toByteArray(),
        ))
        val preview = gate.previewText
        assertTrue("report body is shown inline", preview.contains("the report body"))
        assertFalse("raw-capture is NOT laid out inline", preview.contains("deadbeef"))
        assertTrue("raw-capture is named in the attached note", preview.contains("raw-capture.jsonl"))
    }

    // #570 belt-and-braces: ANY entry over the ~1 MiB guard is excluded even if it isn't a known raw stream —
    // a future stream, or a pathologically large report.txt, can't choke the review sheet — and is named.
    @Test
    fun oversizedEntryIsExcludedByTheSizeGuardAndNamed() {
        val huge = ByteArray(2 * 1024 * 1024) { 'a'.code.toByte() }
        val gate = ReportReviewGate(listOf(
            "meta.json" to "{\"ok\":true}".toByteArray(),
            "last-crash.txt" to huge,   // over the guard
        ))
        val preview = gate.previewText
        assertTrue("small meta.json still shown inline", preview.contains("\"ok\":true"))
        assertTrue("the 2 MB entry is not laid out inline", preview.length < 100_000)
        assertTrue("the oversized entry is named in the attached note", preview.contains("last-crash.txt"))
    }

    // Normal small text files still show in full, and there is no "attached" note when nothing is excluded.
    @Test
    fun normalTextFilesStayInlineWithNoAttachedNote() {
        val gate = ReportReviewGate(listOf(
            "report.txt" to "report line".toByteArray(),
            "meta.json" to "{\"v\":1}".toByteArray(),
        ))
        val preview = gate.previewText
        assertTrue(preview.contains("report line"))
        assertTrue(preview.contains("{\"v\":1}"))
        assertFalse(preview.contains("attached (not shown above)"))
    }
}
