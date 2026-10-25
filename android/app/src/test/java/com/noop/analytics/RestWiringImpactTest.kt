package com.noop.analytics

import java.util.Locale
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Faithful Kotlin port of
 * Packages/StrandAnalytics/Tests/StrandAnalyticsTests/RestWiringImpactTests.swift (Wave 0 · SL1/T1,
 * PR #456).
 *
 * Behavioral validation of SL1/T1: score the SAME night for different sleeper HISTORIES and show how
 * Rest moves once real regularity + personalized need replace neutral-0.5 / fixed-8h. Prints an
 * old→new table for eyeballing magnitude/direction, and pins the load-bearing directions. Same
 * inputs and assertions as the Swift test.
 */
class RestWiringImpactTest {

    // One fixed scored night so only (need, consistency) vary: 7h TST, 90% eff, 1h deep, 1.5h REM.
    private val tst = 7.0 * 3600
    private val eff = 0.90
    private val deep = 1.0 * 3600
    private val rem = 1.5 * 3600

    private fun restOld(): Double =
        RestScorer.rest(
            asleepSeconds = tst, efficiency = eff, deepSeconds = deep, remSeconds = rem,
            sleepNeedHours = RestScorer.defaultSleepNeedHours, consistency = null,   // null → neutral 0.5
        )!!

    private data class NewRest(val rest: Double, val need: Double, val cons: Double)

    private fun restNew(history: List<Double>, age: Int?): NewRest {
        val need = RestScorer.personalizedNeedHours(history, age)
        val cons = VitalityEngine.sleepConsistency(history.takeLast(28))
        val rest = RestScorer.rest(
            asleepSeconds = tst, efficiency = eff, deepSeconds = deep, remSeconds = rem,
            sleepNeedHours = need, consistency = cons,
        )!!
        return NewRest(rest, need, cons ?: -1.0)
    }

    @Test
    fun archetypeImpactTable() {
        val regular = List(14) { 8.0 }
        val irregular = (0 until 14).map { if (it % 2 == 0) 5.0 else 10.0 }   // mean 7.5, high variance
        val chronicShort = List(14) { 5.5 }
        val longSleeper = List(14) { 9.2 }

        val old = restOld()
        val reg = restNew(regular, age = 30)
        val irr = restNew(irregular, age = 30)
        val shortS = restNew(chronicShort, age = 30)
        val longS = restNew(longSleeper, age = 30)

        println(String.format(Locale.US, "OLD (neutral 0.5, need 8h):            Rest %5.1f", old))
        println(String.format(Locale.US, "regular good sleeper:  need %.1f cons %.2f  Rest %5.1f", reg.need, reg.cons, reg.rest))
        println(String.format(Locale.US, "irregular sleeper:     need %.1f cons %.2f  Rest %5.1f", irr.need, irr.cons, irr.rest))
        println(String.format(Locale.US, "chronic short (5.5h):  need %.1f cons %.2f  Rest %5.1f", shortS.need, shortS.cons, shortS.rest))
        println(String.format(Locale.US, "long sleeper (9.2h):   need %.1f cons %.2f  Rest %5.1f", longS.need, longS.cons, longS.rest))

        // Load-bearing directions (SL1): a REGULAR history lifts Rest above an IRREGULAR one for the
        // identical night — regularity now actually matters.
        assertTrue(reg.rest > irr.rest)
        // T1: chronic-short need is floored (never collapses toward the 5.5h deficit).
        assertTrue(shortS.need >= 7.0)
        // T1: a genuine long sleeper's need exceeds the old fixed 8h (more demanding duration term).
        assertTrue(longS.need > 8.0)
    }
}
