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

    @Test fun aPlanFromIOSKeepsItsNewerFieldsThroughAnAndroidSave() {
        val raw = """{"goal":"recomp","mode":"advanced","pacePercent":0.5,"form":"highProtein","strength":true,
            "steering":"coached","keep":[],"startDay":"2026-10-13","startWeightKg":92,"adjustmentKcal":0,
            "hideNumbers":false,"pregnantOrNursing":false,"activeDays":true,"burnSource":"scale",
            "recompDeficitPercent":10,"trainingWeekdays":[2,4,6],"dayShift":0.1,"experience":"returning",
            "breakFromDay":"2026-11-03"}"""
        val plan = CoreDietPlan.Plan.parse(raw)!!
        val saved = JSONObject(plan.copy(hideNumbers = true).json())
        assertEquals(true, saved.getBoolean("activeDays"))
        assertEquals("scale", saved.getString("burnSource"))
        assertEquals(10.0, saved.getDouble("recompDeficitPercent"), 0.0)
        assertEquals(3, saved.getJSONArray("trainingWeekdays").length())
        assertEquals(0.1, saved.getDouble("dayShift"), 0.0)
        assertEquals("returning", saved.getString("experience"))
        assertEquals("2026-11-03", saved.getString("breakFromDay"))
    }

    @Test fun brokenJsonIsNoPlan() {
        assertNull(CoreDietPlan.Plan.parse("not json"))
        assertNull(CoreDietPlan.Plan.parse(null))
    }
}
