package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The LineChart tap/drag pinpoint label (#463). The overlay used to draw the RAW plotted value
 * unconditionally, so on Trends' Effort chart a tapped day printed the stored 0-100 figure (a bare
 * "13") beside a 0-21 converted axis. Callers can inject the same formatter the axis uses and
 * prefix a selected daily point with its date; with neither, the raw default is unchanged.
 */
class ChartSelectionLabelTest {

    @Test fun withoutAFormatterTheRawDefaultIsUnchanged() {
        // Near-integer values collapse to the bare integer, the exact "13" the reporter saw.
        assertEquals("13", lineChartSelectionLabel(13.0, null))
        assertEquals("13", lineChartSelectionLabel(12.98, null))
        // Clearly fractional values keep one decimal.
        assertEquals("9.4", lineChartSelectionLabel(9.4, null))
    }

    @Test fun aSuppliedFormatterOwnsTheLabel() {
        val toWhoopScale: (Double) -> String = { UnitFormatter.effortDisplay(it, EffortScale.WHOOP) }
        // The stored 13 renders as 2.7 on the 0-21 display scale, matching the axis column.
        assertEquals("2.7", lineChartSelectionLabel(13.0, toWhoopScale))
    }

    @Test fun theFormatterReceivesThePlottedValueVerbatim() {
        var seen: Double? = null
        lineChartSelectionLabel(41.5, { v -> seen = v; "x" })
        assertEquals(41.5, seen!!, 0.0)
    }

    // Prototype (hr-chart-time-axis): a caller-supplied sample timestamp PREFIXES the local clock
    // time, so the scrub answers "when" — "14:32 · 87 bpm", not a bare value.
    @Test fun aSuppliedTimestampPrefixesTheLocalClockTime() {
        val zone = java.time.ZoneId.of("Europe/Kyiv")   // UTC+3 in July
        val ts = java.time.ZonedDateTime.of(2026, 7, 10, 14, 32, 0, 0, zone).toEpochSecond()
        assertEquals("14:32 · 87 bpm", lineChartSelectionLabel(87.2, { "${it.toInt()} bpm" }, ts, zone))
        // Without a formatter the raw default still carries the time prefix.
        assertEquals("14:32 · 87", lineChartSelectionLabel(87.0, null, ts, zone))
    }

    @Test fun withoutATimestampTheLabelIsUnchanged() {
        assertEquals("87", lineChartSelectionLabel(87.0, null, null))
    }

    @Test fun aSuppliedPointLabelPrefixesTheFormattedValue() {
        assertEquals(
            "16 Jul · 87 bpm",
            lineChartSelectionLabel(
                value = 87.2,
                formatValue = { "${it.toInt()} bpm" },
                pointLabel = "16 Jul",
            ),
        )
    }

    @Test fun aBlankPointLabelLeavesTheValueUnchanged() {
        assertEquals("87", lineChartSelectionLabel(87.0, null, pointLabel = ""))
    }
}
