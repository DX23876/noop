package com.noop.ingest

import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

/**
 * Splits an import window into month-sized blocks, newest first, each one read a night wider than the
 * days it owns.
 *
 * Fork (DX23876), 2026-11-22. A Health Connect import read ten years in one pass and held what it could
 * not fold per day until the end: `activeKcalRecords` and `totalKcalRecords` carry one entry per calorie
 * record, which a provider writing fifteen-minute buckets makes hundreds of thousands of, and
 * `workoutSamples` carries every heart-rate sample of every session. The tester log of 2026-11-22 counted
 * 2 269 462 records in a single pass, with two such passes running at once, on a phone that gives an app a
 * few hundred megabytes. Read a month, fold it, write it, let it go, and the peak is a month.
 *
 * Newest first, because that is the order in which data is missed, and because a run that dies has then
 * banked the weeks anybody would look at first.
 *
 * ## Why a block is read wider than it owns
 *
 * A night is keyed by the day the sleeper WOKE (`SleepSessionRecord` is bucketed on `endTime`), while
 * Health Connect filters a read by the record's START. So a night from 23:00 on the 31st to 07:00 on the
 * 1st is READ in one month and BELONGS to the next. With a per-block write that REPLACES the day's row —
 * which `upsertAppleDaily` does, whole row at a time — the two blocks would take turns erasing each
 * other: the block that owns the day would write it without the night, or the block that read the night
 * would write the day without its steps.
 *
 * The repository has already answered this shape once. `HealthWriteback.sleepReadLeadSeconds` reads
 * sessions a night's length wider than its window for the same reason, and `sleepEntriesOwned` writes
 * only the keys the window owns while claiming every fragment's. Both halves are here: [Block.readStart]
 * is widened by [READ_LEAD_SECONDS] and [Block.owns] is what the write-out filters on. A day therefore
 * belongs to exactly one block, and every block sees the records that belong to its days.
 */
object ImportBlocks {

    /**
     * How far before its first owned day a block starts reading. A full day, which is longer than any
     * night: a session that began earlier than this and is still running at the block boundary would be
     * a day and a half in bed, and is not what this is protecting.
     */
    const val READ_LEAD_SECONDS: Long = 24 * 60 * 60

    /**
     * One month of the import, the days it is responsible for writing, and the range it reads to write
     * them completely.
     *
     * `firstOwnedDay` and `lastOwnedDay` are inclusive local dates. `readStart` is at or before the start
     * of `firstOwnedDay`; `readEnd` is the instant after the end of `lastOwnedDay`, so an exclusive upper
     * bound covers the whole last day.
     */
    data class Block(
        val firstOwnedDay: LocalDate,
        val lastOwnedDay: LocalDate,
        val readStart: Instant,
        val readEnd: Instant,
    ) {
        /**
         * Whether this block writes `dayKey`, which is a `localDayKey` value ("YYYY-MM-DD"). Compared as
         * text: ISO dates sort as dates, and a key that cannot be parsed (a corrupt record, a writer with
         * its own ideas) is then simply not owned by anybody rather than throwing mid-import.
         */
        fun owns(dayKey: String): Boolean =
            dayKey >= firstOwnedDay.toString() && dayKey <= lastOwnedDay.toString()
    }

    /**
     * The blocks covering `start`..`end` inclusive, newest first. Each block is a calendar month, clipped
     * to the window at both ends, so the oldest block can start mid-month and the newest can end today.
     *
     * An empty list when `end` is before `start`, rather than a block that reads backwards.
     */
    fun monthly(start: LocalDate, end: LocalDate, zone: ZoneId): List<Block> {
        if (end.isBefore(start)) return emptyList()
        val blocks = ArrayList<Block>()
        var lastOwned = end
        while (!lastOwned.isBefore(start)) {
            val monthFirst = lastOwned.withDayOfMonth(1)
            val firstOwned = if (monthFirst.isBefore(start)) start else monthFirst
            blocks.add(
                Block(
                    firstOwnedDay = firstOwned,
                    lastOwnedDay = lastOwned,
                    // Start of the owned range in the wearer's zone, then a night earlier. ZonedDateTime
                    // rather than a plain epoch subtraction, so a month boundary that falls on a DST
                    // change still begins where the day does.
                    readStart = firstOwned.atStartOfDay(zone).toInstant()
                        .minusSeconds(READ_LEAD_SECONDS),
                    // Exclusive upper bound: the start of the day AFTER the last owned one.
                    readEnd = lastOwned.plusDays(1).atStartOfDay(zone).toInstant(),
                ),
            )
            if (firstOwned == start) break
            lastOwned = firstOwned.minusDays(1)
        }
        return blocks
    }

    /** The line a block writes to the strap log, so a long import's course can be read afterwards. */
    fun blockLine(index: Int, total: Int, block: Block): String =
        "Import Health Connect: block ${index + 1} of $total · " +
            "${block.firstOwnedDay}..${block.lastOwnedDay}"
}
