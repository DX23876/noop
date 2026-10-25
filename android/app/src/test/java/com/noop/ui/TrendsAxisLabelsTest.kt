package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Test

class TrendsAxisLabelsTest {

    @Test fun fewerThanTwoDatesHasNoAxisLabels() {
        assertEquals(emptyList<TrendAxisLabel>(), trendAxisLabels(emptyList()))
        assertEquals(emptyList<TrendAxisLabel>(), trendAxisLabels(listOf("2026-07-16")))
    }

    @Test fun twoDatesUseThePlotEndpointsWithoutDuplicatingTheFirstDate() {
        assertEquals(
            listOf(
                TrendAxisLabel("2026-07-15", TrendAxisAnchor.START),
                TrendAxisLabel("2026-07-16", TrendAxisAnchor.END),
            ),
            trendAxisLabels(listOf("2026-07-15", "2026-07-16")),
        )
    }

    @Test fun longerRangesUseStartCenterAndEndAnchors() {
        assertEquals(
            listOf(
                TrendAxisLabel("2026-07-12", TrendAxisAnchor.START),
                TrendAxisLabel("2026-07-14", TrendAxisAnchor.CENTER),
                TrendAxisLabel("2026-07-16", TrendAxisAnchor.END),
            ),
            trendAxisLabels(
                listOf(
                    "2026-07-12",
                    "2026-07-13",
                    "2026-07-14",
                    "2026-07-15",
                    "2026-07-16",
                ),
            ),
        )
    }
}
