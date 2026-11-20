package com.noop.ingest

import java.time.Instant
import java.time.ZoneId
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The phone's steps per LOCAL hour, which the core's gap rule (`ActivityCandidates.gapWalks`) asks about:
 * a walk inside a stretch the strap never delivered is offered only when the phone's steps in those hours
 * speak for it. iOS fills the same `appleStepHour` table from HealthKit at hourly granularity, so these pin
 * the Android side of that table, not a rule of its own.
 *
 * Health Connect hands over step records of whatever length the writing app chose, so the split has to be
 * proportional: putting a long record's whole count into the hour it started in would move steps into an
 * hour the wearer was not walking in, which is the hour the rule then asks about.
 */
class HealthConnectHourlyStepsTest {

    private val berlin = ZoneId.of("Europe/Berlin")
    private val kolkata = ZoneId.of("Asia/Kolkata")   // +05:30: a local hour does not start on a unix hour

    private fun spread(fromS: Long, toS: Long, count: Long, zone: ZoneId = berlin): Map<Long, Long> {
        val out = HashMap<Long, Long>()
        HealthConnectImporter.spreadOverHours(Instant.ofEpochSecond(fromS), Instant.ofEpochSecond(toS),
                                              count, zone) { hour, steps ->
            out[hour] = (out[hour] ?: 0L) + steps
        }
        return out
    }

    /** 2026-11-20 10:00:00 +01:00 in Berlin, a local hour start. */
    private val tenInBerlin = Instant.parse("2026-11-20T09:00:00Z").epochSecond

    @Test fun aRecordInsideOneHourStaysWhole() {
        val hours = spread(tenInBerlin + 600, tenInBerlin + 900, 400)
        assertEquals(mapOf(tenInBerlin to 400L), hours)
    }

    @Test fun aRecordAcrossTwoHoursIsSplitByTheTimeInEach() {
        // Fifteen minutes before the hour, forty-five after: a quarter and three quarters of 800.
        val hours = spread(tenInBerlin - 900, tenInBerlin + 2_700, 800)
        assertEquals(200L, hours[tenInBerlin - 3_600])
        assertEquals(600L, hours[tenInBerlin])
        assertEquals(800L, hours.values.sum())
    }

    @Test fun theLastHourTakesTheRoundingLeftoverSoThePartsAddUp() {
        val hours = spread(tenInBerlin, tenInBerlin + 3 * 3_600, 1_000)
        assertEquals(1_000L, hours.values.sum())
        assertEquals(3, hours.size)
    }

    @Test fun aZeroLengthRecordBelongsToTheHourItStartsIn() {
        val at = tenInBerlin + 1_234
        assertEquals(mapOf(tenInBerlin to 250L), spread(at, at, 250))
    }

    @Test fun hoursComeFromTheZoneNotFromUnixArithmetic() {
        // 10:00 local in Kolkata is 04:30 UTC, so the hour key is NOT a multiple of 3600.
        val tenInKolkata = Instant.parse("2026-11-20T04:30:00Z").epochSecond
        val hours = spread(tenInKolkata + 60, tenInKolkata + 120, 90, kolkata)
        assertEquals(mapOf(tenInKolkata to 90L), hours)
        assertTrue("a local hour in a half-hour zone does not start on a unix hour",
                   tenInKolkata % 3_600L != 0L)
    }

    @Test fun aRecordTooLongToPlaceInAnHourIsLeftOut() {
        // Beyond the window the split will speak for: no honest hour can be named, and the day total has
        // it anyway.
        val span = (HealthConnectImporter.MAX_HOURLY_SPREAD_HOURS + 1) * 3_600L
        assertTrue(spread(tenInBerlin, tenInBerlin + span, 10_000).isEmpty())
        assertTrue(spread(tenInBerlin, tenInBerlin + 600, 0).isEmpty())
    }
}
