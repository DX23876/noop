package com.noop.core

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The plan's JSON must stay what Swift `DietPlan` decodes (`DietPlanTests.testAKotlinPlanDecodes` reads the same shape). */
class CoreDietPlanTest {
    @Test fun aPlanRoundTripsAndLeavesUnsetFieldsOut() {
        val plan = CoreDietPlan.Plan(goal = "lose", mode = "advanced", pacePercent = 0.75, form = "fasting52", addon = "pescatarian",
            strength = true, goalWeightKg = 180.0, keep = listOf("breadAndPasta"), startDay = "2026-11-09", startWeightKg = 200.0)
        val json = JSONObject(plan.json())
        assertEquals("fasting52", json.getString("form"))
        assertFalse(json.has("fixedKcal"))
        assertFalse(json.has("lastAdjustedDay"))
        assertTrue(json.has("adjustmentKcal"))
        assertEquals(plan, CoreDietPlan.Plan.parse(plan.json()))
    }

    @Test fun brokenJsonIsNoPlan() {
        assertNull(CoreDietPlan.Plan.parse("not json"))
        assertNull(CoreDietPlan.Plan.parse(null))
    }
}
