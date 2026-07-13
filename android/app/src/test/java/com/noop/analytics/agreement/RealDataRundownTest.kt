package com.noop.analytics.agreement

import com.noop.analytics.HrvAnalyzer
import org.json.JSONObject
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import kotlin.math.abs

/**
 * Real-data R-R rundown. Replays a user's own captured R-R (from a noop backup) through the three
 * algorithm versions and reports agreement with WHOOP's OWN reported nightly HRV.
 *
 * Base data is a LOCAL fixture exported from the noop backup DB paired to the WHOOP CSV export. It holds
 * personal health biometrics, so it is NOT committed: the test reads it from an absolute path (override
 * with -Dnoop.rrFixture=...) and SKIPS when absent, so it never runs in CI. Real WHOOP labels only exist
 * for the user's own device.
 *
 * Versions (reproduced from the tree's own public functions):
 *   ryanbr / +2PR : mean over 5-min buckets of rmssdRaw(cleanRR(bucket))
 *   rr-opt        : mean over 5-min buckets of rmssdGapAware(cleanRRGapAware(bucket))
 * ryanbr and +2PR are identical on a pre-seq backup: the equal same-second duplicates the seq PK (#163)
 * preserves were already dropped at storage, so that delta is only visible in the synthetic rundown.
 */
class RealDataRundownTest {

    private val fixturePath: String =
        System.getProperty("noop.rrFixture") ?: "C:/Users/DavidGillot/Projects/whoop/whoop data/rr-real-fixture.json"

    private fun nightlyHrv(rr: List<Pair<Long, Int>>, gapAware: Boolean): Double? {
        if (rr.isEmpty()) return null
        val t0 = rr.first().first
        val buckets = LinkedHashMap<Long, ArrayList<Double>>()
        for ((ts, ms) in rr) buckets.getOrPut((ts - t0) / 300L) { ArrayList() }.add(ms.toDouble())
        val vals = ArrayList<Double>()
        for (b in buckets.values) {
            val r = if (gapAware) {
                val c = HrvAnalyzer.cleanRRGapAware(b)
                if (c.nn.size >= 2) HrvAnalyzer.rmssdGapAware(c.nn, c.contiguous) else null
            } else {
                val c = HrvAnalyzer.cleanRR(b)
                if (c.size >= 2) HrvAnalyzer.rmssdRaw(c) else null
            }
            if (r != null) vals.add(r)
        }
        return if (vals.isEmpty()) null else vals.sum() / vals.size
    }

    @Test
    fun realRundown() {
        val f = File(fixturePath)
        assumeTrue("real R-R fixture absent (local-only), skipping: $fixturePath", f.exists())

        val nights = JSONObject(f.readText()).getJSONArray("nights")
        val out = StringBuilder("# R-R real-data rundown (user backup vs WHOOP reported HRV)\n\n")
        out.append("| date | beats | WHOOP | ryanbr/+2PR | rr-opt | ry-err | opt-err |\n")
        out.append("|---|---|---|---|---|---|---|\n")
        var errBase = 0.0; var errOpt = 0.0; var n = 0
        for (i in 0 until nights.length()) {
            val o = nights.getJSONObject(i)
            val rrJson = o.getJSONArray("rr")
            val rr = ArrayList<Pair<Long, Int>>(rrJson.length())
            for (j in 0 until rrJson.length()) {
                val p = rrJson.getJSONArray(j); rr.add(p.getLong(0) to p.getInt(1))
            }
            val whoop = o.getDouble("whoopHrvMs")
            val vBase = nightlyHrv(rr, gapAware = false) ?: continue
            val vOpt = nightlyHrv(rr, gapAware = true) ?: continue
            val eB = abs(vBase - whoop); val eO = abs(vOpt - whoop)
            errBase += eB; errOpt += eO; n += 1
            out.append(
                "| ${o.getString("date")} | ${rr.size} | ${"%.0f".format(whoop)} | ${"%.1f".format(vBase)} | " +
                    "${"%.1f".format(vOpt)} | ${"%.1f".format(eB)} | ${"%.1f".format(eO)} |\n"
            )
        }
        val maeBase = errBase / n; val maeOpt = errOpt / n
        out.append("\n## MAE vs WHOOP reported HRV (ms), $n nights\n\n")
        out.append("| version | MAE |\n|---|---|\n")
        out.append("| ryanbr / +2PR (whole-night, no gap handling) | ${"%.2f".format(maeBase)} |\n")
        out.append("| rr-opt (gap-aware) | ${"%.2f".format(maeOpt)} |\n")
        out.append("\nAll versions read high vs WHOOP: whole-night pooling vs WHOOP's slow-wave-sleep window (rec #3, deep window, is the remaining lever).\n")

        File("build").mkdirs()
        File("build/rr-real-rundown.md").writeText(out.toString())
        println("REAL-RUNDOWN nights=$n maeBase=${"%.2f".format(maeBase)} maeOpt=${"%.2f".format(maeOpt)}")

        assertTrue("gap-aware should not read further from WHOOP than the un-gapped path", maeOpt <= maeBase + 1e-9)
    }
}
