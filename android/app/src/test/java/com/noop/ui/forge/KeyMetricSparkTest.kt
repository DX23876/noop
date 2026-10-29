package com.noop.ui.forge

import org.junit.Assert.assertEquals
import org.junit.Test

/** The detailed tile's line, after iOS `LiquidSparkWindowTests`. */
class KeyMetricSparkTest {
    @Test fun aDenseSeriesKeepsItsWindow() {
        val points = listOf("2026-10-01" to 1.0, "2026-10-20" to 2.0, "2026-10-21" to 3.0, "2026-10-22" to 4.0)
        assertEquals(listOf(2.0, 3.0, 4.0), windowedSpark(points, "2026-10-15", 14))
    }

    @Test fun aSparseSeriesFallsBackToItsLatestMeasurements() {
        val points = listOf("2026-08-01" to 80.0, "2026-09-01" to 79.5, "2026-10-01" to 79.0, "2026-10-22" to 78.8)
        assertEquals(listOf(79.5, 79.0, 78.8), windowedSpark(points, "2026-10-15", 3))
    }
}
