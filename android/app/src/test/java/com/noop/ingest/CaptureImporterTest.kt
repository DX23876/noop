package com.noop.ingest

import com.noop.protocol.DeviceFamily
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.StringReader
import java.time.LocalDate

class CaptureImporterTest {

    private val whoop5Char = "fd4b0003-cce1-4033-93ce-002d5875f58a"
    private val whoop4Char = "61080003-8d6d-82b8-614a-1c8cb0f8dcc6"

    // One WHOOP5 v18 worn record (HR 102) and three WHOOP4 v25 records (gravity present).
    private val v18 =
        "aa01740001003fb12f1280733d8401b69f266a66460066025a0265020000000000007b0a8d656463ff0012163cf6a439bf2924fd3ed763fe3e3200aa000000000000000000f7000901f10b0007010c020c00000000000000000000000000000000000000000000000100656f1e1e0000009d61a7c00000003e862817"
    private val v25a =
        "aa50000c2f1900006800007dff2a6a20430900433103007e026502ba026c022eff70f996f879fad6fd8300d6017e0267027201be00290258030e05c507f00c030ead11cb15791500d2553c9003000000d6393716"
    private val v25b =
        "aa50000c2f1900016800007eff2a6a283e0900a0ad03007a0e880698018bfff5fb61eee9f2a7fa2bfe1af5fdf618fdf0f9c2fb0804510a14046a004dffd0ff6dfdddfd670183014e071a3f9003000000587bbabf"
    private val v25c =
        "aa50000c2f1900026800007fff2a6a38390900729103003608a2fd0104850d4f1bd21aa60f080d850edb116b0f160b7d063f06ab04d5041704a4045f04f003f5ffd7ff7efe73ffa8b2333e9003010000fa54e5e9"

    private fun captureJson(vararg pairs: Pair<String, String>): String =
        pairs.joinToString(prefix = "[", postfix = "]") { (char, hex) ->
            """{"hex":"$hex","char":"$char","ts_ms":0,"hr":0}"""
        }

    @Test
    fun familyForCharMapsByMarker() {
        assertEquals(DeviceFamily.WHOOP5, CaptureImporter.familyForChar(whoop5Char))
        assertEquals(DeviceFamily.WHOOP4, CaptureImporter.familyForChar(whoop4Char))
        assertEquals(DeviceFamily.WHOOP4, CaptureImporter.familyForChar(whoop4Char.uppercase()))
        assertNull(CaptureImporter.familyForChar("0000abcd-dead-beef-0000-000000000000"))
        assertNull(CaptureImporter.familyForChar(null))
    }

    @Test
    fun hexToBytesRoundTripsAndRejectsBadInput() {
        assertEquals(2, CaptureImporter.hexToBytes("aa50")!!.size)
        assertEquals(0xaa.toByte(), CaptureImporter.hexToBytes("aa50")!![0])
        assertNull(CaptureImporter.hexToBytes("abc"))   // odd length
        assertNull(CaptureImporter.hexToBytes("zz"))    // non-hex
    }

    @Test
    fun hexToBytesRejectsOverlongFrameFromUntrustedFile() {
        // A frame far longer than any real strap record (here 600 bytes) is junk in an untrusted file
        // and must be skipped, not turned into a 600-byte ByteArray fed to the decoder.
        val overlong = "ab".repeat(600)
        assertNull(CaptureImporter.hexToBytes(overlong))
    }

    @Test
    fun parseGroupsFramesByFamilyAndCountsSkips() {
        val json = captureJson(
            whoop5Char to v18,
            whoop4Char to v25a,
            "0000abcd-0000-0000-0000-000000000000" to v25a, // unknown char -> skipped
        )
        val parsed = CaptureImporter.parse(json)
        assertEquals(3, parsed.totalFrames)
        assertEquals(1, parsed.skipped)
        assertEquals(1, parsed.byFamily[DeviceFamily.WHOOP5]!!.size)
        assertEquals(1, parsed.byFamily[DeviceFamily.WHOOP4]!!.size)
        assertEquals(false, parsed.truncated)
    }

