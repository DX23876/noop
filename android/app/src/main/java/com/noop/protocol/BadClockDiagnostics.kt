package com.noop.protocol

import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * #324 bad-clock strap diagnostics: pure formatters for the Backfiller's strap-log lines about a strap
 * whose RTC reset to a wrong base (future- or far-past-dated banking). Kept in the protocol layer so the
 * formatting mirrors the Swift `BadClockDiagnostics` byte-for-byte. No state, no `now` inside - callers
 * inject `now` so the output is deterministic and unit-testable.
 */
object BadClockDiagnostics {

    /**
     * UTC `yyyy-MM-dd` for a unix-seconds timestamp - the human-readable day a dropped record CLAIMED,
     * which on a bad-clock strap is the wrong base its RTC jumped to.
     */
    fun isoDay(unix: Long): String {
        val f = SimpleDateFormat("yyyy-MM-dd", Locale.US)
        f.timeZone = TimeZone.getTimeZone("UTC")
        return f.format(Date(unix * 1000L))
    }

    /**
     * Signed hour offset of [unix] from [now], worded for a log: "26445h ahead" / "512h behind" / "~now"
     * (within an hour). The magnitude is what tells a future-clock strap (#928) from a stale-clock one.
     */
    fun hoursOffset(unix: Long, now: Long): String {
        val h = (unix - now) / 3600
        return when {
            h > 0 -> "${h}h ahead"
            h < 0 -> "${-h}h behind"
            else -> "~now"
        }
    }

    /**
     * The parenthetical span clause appended to the dropped-record log: " (dated 2028-06-24 -> 2029-07-15,
     * 26445h ahead)". Empty string when nothing was dropped (both null), so the base sentence reads normally.
     * When oldest == newest a single date is shown. [now] words the offset of the NEWEST (frontier) record.
     */
    fun droppedSpanClause(oldest: Long?, newest: Long?, now: Long): String {
        if (oldest == null || newest == null) return ""
        val offset = hoursOffset(newest, now)
        return if (oldest == newest) " (dated ${isoDay(newest)}, $offset)"
        else " (dated ${isoDay(oldest)} -> ${isoDay(newest)}, $offset)"
    }
}
