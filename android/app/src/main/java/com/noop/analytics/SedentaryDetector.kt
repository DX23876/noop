package com.noop.analytics

import com.noop.data.GravitySample

/*
 * SedentaryDetector.kt — the pure core of the "inactivity reminder" (wrist buzz after sitting too long).
 *
 * Faithful Kotlin mirror of StrandAnalytics/SedentaryDetector.swift. Keep the detector tunables, the
 * active/quiet-hours window math, and the de-dup decision byte-identical to Swift — cross-platform
 * parity is the contract. This folds the PR #419 logic (ActivityDetector.detectSedentaryBouts +
 * InactivityPrefs.mayBuzzInactivity + WhoopBleClient.maybeBuzzInactivity de-dup) into ONE pure,
 * deterministic, DB-free engine. The human wires this into the existing Android service +
 * InactivityPrefs persistence afterward.
 *
 * WHY GRAVITY, NOT STEPS: the WHOOP 4.0 exposes no step count over BLE — only the wrist accelerometer,
 * and only via the ~15-min historical offload. Sedentary time is therefore inferred from gravity. The
 * wrist moves constantly at a desk (typing, reaching), so "wrist stillness" is the wrong signal; what a
 * "time to move" reminder needs is the ABSENCE OF AMBULATION (walking around). [detectSedentaryBouts]
 * smooths the per-record gravity delta (reusing [WorkoutDetector.activitySeries]) over [smoothWindowS]
 * and calls any stretch where that smoothed signal stays at/under [moveThresholdG] — i.e. no sustained
 * walking — a sedentary bout. Typing and isolated reaches average out and keep the bout alive; sustained
 * walking pushes the smoothed signal over the threshold and ends it. Defaults were calibrated from
 * on-wrist data (desk ≈ 0.05–0.10 g smoothed, walking ≈ 0.2–0.4 g).
 *
 * PURITY: no I/O, no wall-clock reads. `nowSec` and `tzOffsetSec` (seconds east of UTC) are passed IN.
 * Active-hours / quiet-hours are evaluated against the candidate bout's LOCAL END TIME, not `now`:
 * gravity only reaches the app on the strap's offload flush, so an overnight bout is processed in the
 * morning; a `now`-based check would wrongly admit it. Checking the bout's own end time is what makes
 * "active hours excludes nighttime sleep" actually hold.
 *
 * All `ts`/`start`/`end`/`nowSec` are wall-clock unix SECONDS. Outputs are APPROXIMATE, not medical advice.
 */

/**
 * A sedentary ("haven't moved from my seat") period. Times are wall-clock unix seconds; [durationS]
 * mirrors [ExerciseSession.durationS]. APPROXIMATE.
 */
data class InactivityPeriod(
    val start: Long,
    val end: Long,
    val durationS: Double,
)

/**
 * The persisted de-dup / freshness state the reminder carries between offloads (restart-safe). The
 * caller stores this verbatim (the byte-identical analogue of the InactivityPrefs LAST_* keys) and
 * feeds the prior value back into the next [evaluate]. A fresh user starts from [INITIAL].
 */
data class SedentaryState(
    /** Newest gravity ts already processed — a replayed / no-new-rows offload can't re-buzz. */
    val lastProcessedGravityTs: Long = 0L,
    /** Unix-seconds of the last buzz (0 = never) — drives the re-nudge cadence. */
    val lastBuzzAt: Long = 0L,
    /** Start of the last buzzed bout (0 = none) — distinguishes "same bout, re-nudge" from "new bout". */
    val lastBuzzedBoutStart: Long = 0L,
    /** End of the last buzzed bout (0 = none). */
    val lastBuzzedBoutEnd: Long = 0L,
) {
    companion object {
        /** A cold-start state (never processed, never buzzed). */
        val INITIAL = SedentaryState()
    }
}

/**
 * The decision the engine returns each offload: whether to buzz now, the next persisted state to store,
 * and (when buzzing) the buzz strength + the bout that triggered it (for logging / UI).
 */
