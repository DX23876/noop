package com.noop.ui

import com.noop.R
import com.noop.data.WhoopRepository
import java.time.LocalDate
import java.util.Locale
import kotlin.math.roundToInt
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The readings table under a series-backed vital detail (task #8). Pins the pure projection
 * [vitalReadingRows] the VitalDetailScreen table renders: rows and the "N readings" header derive from the
 * SAME windowed list (so their counts can't disagree), rows are NEWEST-FIRST, each raw source id resolves
 * through the shared [provenanceDisplayLabel] (strap → "Whoop", Health Connect → "Health Connect", Apple
 * Health → "Apple Health", the "-noop" sibling → "On-device"), and each value reuses the model's own
 * formatter + unit. Blood Oxygen (SpO2) is the acceptance case.
 */
class VitalReadingsTableTest {

    private val strap = WhoopRepository.WHOOP_SOURCE            // "my-whoop"
    private val healthConnect = WhoopRepository.HEALTH_CONNECT_SOURCE  // "health-connect"
    private val appleHealth = WhoopRepository.APPLE_HEALTH_SOURCE      // "apple-health"

    // Blood Oxygen: %-formatted, ascending readings from three different sources — a strap reading, a
    // Health Connect import (e.g. a Galaxy Watch), and an Apple Health import.
    private val spo2Readings = listOf(
        VitalReading("2026-01-01", 96.0, strap),
        VitalReading("2026-01-02", 95.0, healthConnect),
        VitalReading("2026-01-03", 97.0, appleHealth),
    )
    private val spo2Format: (Double) -> String = { String.format(Locale.US, "%.0f", it) }

    @Test fun rowCountEqualsReadingsCount() {
        val rows = vitalReadingRows(spo2Readings, "%", strap, spo2Format)
        assertEquals(spo2Readings.size, rows.size)
    }

    @Test fun rowsAreNewestFirst() {
        val rows = vitalReadingRows(spo2Readings, "%", strap, spo2Format)
        // Ascending input (01 → 03) must render descending (03 → 01).
        assertEquals(listOf("Sat 3 Jan", "Fri 2 Jan", "Thu 1 Jan"), rows.map { it.time })
        assertEquals("97 %", rows.first().value)   // the newest reading leads
    }

    @Test fun readingDatesShowWeekdaysIncludingTodayAndYesterday() {
        val today = LocalDate.parse("2026-09-30")
        assertEquals("Today · Wed", vitalReadingDateLabel("2026-09-30", today, Locale.US))
        assertEquals("Yesterday · Tue", vitalReadingDateLabel("2026-09-29", today, Locale.US))
        assertEquals("Sat 26 Sep", vitalReadingDateLabel("2026-09-26", today, Locale.US))
        assertEquals("bad-day", vitalReadingDateLabel("bad-day", today, Locale.US))
    }

    @Test fun sourceLabelsResolvePerSample() {
        val rows = vitalReadingRows(spo2Readings, "%", strap, spo2Format)
        // Newest-first, so: Apple Health (03), Health Connect (02), Whoop strap (01).
        assertEquals(
            listOf(
                DisplayText.Resource(R.string.today_source_apple_health),
                DisplayText.Resource(R.string.today_source_health_connect),
                DisplayText.Resource(R.string.today_source_whoop),
            ),
            rows.map { it.source },
        )
    }

    @Test fun computedStrapSiblingReadsOnDevice() {
        val rows = vitalReadingRows(
            listOf(VitalReading("2026-01-04", 55.0, "$strap-noop")),
            "yrs",
            strap,
            { it.roundToInt().toString() },
        )
        assertEquals(DisplayText.Resource(R.string.today_source_on_device), rows.single().source)
    }

    /**
     * #103/queue-11a follow-up: a spo2 candidate-fallback row (see [SPO2_CANDIDATE_ATTRIBUTION_SOURCE])
     * must resolve to "strap estimate (unverified)" — the SAME caption every other candidate-fallback
     * surface uses — never a device name, which would misrepresent an unvalidated estimate as a
     * calibrated reading.
     */
    @Test fun spo2CandidateSourceReadsStrapEstimateUnverified() {
        val rows = vitalReadingRows(
            listOf(VitalReading("2026-08-24", 97.0, SPO2_CANDIDATE_ATTRIBUTION_SOURCE)),
            "%",
            strap,
            spo2Format,
        )
        assertEquals(DisplayText.Resource(R.string.spo2_strap_estimate_caption), rows.single().source)
    }

    @Test fun valueReusesModelFormatAndUnit() {
        // The row value is the model's own formatter applied to the reading, with the unit appended —
        // 41.7 ms rounds to "42 ms".
        val rows = vitalReadingRows(
            listOf(VitalReading("2026-01-01", 41.7, strap)),
            "ms",
            strap,
            { it.roundToInt().toString() },
        )
        assertEquals("42 ms", rows.single().value)
    }

    @Test fun unitlessMetricLeavesNoTrailingSpace() {
        // Vitality has an empty unit; the value must not carry a dangling space.
        val rows = vitalReadingRows(
            listOf(VitalReading("2026-01-01", 72.0, "$strap-noop")),
            "",
            strap,
            { it.roundToInt().toString() },
        )
        assertEquals("72", rows.single().value)
    }

    @Test fun tableRowsUseTheProductionWindowInEveryRange() {
        val readings = (0 until 400).map {
            VitalReading(LocalDate.parse("2026-01-01").plusDays(it.toLong()).toString(), 60.0 + it, strap)
        }
        VitalDetailRange.entries.forEach { range ->
            val expected = range.days?.let { readings.takeLast(it.toInt()) } ?: readings
            val window = filterVitalReadings(readings, range)
            assertEquals(expected, window)
            val rows = vitalReadingRows(window, "%", strap, spo2Format)
            assertEquals(expected.size, rows.size)
            assertEquals(expected.reversed().map { "${spo2Format(it.value)} %" }, rows.map { it.value })
        }
    }
}

/**
 * A night read in minutes. "526 min" is a true figure nobody reads as eight and three quarter hours,
 * reported on 2026-11-17. Twin of `VitalReadingsTableTests` on Apple.
 */
class VitalReadingDurationTest {

    private fun rows(value: Double, unit: String) = vitalReadingRows(
        readings = listOf(VitalReading(day = "2026-01-01", value = value, source = "my-whoop")),
        unit = unit,
        strapDeviceId = "my-whoop",
        format = { String.format(java.util.Locale.US, "%.0f", it) },
    )

    @org.junit.Test
    fun `a minute reading past an hour reads as hours and minutes`() {
        org.junit.Assert.assertEquals("8h 46m", rows(526.0, "min").first().value)
    }

    @org.junit.Test
    fun `under an hour it stays in minutes`() {
        org.junit.Assert.assertEquals("47 min", rows(47.0, "min").first().value)
    }

    @org.junit.Test
    fun `an exact hour says both parts`() {
        org.junit.Assert.assertEquals("1h 0m", rows(60.0, "min").first().value)
    }

    @org.junit.Test
    fun `other units are untouched`() {
        org.junit.Assert.assertEquals("96 %", rows(96.0, "%").first().value)
    }
}

/**
 * The share each row carries for its hairline, and the one duration rule the whole metric page asks.
 * Swift twins: `VitalReadingShareTests` and `MetricDurationSpellingTests`.
 */
class VitalReadingShareTest {

    private fun rows(values: List<Double>) = vitalReadingRows(
        readings = values.mapIndexed { i, v ->
            VitalReading(day = String.format(Locale.US, "2026-01-%02d", i + 1), value = v, source = "my-whoop")
        },
        unit = "",
        strapDeviceId = "my-whoop",
        format = { String.format(Locale.US, "%.0f", it) },
    )

    /** Newest first, so the LAST reading is the first row; the window's lowest sits at 0, its highest at 1. */
    @Test
    fun `the lowest is empty and the highest is full`() {
        val out = rows(listOf(400.0, 500.0, 450.0))
        assertEquals(listOf("450", "500", "400"), out.map { it.value })
        assertEquals(0.5, out[0].share, 0.0001)
        assertEquals(1.0, out[1].share, 0.0001)
        assertEquals(0.0, out[2].share, 0.0001)
    }

    /** A window where nothing moved has no position to state, so every row draws the bare track. */
    @Test
    fun `a flat window states nothing`() {
        assertEquals(listOf(0.0, 0.0, 0.0), rows(listOf(420.0, 420.0, 420.0)).map { it.share })
    }

    @Test
    fun `one reading is flat too`() {
        assertEquals(0.0, rows(listOf(443.0)).first().share, 0.0)
    }

    @Test
    fun `a minute metric past an hour is spelled out`() {
        assertEquals("7h 23m", metricDurationSpelling("min", 443.0))
        assertEquals("1h 0m", metricDurationSpelling("min", 60.0))
    }

    @Test
    fun `under an hour and other units decline`() {
        assertEquals(null, metricDurationSpelling("min", 59.0))
        assertEquals(null, metricDurationSpelling("%", 96.0))
        assertEquals(null, metricDurationSpelling("", 443.0))
    }
}
