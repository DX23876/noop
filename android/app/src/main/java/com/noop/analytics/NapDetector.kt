package com.noop.analytics

import com.noop.data.GravitySample
import com.noop.data.HrRow

/*
 * NapDetector.kt — the pure core of on-device SHORT-NAP detection (reimplemented from @cbarrado's
 * PR #569 under NoopApp identity).
 *
 * A daytime nap is a short stretch where the wrist goes quiet AND the heart rate settles below the
 * person's resting band — the same primitives the inactivity reminder and the sleep stager already use,
 * but read together over a SHORT window. The strap has no "is asleep" flag over BLE on a 4.0, so a nap is
 * INFERRED, and the inference is deliberately conservative: a tri-state verdict (NAP / NONE / INCONCLUSIVE)
 * that NEVER auto-writes a sleep session. A confident NAP is offered as a review card the user accepts or
 * dismisses; an INCONCLUSIVE window is shown honestly as "couldn't tell" rather than guessed either way.
 *
 * WHY A REVIEW CARD, NOT AUTO-INSERT: a false nap silently corrupts the day's sleep totals + recovery
 * inputs, and we can't be sure from wrist motion + HR alone. So the engine only PROPOSES; the human
 * confirms via [NapStore] → `WhoopRepository.addManualNap` (the SAME hand-corrected-nap path #508 ships,
 * with the recompute overlap guard). Honesty over completeness (memory: feedback_evidence_based).
 *
 * ELIGIBILITY GATE (dense gravity): a nap verdict is only attempted over a window the strap actually
 * sampled densely — [minGravitySamples] gravity rows whose median inter-sample gap is ≤ [maxMedianGapS].
 * A sparse window (strap off, gappy offload) yields INCONCLUSIVE, never NONE: absence of dense motion
 * isn't evidence the person was awake. This mirrors the SleepStager's morning-stillness density check.
 *
 * PURITY: no I/O, no wall-clock reads, no Room/coroutines. Everything is passed IN, so it runs under
 * testFullDebugUnitTest and is byte-identical to verify cross-platform. All `ts`/`start`/`end` are
 * wall-clock unix SECONDS. Outputs are APPROXIMATE, never medical advice.
 */

/** Tri-state verdict for one candidate window. Conservative by construction. */
enum class NapVerdict {
    /** Confident short nap: dense quiet motion + a settled HR band over a plausible nap length. */
    NAP,

    /** Confident NOT a nap: the window had dense data but the person was clearly awake/active. */
    NONE,

    /** Couldn't tell — too little dense data, or mixed signals. Shown honestly, never guessed. */
    INCONCLUSIVE,
}

/**
 * A proposed nap the user can review (accept → it becomes a manual nap session; dismiss → forgotten).
 * Times are wall-clock unix seconds. [confidence] in 0..1 is for ordering/UI only — NEVER a medical claim.
 */
data class NapCandidate(
    val start: Long,
    val end: Long,
    /** Mean HR over the quiet stretch (bpm), for the honest review-card sub-line. Null if no HR landed. */
    val meanHr: Int?,
    /** 0..1 ordering confidence (motion quietness + HR settling). Not a probability, not a diagnosis. */
    val confidence: Double,
) {
    val durationS: Long get() = end - start
}

/** The full outcome of one [evaluate] pass: the verdict + (when NAP) the candidate to offer for review. */
data class NapDecision(
    val verdict: NapVerdict,
    /** Present only when [verdict] == NAP; the window to offer as a review card. */
    val candidate: NapCandidate?,
)

/**
 * User-tunable thresholds. Defaults calibrated from the same on-wrist data the SedentaryDetector used
 * (desk/quiet ≈ 0.05–0.10 g smoothed, walking ≈ 0.2–0.4 g) plus typical resting-HR bands. Mirrors the
 * macOS NapConfig; keep the numbers identical for cross-platform parity.
 */
data class NapConfig(
    /** Feature toggle (default OFF — opt-in, manual-first). */
    val enabled: Boolean = false,
    /** Shortest stretch that counts as a nap (minutes). Below this it's just sitting still. */
    val minNapMinutes: Int = NapDetector.DEFAULT_MIN_NAP_MIN,
    /** Longest a daytime "nap" can be before it's really main sleep we shouldn't fold in (minutes). */
    val maxNapMinutes: Int = NapDetector.DEFAULT_MAX_NAP_MIN,
    /** Smoothed wrist-motion at/under this (g) is "lying still" — quieter than the sedentary threshold,
     *  because a nap needs genuine stillness, not just "not walking". */
    val stillThresholdG: Double = NapDetector.DEFAULT_STILL_THRESHOLD_G,
    /** HR must sit at/under (restingHr + this margin) bpm to read as asleep, not awake-but-still. */
    val hrSettleMarginBpm: Int = NapDetector.DEFAULT_HR_SETTLE_MARGIN_BPM,
    /** Rolling-mean window (seconds) for the motion signal — shorter than the sedentary one so a brief
     *  nap isn't smoothed away. */
    val smoothWindowSeconds: Double = NapDetector.DEFAULT_SMOOTH_WINDOW_S,
)