data class SedentaryDecision(
    /** True if the wrist should buzz on this offload. */
    val shouldBuzz: Boolean,
    /** How many buzz loops to play (strength) when [shouldBuzz] — mirrors [SedentaryConfig.buzzLoops]. */
    val buzzLoops: Int,
    /** The current sedentary bout that drove the decision, or null if none qualified. */
    val bout: InactivityPeriod?,
    /** The state to persist for the next offload (always advance [SedentaryState.lastProcessedGravityTs]). */
    val nextState: SedentaryState,
)

/**
 * User-tunable config for the inactivity reminder. Mirrors InactivityPrefs (defaults included) plus the
 * global gates the Android guard reuses from NotifPrefs (master / quiet-hours / only-when-worn), passed
 * in here as plain values so the engine stays pure.
 */
data class SedentaryConfig(
    // Feature toggle + master gate.
    /** Inactivity reminder feature toggle (InactivityPrefs.enabled, default OFF). */
    val enabled: Boolean = false,
    /** Global notification master switch (NotifPrefs.MASTER, default OFF). Buzz is inert if off. */
    val notificationsMasterOn: Boolean = false,
    // Detector tunables (ActivityDetector).
    /** Smoothed wrist-motion above this (g) counts as "walking around", ending a sedentary bout. */
    val moveThresholdG: Double = SedentaryDetector.DEFAULT_MOVE_THRESHOLD_G,
    /** Minimum sedentary-bout length (minutes) before the first nudge (InactivityPrefs threshold). */
    val thresholdMinutes: Int = SedentaryDetector.DEFAULT_THRESHOLD_MINUTES,
    /** Rolling-mean window (seconds) for the movement signal. */
    val smoothWindowSeconds: Double = SedentaryDetector.DEFAULT_SMOOTH_WINDOW_S,
    // Cadence + strength.
    /** If still seated, re-buzz this often (minutes). InactivityPrefs re-nudge, default 30. */
    val reNudgeMinutes: Int = SedentaryDetector.DEFAULT_RENUDGE_MINUTES,
    /** Buzz strength (loops). InactivityPrefs buzz loops, default 2. */
    val buzzLoops: Int = SedentaryDetector.DEFAULT_BUZZ_LOOPS,
    // Active-hours window (InactivityPrefs).
    /** Only nudge during the active-hours window (default ON). */
    val activeHoursEnabled: Boolean = true,
    /** Active-hours window start, local minute-of-day [0,1440) (default 9:00 = 540). */
    val activeStartMinutes: Int = SedentaryDetector.DEFAULT_ACTIVE_START_MIN,
    /** Active-hours window end, local minute-of-day [0,1440) (default 17:00 = 1020). */
    val activeEndMinutes: Int = SedentaryDetector.DEFAULT_ACTIVE_END_MIN,
    // Quiet-hours window (reused from NotifPrefs).
    /** Suppress during quiet hours (NotifPrefs.QUIET, default OFF). */
    val quietHoursEnabled: Boolean = false,
    /** Quiet-hours start, local minute-of-day (default 22:00 = 1320). */
    val quietStartMinutes: Int = SedentaryDetector.DEFAULT_QUIET_START_MIN,
    /** Quiet-hours end, local minute-of-day (default 7:00 = 420). */
    val quietEndMinutes: Int = SedentaryDetector.DEFAULT_QUIET_END_MIN,
    // Only-when-worn gate (reused from NotifPrefs).
    /** Require the strap to be worn (NotifPrefs.WORN, default ON). */
    val onlyWhenWorn: Boolean = true,
)

object SedentaryDetector {

    // ── Detector defaults (ActivityDetector parity) ──────────────────────────
    /** Smoothed wrist-motion above this (g) counts as "walking around", ending a sedentary bout. */
    const val DEFAULT_MOVE_THRESHOLD_G: Double = 0.15

    /** Rolling-mean window (seconds) for the movement signal — long enough that desk reaches / typing
     *  flurries average out, short enough that sustained walking still crosses the threshold within a
     *  minute or two. */
    const val DEFAULT_SMOOTH_WINDOW_S: Double = 240.0

