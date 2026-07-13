package com.noop.analytics.agreement

import com.noop.analytics.RecoveryScorer
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File

/**
 * Recovery-formula correctness / regression pin. Feeds diverse driver-input cases through
 * [RecoveryScorer.recovery] and asserts each matches an INDEPENDENT numpy replication of the exact
 * z-score + logistic composite (recovery_cases.json). Recovery is noop-defined (no external gold —
 * WHOOP's model is proprietary), so this validates internal consistency and PINS all 11 constants
 * (driver weights, logistic K/Z0, sleep centre/scale, skin-temp scale, the 1.253 spread factor) against
 * silent regressions, plus the null semantics (cold-start, dropped-term renormalisation).
 *
 * Local fixture generated from the exact formula; test SKIPS when absent (override -Dnoop.hrvGoldFixtures).
 */
class RecoveryAgreementTest {

    private val path: String = (System.getProperty("noop.hrvGoldFixtures")
        ?: "C:/Users/DavidGillot/Projects/whoop/whoop data/datasets/agreement-fixtures") + "/recovery_cases.json"

    private fun baseline(o: JSONObject, meanKey: String, spreadKey: String): RecoveryScorer.DriverBaseline? =
        if (o.isNull(meanKey)) null
        else RecoveryScorer.DriverBaseline(mean = o.getDouble(meanKey), spread = o.getDouble(spreadKey))

    private fun optD(o: JSONObject, k: String): Double? = if (o.isNull(k)) null else o.getDouble(k)

    @Test
    fun recoveryMatchesReferenceFormulaAcrossCases() {
        val f = File(path)
        assumeTrue("recovery fixture absent (local-only), skipping: $path", f.exists())
        val arr = org.json.JSONArray(f.readText())

        var scored = 0
        var maxErr = 0.0
        for (i in 0 until arr.length()) {
            val c = arr.getJSONObject(i)
            val got = RecoveryScorer.recovery(
                hrv = c.getDouble("hrv"),
                rhr = c.getDouble("rhr"),
                resp = optD(c, "resp"),
                hrvBaseline = baseline(c, "hrvBaselineMean", "hrvBaselineSpread"),
                rhrBaseline = baseline(c, "rhrBaselineMean", "rhrBaselineSpread"),
                respBaseline = baseline(c, "respBaselineMean", "respBaselineSpread"),
                sleepPerf = optD(c, "sleepPerf"),
                skinTempDev = optD(c, "skinTempDev"),
                hrvBaselineUsable = c.getBoolean("hrvBaselineUsable"),
            )
            if (c.isNull("expectedRecovery")) {
                assertNull("case $i expected null recovery", got)
            } else {
                val exp = c.getDouble("expectedRecovery")
                requireNotNull(got) { "case $i: noop returned null, expected $exp" }
                assertEquals("case $i recovery", exp, got, 1e-6)
                maxErr = maxOf(maxErr, kotlin.math.abs(exp - got))
            }
            scored++
        }
        assertTrue("no cases scored", scored > 0)
        println("[recovery] $scored cases pinned (incl null-semantics), maxErr=$maxErr")
    }
}