object NapDetector {

    // ── Defaults (macOS NapConfig parity) ────────────────────────────────────
    const val DEFAULT_MIN_NAP_MIN: Int = 20
    const val DEFAULT_MAX_NAP_MIN: Int = 90
    const val DEFAULT_STILL_THRESHOLD_G: Double = 0.08
    const val DEFAULT_HR_SETTLE_MARGIN_BPM: Int = 8
    const val DEFAULT_SMOOTH_WINDOW_S: Double = 120.0

    /** Break a quiet run when the inter-record gap exceeds this (seconds) — a data hole isn't sleep. */
    const val MAX_GAP_S: Long = 10 * 60

    // ── Eligibility gate (dense-gravity) ─────────────────────────────────────
    /** A verdict is only attempted with at least this many gravity rows in the window. */
    const val DEFAULT_MIN_GRAVITY_SAMPLES: Int = 20

    /** ...and only when their MEDIAN inter-sample gap is no larger than this (seconds). A sparse / gappy
     *  window is INCONCLUSIVE, not NONE — we can't claim "awake" from data we don't have. */
    const val DEFAULT_MAX_MEDIAN_GAP_S: Long = 90

    /**
     * Is the gravity window dense enough to judge? True only when there are ≥ [minSamples] rows and their
     * median inter-sample gap is ≤ [maxMedianGapS]. Pure; the eligibility half of the tri-state.
     */
    fun isWindowDense(
        gravity: List<GravitySample>,
        minSamples: Int = DEFAULT_MIN_GRAVITY_SAMPLES,
        maxMedianGapS: Long = DEFAULT_MAX_MEDIAN_GAP_S,
    ): Boolean {
        if (gravity.size < minSamples) return false
        val ts = gravity.map { it.ts }.sorted()
        val gaps = ts.zipWithNext { a, b -> b - a }.filter { it >= 0 }
        if (gaps.isEmpty()) return false
        val sorted = gaps.sorted()
        val median = sorted[sorted.size / 2]
        return median <= maxMedianGapS
    }

    /**
     * The LONGEST stretch of sustained stillness in the window: smoothed wrist-motion ≤ [stillThresholdG],
     * unbroken by motion or by a data gap > [MAX_GAP_S]. Reuses the shipped [WorkoutDetector] primitives so
     * the motion math matches the sedentary detector exactly. Returns (startTs, endTs) or null if none.
     */
    fun longestQuietRun(
        gravity: List<GravitySample>,
        stillThresholdG: Double = DEFAULT_STILL_THRESHOLD_G,
        smoothWindowSeconds: Double = DEFAULT_SMOOTH_WINDOW_S,
    ): Pair<Long, Long>? {
        val rows = gravity.sortedBy { it.ts }
        if (rows.size < 2) return null
        val motion = WorkoutDetector.activitySeries(rows)
        val smoothed = WorkoutDetector.smoothedIntensity(motion, smoothWindowSeconds)
        val ts = motion.map { it.ts }
        val n = ts.size

        var bestStart = -1L
        var bestEnd = -1L
        var runStart = -1
        fun closeRun(endIdx: Int) {
            if (runStart in 0..endIdx) {
                val s = ts[runStart]
                val e = ts[endIdx]
                if (bestStart < 0 || (e - s) > (bestEnd - bestStart)) {
                    bestStart = s; bestEnd = e
                }
            }
            runStart = -1
        }
        for (i in 0 until n) {
            if (i > 0 && ts[i] - ts[i - 1] > MAX_GAP_S) closeRun(i - 1) // data gap ends the run
            if (smoothed[i] > stillThresholdG) {
                closeRun(i - 1) // movement ends the quiet run
            } else if (runStart < 0) {
                runStart = i
            }
        }
        closeRun(n - 1)
        return if (bestStart < 0) null else bestStart to bestEnd
    }