    @Test(expected = org.json.JSONException::class)
    fun parseThrowsOnNonArrayJson() {
        CaptureImporter.parse("not json at all")
    }

    @Test(expected = org.json.JSONException::class)
    fun parseReaderThrowsOnNonArrayJson() {
        CaptureImporter.parse(StringReader("not json at all"))
    }

    @Test
    fun parseReaderMatchesStringForCompactInput() {
        val json = captureJson(whoop5Char to v18, whoop4Char to v25a)
        val parsed = CaptureImporter.parse(StringReader(json))
        assertEquals(2, parsed.totalFrames)
        assertEquals(0, parsed.skipped)
        assertEquals(1, parsed.byFamily[DeviceFamily.WHOOP5]!!.size)
        assertEquals(1, parsed.byFamily[DeviceFamily.WHOOP4]!!.size)
    }

    @Test
    fun parseReaderHandlesPrettyPrintedExport() {
        // The real whoop_sync.py export is pretty-printed (newlines + indentation), unlike the
        // compact captureJson helper; the streaming scanner must span elements across lines.
        val json = """
            [
             {
              "hex": "$v18",
              "char": "$whoop5Char",
              "ts_ms": 0,
              "hr": 0
             },
             {
              "hex": "$v25a",
              "char": "$whoop4Char",
              "ts_ms": 0,
              "hr": 0
             }
            ]
        """.trimIndent()
        val parsed = CaptureImporter.parse(StringReader(json))
        assertEquals(2, parsed.totalFrames)
        assertEquals(0, parsed.skipped)
        assertEquals(1, parsed.byFamily[DeviceFamily.WHOOP5]!!.size)
        assertEquals(1, parsed.byFamily[DeviceFamily.WHOOP4]!!.size)
    }

    @Test
    fun parseReaderRespectsStructuralCharsInsideStrings() {
        // A string value containing braces, brackets, commas and an escaped quote would break a naive
        // brace-counting splitter. The scanner must stay inside the string and still split elements.
        val tricky = """[{"note":"}, ] {\" weird","hex":"$v25a","char":"$whoop4Char"},""" +
            """{"hex":"$v18","char":"$whoop5Char"}]"""
        val parsed = CaptureImporter.parse(StringReader(tricky))
        assertEquals(2, parsed.totalFrames)
        assertEquals(0, parsed.skipped)
        assertEquals(1, parsed.byFamily[DeviceFamily.WHOOP4]!!.size)
        assertEquals(1, parsed.byFamily[DeviceFamily.WHOOP5]!!.size)
    }

    @Test
    fun parseReaderSkipsNonObjectArrayElements() {
        // optJSONObject(i) returned null for non-object elements (counted as skipped); the streaming
        // scanner must preserve that — a bare number/string/null between objects is skipped, not fatal.
        val json = """[ 42, "loose", null, {"hex":"$v25a","char":"$whoop4Char"} ]"""
        val parsed = CaptureImporter.parse(StringReader(json))
        assertEquals(1, parsed.totalFrames)
        assertEquals(3, parsed.skipped)
        assertEquals(1, parsed.byFamily[DeviceFamily.WHOOP4]!!.size)
    }

    @Test
    fun parseReaderHandlesEmptyArray() {
        val parsed = CaptureImporter.parse(StringReader("[]"))
        assertEquals(0, parsed.totalFrames)
        assertEquals(0, parsed.skipped)
        assertTrue(parsed.byFamily.isEmpty())
    }

    @Test
    fun parseSkipsUnparsableHexFrames() {
        // A row whose hex is malformed (odd length) on an otherwise-known char is skipped, not fatal.
        val json = """[ {"hex":"abc","char":"$whoop4Char"}, {"hex":"$v25a","char":"$whoop4Char"} ]"""
        val parsed = CaptureImporter.parse(StringReader(json))
        assertEquals(2, parsed.totalFrames)
        assertEquals(1, parsed.skipped)
        assertEquals(1, parsed.byFamily[DeviceFamily.WHOOP4]!!.size)
    }

