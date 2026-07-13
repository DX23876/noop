package com.noop.analytics.agreement

import com.noop.analytics.HrvAnalyzer
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.util.Random
import kotlin.math.abs
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * R-R version rundown. Replays identical synthetic sleep windows through the THREE algorithm versions
 * and reports how each one's computed RMSSD deviates from the clean-rhythm reference.
 *
 * Each version is reproduced from the CURRENT tree's own public functions, so every column is the real
 * noop code path, not a re-implementation:
 *   ryanbr base : rmssdRaw(cleanRR( dedup-by-(ts,rrMs) ))       old PK+IGNORE drops equal same-second beats, no gap handling
 *   + 2 PRs     : rmssdRaw(cleanRR( all beats ))                seq PK keeps duplicates (#163), still splices across a dropped beat
 *   rr-opt      : rmssdGapAware(cleanRRGapAware( all beats ))   keeps duplicates AND skips the successive diff across a dropped beat
 *
 * Reference = RMSSD of the artifact-free rounded RR (the true rhythm). This is a synthetic yardstick,
 * NOT a WHOOP label: real WHOOP agreement needs a captured R-R night paired to the WHOOP CSV export,
 * which slots into the same report once available.
 *
 * The test writes build/rr-rundown.md and asserts the accuracy ordering improves monotonically
 * (ryanbr error >= +2PR error >= rr-opt error) across the whole set.
 */
class RrVersionRundownTest {

    private data class Beat(val ts: Long, val rrMs: Int)

    private fun rmssd(x: List<Double>): Double = HrvAnalyzer.rmssdRaw(x) ?: Double.NaN

    /** Old storage: PK (deviceId,ts,rrMs) + INSERT IGNORE keeps the first (ts,rrMs) and drops the rest. */
    private fun dedupTsRr(beats: List<Beat>): List<Beat> {
        val seen = HashSet<Pair<Long, Int>>()
        val out = ArrayList<Beat>(beats.size)
        for (b in beats) if (seen.add(b.ts to b.rrMs)) out.add(b)
        return out
    }

    private fun vRyanbr(beats: List<Beat>): Double =
        rmssd(HrvAnalyzer.cleanRR(dedupTsRr(beats).map { it.rrMs.toDouble() }))

    private fun vTwoPr(beats: List<Beat>): Double =
        rmssd(HrvAnalyzer.cleanRR(beats.map { it.rrMs.toDouble() }))

    private fun vRrOpt(beats: List<Beat>): Double {
        val c = HrvAnalyzer.cleanRRGapAware(beats.map { it.rrMs.toDouble() })
        return HrvAnalyzer.rmssdGapAware(c.nn, c.contiguous) ?: Double.NaN
    }

    /**
     * One ~5-minute sleep window. Builds a clean rhythm (respiratory sinus arrhythmia + slow drift +
     * noise), forces [nEqualDup] real equal same-second pairs into the true rhythm (the exact structure
     * the old PK drops), computes the reference over that true rhythm, then adds [nEctopic] out-of-range
     * beats (the optical artifacts cleaning removes). Returns the captured stream and the reference RMSSD.
     */
    private fun genWindow(seed: Long, nBeats: Int, baseRr: Double, nEqualDup: Int, nEctopic: Int): Pair<List<Beat>, Double> {
        val rng = Random(seed)
        val beats = ArrayList<Beat>(nBeats)
        var tSec = 0.0
        for (i in 0 until nBeats) {
            val rsa = 35.0 * sin(2.0 * Math.PI * i / 12.0)      // ~breathing modulation
            val drift = 20.0 * sin(2.0 * Math.PI * i / 400.0)   // slow trend
            val noise = rng.nextGaussian() * 12.0
            val rr = (baseRr + rsa + drift + noise).coerceIn(600.0, 1300.0)
            tSec += rr / 1000.0
            beats.add(Beat(tSec.toLong(), rr.roundToInt()))
        }
        // Force real equal same-second pairs into the TRUE rhythm: the next beat shares ts AND rrMs, a
        // genuine zero-difference interval that the old PK+IGNORE silently drops (biasing RMSSD high).
        repeat(nEqualDup) {
            val idx = rng.nextInt(beats.size - 1)
            val b = beats[idx]
            beats[idx + 1] = Beat(b.ts, b.rrMs)
        }
        val reference = rmssd(beats.map { it.rrMs.toDouble() })
        // The captured stream adds optical artifacts (out of range), removed by the range filter.
        val captured = ArrayList(beats)
        repeat(nEctopic) {
            val idx = 1 + rng.nextInt(captured.size - 2)
            captured[idx] = captured[idx].copy(rrMs = 5000)
        }
        return captured to reference
    }

    @Test
    fun rundown() {
        val rows = StringBuilder()
        rows.append("# R-R version rundown (synthetic reference nights)\n\n")
        rows.append("Reference = RMSSD of the artifact-free true rhythm. Values in ms. err = |version - reference|.\n\n")
        rows.append("| # | baseRR | dup | ect | ref | ryanbr | err | +2PR | err | rr-opt | err |\n")
        rows.append("|---|---|---|---|---|---|---|---|---|---|---|\n")

        var sumRef = 0.0
        var errRyanbr = 0.0
        var errTwoPr = 0.0
        var errRrOpt = 0.0
        val n = 24
        for (i in 0 until n) {
            val baseRr = 900.0 + (i % 6) * 50.0            // 900..1150 ms (52..67 bpm)
            val nBeats = (300000.0 / baseRr).roundToInt()  // ~5 minutes of beats
            val dup = 3 + (i % 5) * 2                        // 3..11 equal same-second pairs
            val ect = 2 + (i % 4) * 2                        // 2..8 out-of-range artifacts
            val (beats, ref) = genWindow(seed = 1000L + i, nBeats = nBeats, baseRr = baseRr, nEqualDup = dup, nEctopic = ect)
            val vR = vRyanbr(beats); val vP = vTwoPr(beats); val vO = vRrOpt(beats)
            sumRef += ref; errRyanbr += abs(vR - ref); errTwoPr += abs(vP - ref); errRrOpt += abs(vO - ref)
            rows.append(
                "| ${i + 1} | ${baseRr.roundToInt()} | $dup | $ect | ${f(ref)} | ${f(vR)} | ${f(abs(vR - ref))} | " +
                    "${f(vP)} | ${f(abs(vP - ref))} | ${f(vO)} | ${f(abs(vO - ref))} |\n"
            )
        }
        val maeR = errRyanbr / n; val maeP = errTwoPr / n; val maeO = errRrOpt / n
        rows.append("\n## Mean absolute error vs true rhythm (ms), over $n windows\n\n")
        rows.append("| version | MAE | vs ryanbr |\n|---|---|---|\n")
        rows.append("| ryanbr base | ${f(maeR)} | - |\n")
        rows.append("| + 2 PRs (seq #163) | ${f(maeP)} | ${pct(maeR, maeP)} |\n")
        rows.append("| rr-opt (gap-aware) | ${f(maeO)} | ${pct(maeR, maeO)} |\n")
        rows.append("\nMean reference RMSSD ${f(sumRef / n)} ms.\n")

        File("build").mkdirs()
        val out = File("build/rr-rundown.md")
        out.writeText(rows.toString())
        println("RR-RUNDOWN written to ${out.absolutePath}")
        println("MAE ryanbr=${f(maeR)} +2PR=${f(maeP)} rr-opt=${f(maeO)}")

        // Accuracy must improve monotonically as each fix lands.
        assertTrue("seq fix should not worsen error", maeP <= maeR + 1e-9)
        assertTrue("gap-aware should not worsen error", maeO <= maeP + 1e-9)
        assertTrue("rr-opt should be the most accurate", maeO <= maeR + 1e-9)
    }

    private fun f(x: Double): String = if (x.isNaN()) "nan" else String.format("%.2f", x)
    private fun pct(base: Double, v: Double): String =
        if (base <= 0) "-" else String.format("%+.1f%%", (v - base) / base * 100.0)

    // keep sqrt import used if inlined later
    @Suppress("unused") private fun rms(x: DoubleArray): Double = sqrt(x.map { it * it }.average())
}
