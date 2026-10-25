package com.noop.analytics.agreement

import com.noop.analytics.HrvAnalyzer
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import kotlin.math.abs

/**
 * M2 (R-R optimization): HRV math vs GOLD beat-to-beat R-R.
 *
 * Feeds clean NN series derived from public GOLD datasets (GalaxyPPG Polar H10 chest belt, AAUWSS
 * Empatica E4 wrist IBI, AAUWSS PSG 200 Hz ECG) into noop's [HrvAnalyzer] and asserts RMSSD / SDNN /
 * pNN50 match an INDEPENDENT numpy textbook reference computed on the identical NN series to 1e-6. This
 * proves noop's HRV math is a correct Task Force (1996) implementation, independent of any WHOOP label.
 *
 * The NN in each fixture is already range-cleaned, so feeding it through the pure primitives
 * (rmssdRaw / sdnnRaw / pnn50GapAware with all-contiguous flags) isolates the FORMULA — no cleaning,
 * no gap logic — which is exactly what a math-correctness check needs.
 *
 * Fixtures are generated locally from the public datasets and are NOT committed (public research data,
 * kept out of the tree). The test SKIPS when the fixture dir is absent so CI stays green; override with
 * -Dnoop.hrvGoldFixtures=<dir>.
 */
class HrvGoldAgreementTest {

    private val dir: String = System.getProperty("noop.hrvGoldFixtures")
        ?: "C:/Users/DavidGillot/Projects/whoop/whoop data/datasets/agreement-fixtures"

    private val tol = 1e-6

    @Test
    fun rmssdSdnnPnn50MatchTextbookReferenceOnGoldRr() {
        val fixtures = File(dir).listFiles { f -> f.extension == "json" }?.sortedBy { it.name }.orEmpty()
        assumeTrue("gold HRV fixtures absent (local-only), skipping: $dir", fixtures.isNotEmpty())

        var windows = 0
        var maxRmssdErr = 0.0
        var maxSdnnErr = 0.0
        var maxPnnErr = 0.0
        val perSource = StringBuilder()

        for (f in fixtures) {
            val text = f.readText().trimStart()
            if (!text.startsWith("{")) continue          // skip array fixtures (recovery_cases / hrv_freq_cases have their own tests)
            val obj = JSONObject(text)
            if (!obj.has("windows")) continue
            val src = obj.optString("source", f.nameWithoutExtension)
            val ws = obj.getJSONArray("windows")
            var srcWin = 0
            for (i in 0 until ws.length()) {
                val w = ws.getJSONObject(i)
                if (!w.has("refRmssd")) continue          // skip non-gold windows (whoop5-real carries a WHOOP-model ref, not a computed gold ref)
                val nnArr = w.getJSONArray("nn")
                if (nnArr.length() < 2) continue
                val nn = ArrayList<Double>(nnArr.length())
                for (j in 0 until nnArr.length()) nn.add(nnArr.getDouble(j))
                val contiguous = List(nn.size) { it > 0 } // fully clean series -> every successive pair valid

                val rmssd = HrvAnalyzer.rmssdRaw(nn)!!
                val sdnn = HrvAnalyzer.sdnnRaw(nn)!!
                val pnn50 = HrvAnalyzer.pnn50GapAware(nn, contiguous)!!

                val refR = w.getDouble("refRmssd")
                val refS = w.getDouble("refSdnn")
                val refP = w.getDouble("refPnn50")
                assertEquals("$src window $i RMSSD", refR, rmssd, tol)
                assertEquals("$src window $i SDNN", refS, sdnn, tol)
                assertEquals("$src window $i pNN50", refP, pnn50, tol)

                maxRmssdErr = maxOf(maxRmssdErr, abs(refR - rmssd))
                maxSdnnErr = maxOf(maxSdnnErr, abs(refS - sdnn))
                maxPnnErr = maxOf(maxPnnErr, abs(refP - pnn50))
                windows++
                srcWin++
            }
            perSource.append("$src=$srcWin ")
        }

        assertTrue("no gold windows scored (fixtures present but empty)", windows > 0)
        println("[M2] gold-RR HRV agreement: $windows windows [${perSource.toString().trim()}] " +
            "maxErr rmssd=$maxRmssdErr sdnn=$maxSdnnErr pnn50=$maxPnnErr")
    }
}
