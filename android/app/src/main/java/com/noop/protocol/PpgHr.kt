package com.noop.protocol

/**
 * Derive heart rate from the WHOOP 5.0/MG **v26** optical PPG waveform (#156).
 *
 * The strap's type-47 **layout v26** record is a 24 Hz PPG buffer — NOT a per-second biometric
 * summary like v18: **24 little-endian i16 samples at frame bytes [27:75]**, one record per second,
 * with the record's own unix u32 LE @15 (the same slot v18 uses). WHOOP does NOT store a per-second
 * HR in v26 — HR is PPG-derived on-device — so to recover HR we re-derive it here from the waveform,
 * **byte-for-byte mirroring the Swift estimator** (WhoopProtocol/PpgHr.swift) so macOS, iOS and
 * Android produce the SAME per-second HR from the same offload. (Provenance: the concatenated
 * waveform's autocorrelation peaks at the heart rate; verified against measured HR as internal
 * ground truth — lag 14 ≈ 102.9 bpm vs a measured 101.7 bpm.)
 *
 * Algorithm (kept in lockstep with the Swift lane — #219 parity audit):
 *   • Records are grouped into **consecutive-second runs** (PPG phase is only continuous within a
 *     run); a window of the seconds present in `t-half … t+half` (half = WINDOW_SECONDS/2) is
 *     autocorrelated, one estimate per second whose centred window holds ≥ 3 seconds.
 *   • Per window: **linear least-squares detrend** (removes DC *and* baseline wander), then
 *     normalised autocorrelation over the lag band that maps to **30…220 bpm**.
 *   • **Fundamental-period preference**: pick the smallest-lag local maximum that is ≥ 0.85× the
 *     global peak, so the harmonic peaks at 2×/3× the true period don't report half/third the real
 *     rate. Falls back to the global argmax when no clean local max is found.
 *   • Emit only when the global peak clears **0.3** — a clean pulse autocorrelates strongly, noise
 *     does not, so a noisy/limp window yields nothing rather than a fabricated bpm.
 *   • bpm = 60·fs/lag, rounded to whole; the estimate's timestamp is the window's CENTRE second.
 *
 * Pure + side-effect-free so it is unit-testable on synthetic signals (see PpgHrTest).
 */
object PpgHr {
    /** PPG sample rate of the v26 waveform (Hz). */
    const val SAMPLE_RATE_HZ = 24

    /** HR estimation window length in seconds (centred half-window = WINDOW_SECONDS/2 each side). */
    const val WINDOW_SECONDS = 8

    /** Physiological HR search bounds (bpm). */
    const val MIN_BPM = 30.0
    const val MAX_BPM = 220.0

    /** Minimum normalised-autocorrelation peak to emit an estimate. */
    const val MIN_CONFIDENCE = 0.3

    /**
     * One concatenated, time-ordered PPG sample: its wall-clock second [ts] and raw ADC [value].
     * Built from contiguous v26 records (each record contributes 24 samples spanning one second).
     */
    data class Sample(val ts: Long, val value: Int)

    /** A derived HR estimate: [ts] = window-centre second, [bpm], [conf] in 0…1. */
    data class Estimate(val ts: Long, val bpm: Int, val conf: Double)

    /**
     * Per-second PPG-HR over the concatenated [samples] (mirror of Swift `derivePpgHr`).
     *
     * [samples] carry one [ts] per strap-second (all 24 samples of a record share it). They may be
     * unsorted or contain gaps: records are grouped by second (last write wins on a duplicate ts),
     * split into consecutive-second runs, and a centred window is autocorrelated for each second.
     * Returns one [Estimate] per second that yielded a confident estimate, ascending by ts.
     */
    fun estimate(samples: List<Sample>, subLagInterp: Boolean = false): List<Estimate> {
        if (samples.isEmpty()) return emptyList()
        // One waveform per second, in first-seen sample order (last record wins on a duplicate ts).
        val secs = LinkedHashMap<Long, ArrayList<Int>>()
        for (s in samples) {
            val list = secs.getOrPut(s.ts) { ArrayList() }
            list.add(s.value)
        }
        val order = secs.keys.sorted()

        // Split into consecutive-second runs.
        val runs = ArrayList<ArrayList<Long>>()
        var cur = arrayListOf(order[0])
        for (i in 1 until order.size) {
            val u = order[i]
            if (u - cur.last() == 1L) {
                cur.add(u)
            } else {
                runs.add(cur)
                cur = arrayListOf(u)
            }
        }
        runs.add(cur)

        val half = WINDOW_SECONDS / 2
        val out = ArrayList<Estimate>()
        for (run in runs) {
            if (run.size < 3) continue
            val runSet = run.toHashSet()
            for (t in run) {
                // Window of consecutive seconds present in this run, centred on t.
                val win = ArrayList<Long>()
                var u = t - half
                while (u <= t + half) {
                    if (u in runSet) win.add(u)
                    u++
                }
                if (win.size < 3) continue
                var total = 0
                for (w in win) total += secs[w]!!.size
                val sig = DoubleArray(total)
                var idx = 0
                for (w in win) for (v in secs[w]!!) sig[idx++] = v.toDouble()
                estimateWindow(sig, t, subLagInterp)?.let { out.add(it) }
            }
        }
        out.sortBy { it.ts }
        return out
    }

