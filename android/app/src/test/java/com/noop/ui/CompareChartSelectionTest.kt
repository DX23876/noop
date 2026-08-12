package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class CompareChartSelectionTest {

    @Test fun emptyOrUnmeasurableChartsHaveNoSelection() {
        assertNull(nearestCompareDayForX(emptyList(), null, null, width = 100f, x = 50f))
        assertNull(
            nearestCompareDayForX(
                listOf("2026-07-16" to 10L),
                minOrd = 10L,
                maxOrd = 10L,
                width = 0f,
                x = 0f,
            ),
        )
    }

    @Test fun aSingleAvailableDayAlwaysWins() {
        val days = listOf("2026-07-16" to 10L)
        assertEquals("2026-07-16", nearestCompareDayForX(days, 10L, 10L, 100f, -50f))
        assertEquals("2026-07-16", nearestCompareDayForX(days, 10L, 10L, 100f, 150f))
    }

    @Test fun selectionUsesThePlottedDateDomainNotTheListIndex() {
        val days = listOf(
            "2026-07-01" to 0L,
            "2026-07-03" to 2L,
            "2026-07-11" to 10L,
        )

        // 40% of the plot is ordinal 4: nearer Jul 3 than Jul 11. Index-based selection would pick Jul 3
        // only by accident here; the second assertion pins the irregular-domain boundary explicitly.
        assertEquals("2026-07-03", nearestCompareDayForX(days, 0L, 10L, 100f, 40f))
        assertEquals("2026-07-03", nearestCompareDayForX(days, 0L, 10L, 100f, 60f))
        assertEquals("2026-07-11", nearestCompareDayForX(days, 0L, 10L, 100f, 61f))
    }

    @Test fun tiesChooseTheEarlierDayAndCoordinatesClampToTheEnds() {
        val days = listOf(
            "2026-07-01" to 0L,
            "2026-07-03" to 2L,
            "2026-07-11" to 10L,
        )

        assertEquals("2026-07-01", nearestCompareDayForX(days, 0L, 10L, 100f, -10f))
        assertEquals("2026-07-03", nearestCompareDayForX(days, 0L, 10L, 100f, 60f))
        assertEquals("2026-07-11", nearestCompareDayForX(days, 0L, 10L, 100f, 120f))
    }
}
