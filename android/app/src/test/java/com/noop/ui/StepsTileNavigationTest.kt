package com.noop.ui

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Pins the conditional Steps-tile destination introduced for #1515. */
class StepsTileNavigationTest {

    @Test
    fun blankUncalibratedFourPointZeroTile_opensCalibration() {
        assertTrue(stepsTileShouldOpenCalibration(null, null, "Connect your phone's step count"))
    }

    @Test
    fun measuredTile_keepsTrendDestination_evenIfPromptWasResolved() {
        assertFalse(stepsTileShouldOpenCalibration(8_432, null, "Connect your phone's step count"))
    }

    @Test
    fun estimatedTile_keepsTrendDestination_evenIfPromptWasResolved() {
        assertFalse(stepsTileShouldOpenCalibration(null, 7_105, "Need 2 more days"))
    }

    @Test
    fun blankTileWithoutCalibrationPrompt_keepsTrendDestination() {
        assertFalse(stepsTileShouldOpenCalibration(null, null, null))
    }
}