    /**
     * Linear-detrend a waveform: subtract the least-squares best-fit line to remove DC + baseline
     * wander (slow respiration/perfusion drift) before the autocorrelation, so the pulse dominates.
     * Mirror of Swift `PpgHr.detrend`.
     */
    private fun detrend(x: DoubleArray): DoubleArray {
        val n = x.size
        if (n <= 1) return DoubleArray(n) // 0 for all (matches Swift's x.map { 0 })
        val nD = n.toDouble()
        val sumI = nD * (nD - 1) / 2
        val sumI2 = (nD - 1) * nD * (2 * nD - 1) / 6
        var sumY = 0.0
        var sumIY = 0.0
        for (i in 0 until n) { sumY += x[i]; sumIY += i.toDouble() * x[i] }
        val denom = nD * sumI2 - sumI * sumI
        if (denom == 0.0) {
            val mean = sumY / nD
            return DoubleArray(n) { x[it] - mean }
        }
        val slope = (nD * sumIY - sumI * sumY) / denom
        val intercept = (sumY - slope * sumI) / nD
        return DoubleArray(n) { x[it] - (slope * it.toDouble() + intercept) }
    }

    /** Normalised autocorrelation of [x] at [lag] (0 when the signal is flat). Mirror of Swift `acf`. */
    private fun acf(x: DoubleArray, lag: Int): Double {
        val n = x.size - lag
        if (n <= 0) return 0.0
        var mean = 0.0
        for (v in x) mean += v
        mean /= x.size
        var den = 0.0
        for (v in x) { val d = v - mean; den += d * d }
        if (den == 0.0) return 0.0
        var num = 0.0
        for (i in 0 until n) num += (x[i] - mean) * (x[i + lag] - mean)
        return num / den
    }

    /**
     * Estimate HR for one window via linear detrend + normalised autocorrelation with
     * fundamental-period preference. Returns null when the window is too short (< 3 s), flat, or no
     * lag clears [MIN_CONFIDENCE]. Mirror of Swift `PpgHr.estimate` wrapped with the centre [ts].
     *
     * Lag band: a faster HR is a SHORTER lag, so [MAX_BPM] → loLag and [MIN_BPM] → hiLag. Bounds use
     * round-to-nearest and clamp to [2, n-2] exactly as Swift does.
     */
    /**
     * Subtract the record-synchronous (period = fs) component — the artifact a per-record DC step /
     * phase reset injects, which autocorrelates at lag = fs (60 bpm) and would SNAP a sub-60-bpm
     * sleeper to 60 via the fundamental-period preference (#194, ryanbr). A true ~60-bpm pulse is also
     * period-fs, so we only de-artifact when the record BOUNDARY is discontinuous (the artifact's
     * signature) — a real pulse flows smoothly across it and is left untouched, preserving a true
     * 60 bpm. Mirror of the Swift PpgHr.removeRecordRateComponent.
     */
    private fun removeRecordRateComponent(x: DoubleArray, fs: Int): DoubleArray {
        val n = x.size
        if (fs <= 1 || n < fs * 4) return x
        var withinSum = 0.0; var withinCount = 0; var boundarySum = 0.0; var boundaryCount = 0
        for (i in 1 until n) {
            val d = Math.abs(x[i] - x[i - 1])
            if (i % fs == 0) { boundarySum += d; boundaryCount++ } else { withinSum += d; withinCount++ }
        }
        if (withinCount == 0 || boundaryCount == 0) return x
        val within = withinSum / withinCount
        val boundary = boundarySum / boundaryCount
        if (within <= 0.0 || boundary <= within * 3) return x // smooth → real pulse → leave it
        val colSum = DoubleArray(fs); val colCount = IntArray(fs)
        for (i in 0 until n) { val p = i % fs; colSum[p] += x[i]; colCount[p]++ }
        val colMean = DoubleArray(fs) { p -> if (colCount[p] > 0) colSum[p] / colCount[p] else 0.0 }
        return DoubleArray(n) { i -> x[i] - colMean[i % fs] }
    }

