package com.noop.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The day Swift scores (`CoreStressTests`): Kotlin maps it onto the existing stress result the screen draws. */
class CoreStressTest {
    @Test fun theSwiftDayMapsOntoTheStressResult() {
        val json = javaClass.getResource("/stress/day.json")!!.readText()
        val day = CoreStress.parse(json)!!
        assertFalse(day.usesPersonalBaseline)
        assertTrue(day.result.hours.any { it.level != null })
        assertTrue(day.result.timeline.size >= day.result.hours.size)
        assertEquals(day.result.hours.count { it.maskedForActivity }, day.result.activityMaskedHours)
    }

    @Test fun anErrorIsNoDay() {
        assertNull(CoreStress.parse("""{"error":"x"}"""))
    }
}
