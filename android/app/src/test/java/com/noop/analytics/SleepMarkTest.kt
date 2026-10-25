package com.noop.analytics

import com.noop.data.MetricSeriesRow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #461 Phase 1 — sleep-marks. Kotlin twin of StrandTests/SleepMarkTests.swift. Covers the pure
 * encode/decode logic and the persistence round-trip: write a mark through the SAME
 * (deviceId, day, key) upsert semantics the metricSeries table uses, read the "sleep_mark" series
 * back out, and decode it to the original type. No Room/Robolectric — a FakeSeries reproduces the
 * upsert + range-query contract exactly, mirroring MoodStoreTest.
 */
class SleepMarkTest {

    /** In-memory metricSeries: upsert overwrites on the (deviceId, day, key) natural key; query
     *  filters by deviceId+key+inclusive day range (lexicographic, like SQLite). */
    private class FakeSeries {
        val rows = LinkedHashMap<Triple<String, String, String>, MetricSeriesRow>()

        fun upsert(newRows: List<MetricSeriesRow>) {
            for (r in newRows) rows[Triple(r.deviceId, r.day, r.key)] = r
        }

        fun query(deviceId: String, key: String, from: String, to: String): List<MetricSeriesRow> =
            rows.values
                .filter { it.deviceId == deviceId && it.key == key && it.day >= from && it.day <= to }
                .sortedBy { it.day }
    }

    // MARK: - Pure encoding

    @Test
    fun typeEncodesToZeroAndOne() {
        assertEquals(0, SleepMarkType.BEDTIME.seriesValue)
        assertEquals(1, SleepMarkType.WAKE.seriesValue)
    }

    @Test
    fun typeDecodeIsTolerant() {
        assertEquals(SleepMarkType.BEDTIME, SleepMarkType.fromSeriesValue(0.0))
        assertEquals(SleepMarkType.WAKE, SleepMarkType.fromSeriesValue(1.0))
        // Float drift rounds to the nearest valid case; out-of-range clamps to bedtime.
        assertEquals(SleepMarkType.WAKE, SleepMarkType.fromSeriesValue(0.999))
        assertEquals(SleepMarkType.BEDTIME, SleepMarkType.fromSeriesValue(0.001))
        assertEquals(SleepMarkType.BEDTIME, SleepMarkType.fromSeriesValue(7.0))
    }

    @Test
    fun metricPointCarriesKeyDayAndValue() {
        val mark = SleepMark(SleepMarkType.WAKE, 1_710_000_000_000L)
        val row = mark.metricPoint("my-whoop")
        assertEquals("my-whoop", row.deviceId)
        assertEquals("sleep_mark", row.key)
        assertEquals(1.0, row.value, 0.0)
        assertEquals(mark.dayKey, row.day)
    }

    @Test
    fun logLineIsHumanReadableAndTyped() {
        val bed = SleepMark(SleepMarkType.BEDTIME, 1_710_000_000_000L).logLine()
        val wake = SleepMark(SleepMarkType.WAKE, 1_710_000_000_000L).logLine()
        assertTrue(bed, bed.startsWith("Sleep mark · bedtime"))
        assertTrue(bed, bed.contains("going to sleep"))
        assertTrue(wake, wake.startsWith("Sleep mark · wake"))
        assertTrue(wake, wake.contains("awake"))
        assertTrue(bed, bed.contains("@"))
    }

    @Test
    fun fromRowRejectsForeignKey() {
        val foreign = MetricSeriesRow(deviceId = "my-whoop", day = "2024-03-09", key = "steps", value = 1.0)
        assertNull(SleepMark.fromRow(foreign))
    }

    // MARK: - Persistence round-trip (write -> read the series back)

    @Test
    fun markPersistenceRoundTrip() {
        val fake = FakeSeries()
        val deviceId = "my-whoop"

        val bedMark = SleepMark(SleepMarkType.BEDTIME, 1_710_000_000_000L)  // some day D
        val wakeMark = SleepMark(SleepMarkType.WAKE, 1_710_086_400_000L)    // D + 1 day

        fake.upsert(listOf(bedMark.metricPoint(deviceId)))
        fake.upsert(listOf(wakeMark.metricPoint(deviceId)))

        val points = fake.query(deviceId, "sleep_mark", "0000-00-00", "9999-99-99")
        assertEquals("two distinct days -> two rows", 2, points.size)

        val decoded = points.mapNotNull { SleepMark.fromRow(it) }
        assertEquals(2, decoded.size)
        val byDay = decoded.associate { it.dayKey to it.type }
        assertEquals(SleepMarkType.BEDTIME, byDay[bedMark.dayKey])
        assertEquals(SleepMarkType.WAKE, byDay[wakeMark.dayKey])
    }

    @Test
    fun sameDayUpsertReplacesValueInPlace() {
        val fake = FakeSeries()
        val deviceId = "my-whoop"

        // Two marks the SAME calendar day: the natural key (deviceId, day, key) means the second
        // upsert overwrites the first's value — last-wins, one row. (The strap log keeps the full
        // sequence; this asserts the documented Phase-1 store behaviour.)
        val base = 1_710_000_000_000L
        val first = SleepMark(SleepMarkType.BEDTIME, base)
        val second = SleepMark(SleepMarkType.WAKE, base + 60_000L)  // 1 min later, same day
        assertEquals("fixture must be same-day", first.dayKey, second.dayKey)

        fake.upsert(listOf(first.metricPoint(deviceId)))
        fake.upsert(listOf(second.metricPoint(deviceId)))

        val points = fake.query(deviceId, "sleep_mark", "0000-00-00", "9999-99-99")
        assertEquals("same day upserts to one row", 1, points.size)
        assertEquals(SleepMarkType.WAKE, SleepMark.fromRow(points[0])?.type)
    }
}