    /** Break a sedentary bout when the inter-record time gap exceeds this (seconds). Also the freshness
     *  tolerance the live path uses to decide a bout is still "current". */
    const val MAX_GAP_S: Long = 20 * 60

    /** Default minimum sedentary-bout length (minutes) — InactivityPrefs threshold default. */
    const val DEFAULT_THRESHOLD_MINUTES: Int = 45

    /** The detector's own floor when a caller doesn't pass a user threshold (ActivityDetector default). */
    const val DEFAULT_MIN_MINUTES: Int = 15

    // ── Config defaults (InactivityPrefs / NotifPrefs parity) ────────────────
    const val DEFAULT_RENUDGE_MINUTES: Int = 30
    const val DEFAULT_BUZZ_LOOPS: Int = 2
    const val DEFAULT_ACTIVE_START_MIN: Int = 9 * 60   // 09:00
    const val DEFAULT_ACTIVE_END_MIN: Int = 17 * 60    // 17:00
    const val DEFAULT_QUIET_START_MIN: Int = 22 * 60   // 22:00
    const val DEFAULT_QUIET_END_MIN: Int = 7 * 60      // 07:00

    // ── Detection (ActivityDetector.detectSedentaryBouts parity) ─────────────

    /**
     * Detect SEDENTARY bouts: stretches where the smoothed wrist-motion stays at/under [moveThresholdG]
     * — the user hasn't walked around — for ≥ [minMinutes]. Typing and the occasional reach stay below
     * the threshold and keep the bout alive; sustained walking ends it, as does a data gap > [MAX_GAP_S].
     */
    fun detectSedentaryBouts(
        gravity: List<GravitySample>,
        moveThresholdG: Double = DEFAULT_MOVE_THRESHOLD_G,
        minMinutes: Int = DEFAULT_MIN_MINUTES,
        smoothWindowSeconds: Double = DEFAULT_SMOOTH_WINDOW_S,
    ): List<InactivityPeriod> {
        val rows = gravity.sortedBy { it.ts }
        if (rows.size < 2) return emptyList()
        val motion = WorkoutDetector.activitySeries(rows)
        val smoothed = WorkoutDetector.smoothedIntensity(motion, smoothWindowSeconds)
        val ts = motion.map { it.ts }
        val n = ts.size
        val minS = minMinutes * 60L

        val out = ArrayList<InactivityPeriod>()
        var runStart = -1
        fun closeRun(endIdx: Int) {
            if (runStart in 0..endIdx) {
                val s = ts[runStart]
                val e = ts[endIdx]
                if (e - s >= minS) out.add(InactivityPeriod(s, e, (e - s).toDouble()))
            }
            runStart = -1
        }
        for (i in 0 until n) {
            if (i > 0 && ts[i] - ts[i - 1] > MAX_GAP_S) closeRun(i - 1) // data gap ends the run
            if (smoothed[i] > moveThresholdG) {
                closeRun(i - 1) // walking-level motion ends the sedentary run
            } else if (runStart < 0) {
                runStart = i
            }
        }
        closeRun(n - 1)
        return out
    }

    // ── Pure time helpers (InactivityPrefs parity) ───────────────────────────

    /** Local minute-of-day [0,1440) for a unix-seconds instant given a tz offset (seconds east of UTC). */
    fun localMinuteOfDay(epochSec: Long, tzOffsetSec: Long): Int =
        (Math.floorMod(epochSec + tzOffsetSec, 86_400L) / 60L).toInt()

    /** Wrap-aware membership: is [minuteOfDay] inside `[startMin, endMin)` (window may cross midnight)? */
    fun windowContains(minuteOfDay: Int, startMin: Int, endMin: Int): Boolean =
        if (startMin <= endMin) minuteOfDay in startMin until endMin
        else (minuteOfDay >= startMin || minuteOfDay < endMin)