    private fun estimateWindow(values: DoubleArray, ts: Long, subLagInterp: Boolean = false): Estimate? {
        if (values.size < SAMPLE_RATE_HZ * 3) return null // need >= 3 s to resolve a low HR
        // De-artifact (#194) THEN detrend, so the autocorrelation sees the pulse, not a record-rate comb.
        val x = detrend(removeRecordRateComponent(values, SAMPLE_RATE_HZ))
        val fsD = SAMPLE_RATE_HZ.toDouble()
        val loLag = maxOf(2, Math.round(fsD * 60 / MAX_BPM).toInt())
        val hiLag = minOf(x.size - 2, Math.round(fsD * 60 / MIN_BPM).toInt())
        if (hiLag <= loLag) return null

        val vals = HashMap<Int, Double>(hiLag - loLag + 1)
        var peak = Double.NEGATIVE_INFINITY
        for (lag in loLag..hiLag) {
            val v = acf(x, lag)
            vals[lag] = v
            if (v > peak) peak = v
        }
        if (peak < MIN_CONFIDENCE) return null

        // Prefer the FUNDAMENTAL period: the smallest-lag local maximum that is nearly as strong as
        // the global peak. Autocorrelation also peaks at 2×/3× the true period (half/third HR); the
        // global max there would report half the real rate, so prefer the shortest prominent period.
        var bestLag = -1
        if (loLag + 1 <= hiLag - 1) {
            for (lag in (loLag + 1)..(hiLag - 1)) {
                val v = vals[lag]!!
                if (v >= 0.85 * peak && v >= vals[lag - 1]!! && v >= vals[lag + 1]!!) {
                    bestLag = lag
                    break
                }
            }
        }
        if (bestLag < 0) {
            // Fallback: global argmax, smallest lag wins a tie (deterministic).
            var argmax = loLag
            var best = vals[loLag]!!
            for (lag in (loLag + 1)..hiLag) {
                val v = vals[lag]!!
                if (v > best) { best = v; argmax = lag }
            }
            bestLag = argmax
        }

        // Sub-lag parabolic interpolation (Variant A, opt-in): refine the integer bestLag by fitting a
        // parabola to the ACF peak and its two neighbours, so a true HR sitting BETWEEN two integer lags is
        // not quantized (integer lags step ~16 bpm near 150 bpm, so the estimate can be off up to ~±8 bpm).
        // Guarded to interior lags; a non-concave fit (denom >= 0) or a clamp-defended one falls back to the
        // integer lag. Default OFF is byte-identical to the integer-lag estimate. Mirror of the Swift branch.
        var refinedLag = bestLag.toDouble()
        if (subLagInterp && bestLag - 1 >= loLag && bestLag + 1 <= hiLag) {
            val y0 = vals[bestLag - 1]!!
            val y1 = vals[bestLag]!!
            val y2 = vals[bestLag + 1]!!
            val denom = y0 - 2.0 * y1 + y2
            if (denom < 0.0) {
                val delta = (0.5 * (y0 - y2) / denom).coerceIn(-1.0, 1.0)
                refinedLag = (bestLag.toDouble() + delta).coerceIn(loLag.toDouble(), hiLag.toDouble())
            }
        }
        // Round to whole bpm (the ppgHrSample column is Int; #219) — conf stays the integer bestLag's peak
        // (the refinement moves only the frequency, not the confidence). Matches the Swift estimator.
        val bpm = Math.round(fsD * 60 / refinedLag).toInt()
        val conf = Math.round(vals[bestLag]!! * 1000) / 1000.0
        return Estimate(ts = ts, bpm = bpm, conf = conf)
    }
}
