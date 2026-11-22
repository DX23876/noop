package com.noop.ingest

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The steps an import's depth offers, and what a stored value out of that set falls back to. */
class ImportDepthTest {

    @Test
    fun theDefaultIsAYearAndNotTheDecadeTheWindowUsedToBe() {
        assertEquals(ImportDepth.ONE_YEAR, ImportDepth.DEFAULT)
        assertEquals(12L, ImportDepth.DEFAULT.months)
    }

    @Test
    fun theStepsRiseAndTheLongestIsTenYears() {
        val months = ImportDepth.entries.map { it.months }
        assertEquals(listOf(1L, 12L, 36L, 120L), months)
        // Named for what it is. Ten years is the furthest this importer has ever read, which is not the
        // same claim as "everything Health Connect holds".
        assertEquals(120L, ImportDepth.TEN_YEARS.months)
    }

    @Test
    fun aStoredMonthCountResolvesToItsStep() {
        for (step in ImportDepth.entries) {
            assertEquals(step, ImportDepth.ofMonths(step.months))
        }
    }

    @Test
    fun aStoredValueFromAnotherSetOfStepsFallsBackRatherThanFailing() {
        // A build that offered six months would have stored 6. Reading settings must not throw over it.
        assertEquals(ImportDepth.DEFAULT, ImportDepth.ofMonths(6))
        assertEquals(ImportDepth.DEFAULT, ImportDepth.ofMonths(0))
        assertEquals(ImportDepth.DEFAULT, ImportDepth.ofMonths(-1))
        assertEquals(ImportDepth.DEFAULT, ImportDepth.ofMonths(Long.MAX_VALUE))
    }

    @Test
    fun theDefaultIsATenthOfTheOldWindow() {
        // The point of the default: the tester's pass read 2 269 462 records over ten years.
        assertTrue(ImportDepth.TEN_YEARS.months / ImportDepth.DEFAULT.months == 10L)
    }
}
