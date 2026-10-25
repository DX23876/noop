package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ComparePrefsTest {

    @Test
    fun parseSelection_nullWhenNothingStored() {
        assertNull(parseCompareSelection(null, minSelection = 2, maxSelection = 4))
    }

    @Test
    fun parseSelection_restoresSubMinimumWhenAllIdsResolve() {
        val parsed = parseCompareSelection(
            raw = "my-whoop:recovery",
            minSelection = 2,
            maxSelection = 4,
        )

        assertEquals(listOf("my-whoop:recovery"), parsed?.map { it.id })
    }

    @Test
    fun parseSelection_fallsBackWhenResolvedIdsDropBelowMinimum() {
        assertNull(
            parseCompareSelection(
                raw = "my-whoop:missing_metric,my-whoop:removed_metric",
                minSelection = 2,
                maxSelection = 4,
            ),
        )
    }

    @Test
    fun parseSelection_restoresResolvedIdsWhenAtLeastMinimumSurvives() {
        val parsed = parseCompareSelection(
            raw = "my-whoop:recovery,my-whoop:removed_metric,my-whoop:sleep_performance",
            minSelection = 2,
            maxSelection = 4,
        )

        assertEquals(
            listOf("my-whoop:recovery", "my-whoop:sleep_performance"),
            parsed?.map { it.id },
        )
    }

    @Test
    fun parseSelection_dedupsAndCapsAtMaxSelection() {
        val parsed = parseCompareSelection(
            raw = listOf(
                "my-whoop:recovery",
                "my-whoop:recovery",
                "my-whoop:sleep_performance",
                "apple-health:weight",
                "my-whoop:strain",
                "my-whoop:hrv",
            ).joinToString(","),
            minSelection = 2,
            maxSelection = 4,
        )

        assertEquals(
            listOf("my-whoop:recovery", "my-whoop:sleep_performance", "apple-health:weight", "my-whoop:strain"),
            parsed?.map { it.id },
        )
    }
}