    @Test
    fun decodeMapsV18HeartRateAndV25Gravity() {
        val json = captureJson(
            whoop5Char to v18,
            whoop4Char to v25a, whoop4Char to v25b, whoop4Char to v25c,
        )
        val decoded = CaptureImporter.decode(CaptureImporter.parse(json))
        assertEquals(4, decoded.offloadFrames)
        val w5 = decoded.batches[DeviceFamily.WHOOP5]!!
        assertTrue(w5.hr.any { it.bpm == 102 })
        val w4 = decoded.batches[DeviceFamily.WHOOP4]!!
        assertEquals(3, w4.gravity.size)
        assertTrue(decoded.rejects.values.all { it.isEmpty() })
    }

    @Test
    fun decodeDropsNonOffloadFrames() {
        // A WHOOP5 frame whose type byte (the WHOOP5 type index, frame[8]) is 0x00 — not one of the
        // offload types {47,48,49,50,56} — so isOffloadFrame drops it and nothing decodes.
        val realtime = "aa017400010028" + "00".repeat(40)
        val decoded = CaptureImporter.decode(CaptureImporter.parse(captureJson(whoop5Char to realtime)))
        assertTrue(decoded.batches.isEmpty())
        assertEquals(0, decoded.offloadFrames)
    }

    @Test
    fun summarizeBuildsCountsSpanAndMessage() {
        val json = captureJson(
            whoop5Char to v18,
            whoop4Char to v25a, whoop4Char to v25b, whoop4Char to v25c,
        )
        val parsed = CaptureImporter.parse(json)
        val decoded = CaptureImporter.decode(parsed)
        val inserted = com.noop.data.InsertCounts(hr = 1, gravity = 3)
        val s = CaptureImporter.summarize(decoded, inserted, parsed)
        assertEquals("Raw capture", s.source)
        assertEquals(1, s.counts["hr"])
        assertEquals(3, s.counts["gravity"])
        assertNull(s.counts["rr"]) // zero-count streams are omitted
        assertTrue(s.message.contains("4 historical frames"))
        assertTrue(s.firstDay!!.matches(Regex("\\d{4}-\\d{2}-\\d{2}")))
    }

    // ---- import-rescore window (folded in from the original PR's AnalyzeWindowTest) ----

    private val today = LocalDate.parse("2026-06-18")

    @Test
    fun nullSinceDayFallsBackToTheMinimumRecentWindow() {
        assertEquals(21, CaptureImporter.analyzeWindowDays(null, today, minDays = 21, maxDays = 730))
    }

    @Test
    fun malformedSinceDayFallsBackToTheMinimum() {
        assertEquals(21, CaptureImporter.analyzeWindowDays("not-a-date", today, minDays = 21, maxDays = 730))
    }

    @Test
    fun recentImportStaysAtTheMinimumFloor() {
        // 10 days of span (06-08 → 06-18) is inside the default window, so the floor wins.
        assertEquals(21, CaptureImporter.analyzeWindowDays("2026-06-08", today, minDays = 21, maxDays = 730))
    }

    @Test
    fun oldImportWidensTheWindowToCoverItsFirstDay() {
        // 100 days back must score back that far (+2 buffer), not just the default 21.
        assertEquals(102, CaptureImporter.analyzeWindowDays("2026-03-10", today, minDays = 21, maxDays = 730))
    }

    @Test
    fun ancientImportIsClampedToTheMaximum() {
        assertEquals(730, CaptureImporter.analyzeWindowDays("2010-01-01", today, minDays = 21, maxDays = 730))
    }

    @Test
    fun futureSinceDayFallsBackToTheMinimum() {
        // Clock skew / a bad row dated in the future must never yield a negative or zero window.
        assertEquals(21, CaptureImporter.analyzeWindowDays("2026-07-01", today, minDays = 21, maxDays = 730))
    }
}