    /**
     * The global + active/quiet-hours gate, evaluated against the bout's LOCAL END TIME. True only when
     * the inactivity reminder may buzz for a bout ending at [boutEndEpochSec]. Mirrors
     * InactivityPrefs.mayBuzzInactivity (master / quiet hours / worn / active-hours-by-bout-end-time).
     */
    fun mayBuzz(config: SedentaryConfig, worn: Boolean, boutEndEpochSec: Long, tzOffsetSec: Long): Boolean {
        if (!config.enabled) return false
        if (!config.notificationsMasterOn) return false
        if (config.quietHoursEnabled) {
            val mod = localMinuteOfDay(boutEndEpochSec, tzOffsetSec)
            if (windowContains(mod, config.quietStartMinutes, config.quietEndMinutes)) return false
        }
        if (config.onlyWhenWorn && !worn) return false
        if (config.activeHoursEnabled) {
            val mod = localMinuteOfDay(boutEndEpochSec, tzOffsetSec)
            if (!windowContains(mod, config.activeStartMinutes, config.activeEndMinutes)) return false
        }
        return true
    }

    // ── The decision (WhoopBleClient.maybeBuzzInactivity parity) ─────────────

    /**
     * Run the inactivity reminder over the freshly-arrived [gravity] window and decide whether to buzz.
     * Pure: pass [nowSec] (the offload-completion instant) and [tzOffsetSec] IN; never read a clock.
     *
     * Mirrors the Android live path exactly:
     *   1. Disabled → never buzz; state unchanged.
     *   2. Only act when this offload advanced the newest gravity ts (replayed / no-new-rows → no-op);
     *      when it did advance, persist the new `lastProcessedGravityTs`.
     *   3. Pick the most-recent qualifying bout (≥ [SedentaryConfig.thresholdMinutes]).
     *   4. The bout must be CURRENT — its end within [MAX_GAP_S] of the newest sample (still seated).
     *   5. Pass the global + active/quiet/worn gate ([mayBuzz]) on the bout's local end time.
     *   6. Re-nudge a continuing bout on the user's cadence; alert a distinct new bout (one that starts
     *      after the last buzzed bout's end, separated by movement) on its own crossing.
     */
    fun evaluate(
        gravity: List<GravitySample>,
        state: SedentaryState,
        config: SedentaryConfig,
        worn: Boolean,
        nowSec: Long,
        tzOffsetSec: Long,
    ): SedentaryDecision {
        fun noBuzz(next: SedentaryState, bout: InactivityPeriod? = null) =
            SedentaryDecision(shouldBuzz = false, buzzLoops = config.buzzLoops, bout = bout, nextState = next)

        if (!config.enabled) return noBuzz(state)

        val newest = gravity.maxOfOrNull { it.ts } ?: return noBuzz(state)

        // Only act when this offload brought new gravity (a replayed / no-new-rows sync can't fire).
        if (newest <= state.lastProcessedGravityTs) return noBuzz(state)
        var next = state.copy(lastProcessedGravityTs = newest)

        val bout = detectSedentaryBouts(
            gravity,
            moveThresholdG = config.moveThresholdG,
            minMinutes = config.thresholdMinutes,
            smoothWindowSeconds = config.smoothWindowSeconds,
        ).maxByOrNull { it.end } ?: return noBuzz(next)

        // The bout must be current — its end near the newest sample (the user is still seated).
        if (newest - bout.end > MAX_GAP_S) return noBuzz(next, bout)
        if (!mayBuzz(config, worn, bout.end, tzOffsetSec)) return noBuzz(next, bout)

        val reNudgeS = config.reNudgeMinutes * 60L
        // Continues the last buzzed bout → re-nudge on cadence; a distinct new bout (which starts after
        // the last buzzed bout's end, separated by movement) alerts on its own crossing.
        val continues = bout.start <= state.lastBuzzedBoutEnd
        val shouldBuzz = state.lastBuzzAt == 0L || !continues || (nowSec - state.lastBuzzAt >= reNudgeS)
        if (!shouldBuzz) return noBuzz(next, bout)

        next = next.copy(
            lastBuzzAt = nowSec,
            lastBuzzedBoutStart = bout.start,
            lastBuzzedBoutEnd = bout.end,
        )
        return SedentaryDecision(shouldBuzz = true, buzzLoops = config.buzzLoops, bout = bout, nextState = next)
    }
}
