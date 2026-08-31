package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Test

class SleepDebtFormattingTest {

    @Test
    fun nightDetailUsesTenMinuteDebtBoundary() {
        assertEquals("On target", debtCaption(9.9))
        assertEquals(Palette.statusPositive, debtColor(9.9))

        assertEquals("Below need", debtCaption(10.0))
        assertEquals(Palette.statusWarning, debtColor(10.0))
    }

    @Test
    fun importedDebtAboveBoundaryRemainsDebt() {
        assertEquals("Below need", debtCaption(12.5))
        assertEquals(Palette.statusWarning, debtColor(12.5))
    }
}
