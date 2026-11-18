package com.noop.ui.forge

import com.noop.core.CoreTraining
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The Strength fill of the muscle figure (#52).
 *
 * Reported with the figure fully grey while the list under it showed "+X.X % per week" for twelve
 * muscles. The merge compared `abs(slope) >= abs(merged[slug] ?: -1.0)`, so the sentinel for "nothing
 * stored yet" became a threshold of 1.0 once `abs` had been applied to it. Real normalized slopes run
 * around 0.01 to 0.08 a week, so no reading ever passed and nothing was ever painted.
 *
 * The numbers below are the reporter's own: about +0.9 % to +8.1 % per week.
 */
class StrengthMuscleFillTest {

    private fun reading(id: String, slope: Double?, direction: String = "increasing") =
        CoreTraining.Strength(muscleId = id, slopePerWeek = slope, direction = direction, exercises = emptyList())

    @Test
    fun `a real weekly slope reaches the figure`() {
        val fills = strengthSlopesByFigureMuscle(listOf(
            reading("quadriceps", 0.009), reading("biceps", 0.081), reading("calves", 0.03)))
        assertEquals(3, fills.size)
        assertTrue("a slope far below 1.0 a week must still paint", fills.values.all { it > 0.0 })
    }

    @Test
    fun `the steepest reading wins where several share one figure muscle`() {
        // lats and upper back both land on the figure's upper-back; the larger magnitude decides the colour.
        val fills = strengthSlopesByFigureMuscle(listOf(
            reading("lats", 0.02), reading("upper_back", -0.06, direction = "decreasing")))
        assertEquals(mapOf("upper-back" to -0.06), fills)
    }

    @Test
    fun `a reading without a direction or a slope paints nothing`() {
        val fills = strengthSlopesByFigureMuscle(listOf(
            reading("chest", 0.05, direction = "unclear"),
            reading("lats", 0.05, direction = "insufficientEvidence"),
            reading("abdominals", null)))
        assertTrue("nothing to say means nothing to paint", fills.isEmpty())
    }
}