    /** Mean HR (bpm) over `[start, end]`, or null when no sample fell in the window. */
    fun meanHrIn(hr: List<HrRow>, start: Long, end: Long): Int? {
        val inWindow = hr.filter { it.ts in start..end && it.bpm in 25..220 }
        if (inWindow.isEmpty()) return null
        return (inWindow.sumOf { it.bpm }.toDouble() / inWindow.size).toInt()
    }

    /**
     * Classify the candidate window. Pure: pass the freshly-arrived [gravity] + [hr] for the window, the
     * person's [restingHr] (null if unknown), the [config], and the time bounds IN.
     *
     * The tri-state logic, in order:
     *   1. Feature OFF → INCONCLUSIVE with no candidate (the caller simply does nothing).
     *   2. Window NOT dense ([isWindowDense] false) → INCONCLUSIVE (can't judge from sparse data).
     *   3. No sustained quiet run, OR the longest run is shorter than [minNapMinutes] → NONE (had dense
     *      data, person was moving — confidently not a nap).
     *   4. A quiet run ≥ [minNapMinutes] but longer than [maxNapMinutes] → INCONCLUSIVE (could be main
     *      sleep we must not mislabel as a nap).
     *   5. A quiet run in `[min, max]` with resting HR known and the window's mean HR NOT settled
     *      (> restingHr + margin) → NONE (still but awake — e.g. reading, screen time).
     *   6. A quiet run in `[min, max]` with HR settled (or resting HR unknown but motion clearly napping)
     *      → NAP, offered as a review card.
     *
     * When resting HR is UNKNOWN we still allow a NAP verdict on a sufficiently long, sufficiently quiet
     * run, but at lower [confidence] — we never fabricate an HR band we don't have.
     */
    fun evaluate(
        gravity: List<GravitySample>,
        hr: List<HrRow>,
        restingHr: Int?,
        config: NapConfig,
    ): NapDecision {
        if (!config.enabled) return NapDecision(NapVerdict.INCONCLUSIVE, null)

        if (!isWindowDense(gravity)) return NapDecision(NapVerdict.INCONCLUSIVE, null)

        val quiet = longestQuietRun(
            gravity,
            stillThresholdG = config.stillThresholdG,
            smoothWindowSeconds = config.smoothWindowSeconds,
        ) ?: return NapDecision(NapVerdict.NONE, null)

        val (start, end) = quiet
        val durationMin = (end - start) / 60.0
        if (durationMin < config.minNapMinutes) return NapDecision(NapVerdict.NONE, null)
        // Too long to safely call a "nap" — could be main sleep; don't mislabel either way.
        if (durationMin > config.maxNapMinutes) return NapDecision(NapVerdict.INCONCLUSIVE, null)

        val meanHr = meanHrIn(hr, start, end)

        // HR gate when we know the resting band: a settled HR confirms sleep; an elevated one means
        // "still but awake", which is confidently NOT a nap.
        if (restingHr != null && meanHr != null) {
            val settled = meanHr <= restingHr + config.hrSettleMarginBpm
            if (!settled) return NapDecision(NapVerdict.NONE, null)
        }

        return NapDecision(
            NapVerdict.NAP,
            NapCandidate(
                start = start,
                end = end,
                meanHr = meanHr,
                confidence = confidenceFor(durationMin, restingHr, meanHr, config),
            ),
        )
    }

    /**
     * 0..1 ordering confidence (NOT a probability). Longer + a known, well-settled HR band reads as more
     * confident; an unknown HR band caps it lower because we're leaning on motion alone. Pure + bounded.
     */
    internal fun confidenceFor(durationMin: Double, restingHr: Int?, meanHr: Int?, config: NapConfig): Double {
        // Duration term: ramps from min→max nap length across 0.4..0.85.
        val span = (config.maxNapMinutes - config.minNapMinutes).coerceAtLeast(1)
        val durTerm = 0.4 + 0.45 * ((durationMin - config.minNapMinutes) / span).coerceIn(0.0, 1.0)
        // HR term: a known, settled band adds confidence; unknown HR caps the total at the duration term.
        if (restingHr == null || meanHr == null) return durTerm.coerceIn(0.0, 0.7)
        val headroom = config.hrSettleMarginBpm.coerceAtLeast(1)
        val below = (restingHr + config.hrSettleMarginBpm - meanHr).coerceAtLeast(0)
        val hrTerm = 0.15 * (below.toDouble() / headroom).coerceIn(0.0, 1.0)
        return (durTerm + hrTerm).coerceIn(0.0, 1.0)
    }
}
