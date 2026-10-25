package com.noop.ingest

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

/**
 * Pins the Android aggregate-RAM budget for the export importers (#70 parity). Each importer collected
 * every recognised entry into an in-memory `Map<String, ByteArray>` guarded only by a per-entry cap
 * (256 MB) and, for Wearable, a per-COUNT cap (200k) — nothing bounded the SUM of the retained set. The
 * new `maxTotalBytes` budget stops collection once the next retained entry would exceed it, and reports
 * `truncated` so the import summary can say the set was partial instead of reporting a clean import.
 *
 * Drives the extracted [WearableExportImporter.collectZipEntries] seam from an in-memory zip, so no
 * Context / ContentResolver is needed (the same seam pattern as AppleHealthImporterToleranceTest).
 * ZipInputStream yields entries in archive order, so which entries survive is deterministic.
 */
class ImportByteBudgetTest {

    private fun zipOf(entries: List<Pair<String, ByteArray>>): ByteArray {
        val bos = ByteArrayOutputStream()
        ZipOutputStream(bos).use { zos ->
            for ((name, data) in entries) {
                zos.putNextEntry(ZipEntry(name))
                zos.write(data)
                zos.closeEntry()
            }
        }
        return bos.toByteArray()
    }

    private fun bytes(n: Int, fill: Char) = ByteArray(n) { fill.code.toByte() }

    @Test
    fun uncappedRetainsAllWellnessEntries() {
        val zip = zipOf(listOf("sleep.json" to bytes(1000, 'a'), "heart.json" to bytes(1000, 'b')))
        val (files, truncated) = WearableExportImporter.collectZipEntries(
            ByteArrayInputStream(zip), maxTotalBytes = 1L shl 30,
        )
        assertEquals(2, files.size)
        assertFalse("a real-size export never trips the 1 GB budget", truncated)
    }

    @Test
    fun budgetStopsAtSumAndReportsTruncated() {
        val zip = zipOf(listOf("sleep.json" to bytes(1000, 'a'), "heart.json" to bytes(1000, 'b')))
        // Cap over the first entry (1000) but under the sum (2000): the first is kept, the second trips it.
        val (files, truncated) = WearableExportImporter.collectZipEntries(
            ByteArrayInputStream(zip), maxTotalBytes = 1500L,
        )
        assertEquals(1, files.size)
        assertTrue("archive-order first entry survives", files.containsKey("sleep.json"))
        assertTrue("budget trip must be reported, not silent", truncated)
    }

    @Test
    fun retainedBytesNeverExceedBudget() {
        val zip = zipOf((0 until 10).map { "sleep$it.json" to bytes(1000, 'x') })
        val (files, truncated) = WearableExportImporter.collectZipEntries(
            ByteArrayInputStream(zip), maxTotalBytes = 1500L,
        )
        assertTrue(truncated)
        val retained = files.values.sumOf { it.size.toLong() }
        assertTrue("retained bytes ($retained) must stay within the budget", retained <= 1500L)
    }

    @Test
    fun nonWellnessEntriesAreSkippedAndDoNotCountAgainstBudget() {
        // A junk file between two wellness files: it isn't retained, so it neither trips the budget nor
        // consumes it — both wellness files survive under a budget sized for exactly the two of them.
        val zip = zipOf(listOf(
            "sleep.json" to bytes(1000, 'a'),
            "photos.png" to bytes(5000, 'z'),   // not wellness, not .json/.csv → skipped entirely
            "steps.csv" to bytes(1000, 'b'),
        ))
        val (files, truncated) = WearableExportImporter.collectZipEntries(
            ByteArrayInputStream(zip), maxTotalBytes = 2500L,
        )
        assertEquals(2, files.size)
        assertFalse(truncated)
    }
}
