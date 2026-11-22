package com.noop.ingest

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate
import java.time.ZoneId

/**
 * Pure JVM coverage for the import's block split. The case that matters is the month boundary: a night
 * is keyed by the day the sleeper woke, Health Connect filters a read by the record's start, and the
 * per-day write REPLACES the whole row — so a block that owned a day without seeing its night would
 * erase it.
 */
class ImportBlocksTest {

    private val zone: ZoneId = ZoneId.of("Europe/Berlin")

    @Test
    fun aTenYearWindowSplitsIntoMonthsNewestFirst() {
        val end = LocalDate.of(2026, 11, 22)
        val blocks = ImportBlocks.monthly(end.minusYears(10), end, zone)

        // Ten years and a bit: 120 whole months plus the two partial ones at the ends.
        assertEquals(121, blocks.size)
        assertEquals(end, blocks.first().lastOwnedDay)
        assertEquals(LocalDate.of(2026, 11, 1), blocks.first().firstOwnedDay)
        // Newest first, strictly descending.
        for (i in 1 until blocks.size) {
            assertTrue("block $i must be older than block ${i - 1}",
                       blocks[i].lastOwnedDay.isBefore(blocks[i - 1].firstOwnedDay))
        }
    }

    @Test
    fun theOldestBlockStartsWhereTheWindowDoesAndNotAtTheFirstOfItsMonth() {
        val start = LocalDate.of(2026, 3, 17)
        val blocks = ImportBlocks.monthly(start, LocalDate.of(2026, 5, 4), zone)

        assertEquals(3, blocks.size)
        assertEquals(start, blocks.last().firstOwnedDay)
        assertEquals(LocalDate.of(2026, 3, 31), blocks.last().lastOwnedDay)
    }

    @Test
    fun everyDayInTheWindowIsOwnedByExactlyOneBlock() {
        val start = LocalDate.of(2025, 12, 14)
        val end = LocalDate.of(2026, 3, 2)
        val blocks = ImportBlocks.monthly(start, end, zone)

        var day = start
        while (!day.isAfter(end)) {
            val owners = blocks.count { it.owns(day.toString()) }
            assertEquals("$day must have exactly one owner", 1, owners)
            day = day.plusDays(1)
        }
        // And nothing outside the window is claimed.
        assertEquals(0, blocks.count { it.owns(start.minusDays(1).toString()) })
        assertEquals(0, blocks.count { it.owns(end.plusDays(1).toString()) })
    }

    @Test
    fun aBlockReadsANightEarlierThanItsFirstOwnedDay() {
        val blocks = ImportBlocks.monthly(LocalDate.of(2026, 1, 1), LocalDate.of(2026, 2, 28), zone)
        val february = blocks.first()

        assertEquals(LocalDate.of(2026, 2, 1), february.firstOwnedDay)
        // A night from 23:00 on 31 January to 07:00 on 1 February is keyed to 1 February, which February
        // owns, and STARTS in January — so February's read must reach back past that start.
        val nightStart = LocalDate.of(2026, 1, 31).atTime(23, 0).atZone(zone).toInstant()
        assertTrue("February must read the night that began on 31 January",
                   february.readStart <= nightStart)
        assertTrue(february.owns("2026-02-01"))
        // And January must NOT write that day, or it would do so without February's own records.
        assertFalse(blocks.last().owns("2026-02-01"))
    }

    @Test
    fun aBlockReadsToTheEndOfItsLastOwnedDay() {
        val blocks = ImportBlocks.monthly(LocalDate.of(2026, 2, 1), LocalDate.of(2026, 2, 28), zone)
        val february = blocks.single()
        val lastMinute = LocalDate.of(2026, 2, 28).atTime(23, 59).atZone(zone).toInstant()

        assertTrue("a record at 23:59 on the last owned day must fall inside the read range",
                   february.readEnd > lastMinute)
    }

    @Test
    fun aMonthBoundaryOnADaylightSavingChangeStillBeginsWhereTheDayDoes() {
        // Central Europe springs forward on 29 March 2026, inside the month this block owns, and the
        // boundary of the NEXT block (1 April) sits after it. A plain epoch subtraction would be an hour
        // out on one side of the change.
        val blocks = ImportBlocks.monthly(LocalDate.of(2026, 3, 1), LocalDate.of(2026, 4, 30), zone)
        val april = blocks.first()

        assertEquals(LocalDate.of(2026, 4, 1), april.firstOwnedDay)
        val aprilDayStart = LocalDate.of(2026, 4, 1).atStartOfDay(zone).toInstant()
        assertEquals(aprilDayStart.minusSeconds(ImportBlocks.READ_LEAD_SECONDS), april.readStart)
    }

    @Test
    fun aSingleDayWindowIsOneBlock() {
        val day = LocalDate.of(2026, 11, 22)
        val blocks = ImportBlocks.monthly(day, day, zone)

        assertEquals(1, blocks.size)
        assertEquals(day, blocks.single().firstOwnedDay)
        assertEquals(day, blocks.single().lastOwnedDay)
        assertTrue(blocks.single().owns("2026-11-22"))
    }

    @Test
    fun aBackwardsWindowIsNoBlocksRatherThanOneThatReadsBackwards() {
        val blocks = ImportBlocks.monthly(LocalDate.of(2026, 11, 22), LocalDate.of(2026, 11, 1), zone)
        assertTrue(blocks.isEmpty())
    }

    @Test
    fun anUnparseableDayKeyIsOwnedByNobodyRatherThanThrowing() {
        val block = ImportBlocks.monthly(LocalDate.of(2026, 11, 1), LocalDate.of(2026, 11, 22), zone).single()
        assertFalse(block.owns(""))
        assertFalse(block.owns("not-a-day"))
    }

    @Test
    fun theBlockLineNamesWhereTheImportHasGot() {
        val block = ImportBlocks.monthly(LocalDate.of(2026, 11, 1), LocalDate.of(2026, 11, 22), zone).single()
        assertEquals("Import Health Connect: block 1 of 121 · 2026-11-01..2026-11-22",
                     ImportBlocks.blockLine(index = 0, total = 121, block = block))
    }
}
