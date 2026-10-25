package com.noop.analytics

import com.noop.data.GravitySample
import com.noop.data.HrSample
import com.noop.data.StepSample
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/*
 * WorkoutTypeClassifier.kt — COARSE workout-type classifier over ALREADY-CAPTURED signals.
 *
 * Faithful Kotlin twin of StrandAnalytics/WorkoutTypeClassifier.swift (#414) — same constants, same
 * ramp/plateau memberships, same per-class weights, byte-identical scores for the same feature vector.
 *
 * Given a detected workout window (from [WorkoutDetector] / [AutoWorkoutDetector]), this predicts a
 * BROAD activity class — walk / run / strength / cycle / ski / other — plus a confidence, from four
 * signal families that are already decoded and stored, no raw IMU:
 *   1. HR profile over the window (mean/peak/%HRR, HR variability shape) — [HrSample].
 *   2. Activity-class tick composition — [StepSample.activityClass] (0 still / 1 walk / 2 run,
 *      community finding #316) — the on-device per-tick gait classifier, rolled up to a window.
 *   3. Gravity-derived posture/motion variance — the SAME per-record L2 gravity-delta intensity
 *      [WorkoutDetector.activitySeries] already computes for detection, re-used here as a shape
 *      signal rather than a threshold gate.
 *   4. Duration and calories.
 *
 * BROAD ONLY. This deliberately does NOT attempt fine-grained sport discrimination (e.g. basketball
 * vs tennis) — that needs raw high-rate IMU (type-43, ~100 Hz) this app does not capture. `gravity`/
 * `steps` here are the DECODED, already-stored ~1 Hz streams; nothing in this file reads raw motion
 * buffers.
 *
 * NOT a spectral/autocorrelation estimate. The gravity stream this classifier reads is ~1 Hz, well
 * below the Nyquist rate a real gait/pedal cadence would need (~1.5–3 Hz for walk/run strides). Per
 * the CLAUDE.md derived-signal rule (and the withdrawn PPG→HR estimate, #194), autocorrelation or
 * spectral analysis on a fixed low sample rate can manufacture a peak at the RECORD period that looks
 * physiological but isn't — so this file never does that. `motionCV` is a coefficient-of-variation
 * burstiness/regularity statistic, NOT a frequency estimate. Treat it as "how steady vs. bursty is
 * the motion", nothing more.
 *
 * SHIP STATUS: first-pass HEURISTIC (documented, clamped ramp thresholds below), validated so far
 * ONLY against synthetic fixtures that each recover a distinct injected pattern (see
 * WorkoutTypeClassifierTest). This is advisory instrumentation — a caller may use it to LABEL or
 * SUGGEST a class on a detected workout, but it must never override a user's own sport selection and
 * must never gate a downstream score. Real-world accuracy against labeled workouts (e.g. Oura-import
 * `workout.sport` ground truth) is an explicit follow-up, not done here. The `scores` field on
 * [WorkoutClassPrediction] reports every candidate class's raw match score precisely so a later pass
 * can compute accuracy / top-k / confusion against real labels without re-deriving anything.
 *
 * Pure, database-free, no I/O — classifies from a feature vector. [WorkoutTypeFeatureExtractor]
 * builds that vector from the raw decoded streams; a future ML model (or one fed real IMU-derived
 * features) can implement [WorkoutTypeClassifying] and slot in behind the same call sites.
 */

/**
 * A BROAD workout activity class. Deliberately coarse — see file header for why finer-grained sport
 * discrimination (e.g. individual court/ball sports) is out of scope without raw IMU. [raw] preserves
 * the exact lowercase wire string the Swift twin's `rawValue` uses.
 */
enum class CoarseWorkoutClass(val raw: String) {
    WALK("walk"),
    RUN("run"),
    STRENGTH("strength"),
    CYCLE("cycle"),
    SKI("ski"),

    /**
     * No candidate class cleared the plausibility/margin bar — genuinely unclear, or a shape (e.g.
     * swim, row, court sport) this MVP doesn't model. Never a wrong specific guess dressed up.
     */
    OTHER("other"),
}

/**
 * The feature vector a classifier scores. Built once per detected workout window so real labeled
 * workouts (e.g. an Oura-import `workout` row) can be scored later WITHOUT re-deriving anything from
 * raw streams — construct this class directly from a labeled workout's own summary stats to validate,
 * or run [WorkoutTypeFeatureExtractor] over its stored streams. Mirrors Swift `WorkoutClassFeatures`.
 */
data class WorkoutClassFeatures(
    /** Window length (`end - start`), seconds. */
    val durationSec: Double,

    // --- HR profile ---
    val meanHR: Double,
    val peakHR: Int,
    /** Mean Karvonen %HRR over the window, 0..100, or null when resting/max HR couldn't be resolved. */
    val meanHRRPct: Double?,
    /**
     * Coefficient of variation (stdev/mean) of the window's HR samples. Low = steady sustained
     * effort (run/walk/cycle); high = saw-tooth (sets-then-rest strength, or intermittent ski runs).
     */
    val hrCV: Double,

    // --- Activity-class tick composition (StepSample.activityClass: 0 still / 1 walk / 2 run) ---
    /**
     * Fraction of ticks WITH a decoded activity class that read "still", "walk", "run" respectively
     * (sum to ~1 when [tickCoverage] > 0; all 0 when no tick in the window carried a class).
     */
    val stillFraction: Double,
    val walkFraction: Double,
    val runFraction: Double,
    /**
     * How much of the window is actually backed by a decoded activity-class tick, clamped [0, 1]
     * (classified ticks per second of window). Low/zero on a WHOOP 4.0 or any capture predating the
     * @63 decode — the classifier falls back to HR+motion-only scoring below
     * [WorkoutTypeClassifier.minTickCoverage].
     */
    val tickCoverage: Double,

    // --- Gravity-derived posture / motion shape ---
    /**
     * Variance of the per-record L2 gravity-delta intensity series over the window (the same series
     * [WorkoutDetector.activitySeries] computes) — a coarse posture/impact-variability proxy.
     */
    val motionVariance: Double,
    /**
     * Coefficient of variation of that same intensity series — burstiness/regularity, NOT a cadence
     * estimate (see file header). Low = smooth continuous motion (cycle); high = stop-start bursts
     * (strength sets, or ski runs broken up by lift rides).
     */
    val motionCV: Double,

    // --- Energy ---
    /**
     * Estimated kcal / minute over the window (`caloriesKcal / (durationSec/60)`), or null when no
     * calorie estimate was available.
     */
    val kcalPerMin: Double?,
)

/** A predicted coarse class + confidence for one workout window. Advisory only — see file header. */
data class WorkoutClassPrediction(
    val predictedClass: CoarseWorkoutClass,
    /**
     * 0..1. Reflects BOTH how cleanly the winner beat the runner-up (margin) and how complete the
     * inputs were (tick coverage, %HRR availability) — never higher than the evidence supports.
     */
    val confidence: Double,
    /**
     * Every scored candidate's raw match score (0..1), keyed by class. Always covers
     * WALK/RUN/STRENGTH/CYCLE/SKI — OTHER has no prototype score (see file header) and is never a
     * key here; it is only ever [predictedClass]. Kept so a later validation pass can check
     * top-k / confusion against real labels, not just the single winner.
     */
    val scores: Map<CoarseWorkoutClass, Double>,
)

/**
 * Anything that can turn a feature vector into a prediction. [WorkoutTypeClassifier] (the heuristic
 * below) is the only implementation today; a future ML model — trained on real labels, or fed richer
 * raw-IMU-derived features through a wider [WorkoutClassFeatures] — implements the SAME interface so
 * call sites built against it don't change. Mirrors Swift `WorkoutTypeClassifying`.
 */
interface WorkoutTypeClassifying {
    fun classify(features: WorkoutClassFeatures): WorkoutClassPrediction
}

/**
 * Thin instance adapter over [WorkoutTypeClassifier]'s heuristic, for callers that want the interface
 * seam (dependency injection, swapping in a future model) rather than calling the object directly.
 * Stateless; [WorkoutTypeClassifier.classify] is equally fine to call directly.
 */
class HeuristicWorkoutClassifier : WorkoutTypeClassifying {
    override fun classify(features: WorkoutClassFeatures): WorkoutClassPrediction =
        WorkoutTypeClassifier.classify(features)
}

/** The heuristic. Mirrors Swift `WorkoutTypeClassifier` — same constants, same scores. */
object WorkoutTypeClassifier {

    // ─────────────────────────────────────────────────────────────────────────
    // Constants (first-pass heuristic — see file header; tune against real labels later)
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Below this fraction of the window backed by a decoded activity-class tick, walk/run scoring
     * falls back to HR+motion-only (ticks are too sparse/absent — e.g. a WHOOP 4.0 capture — to trust).
     */
    const val minTickCoverage: Double = 0.15

    /** A candidate's top raw score must clear this to be reported as anything other than OTHER. */
    const val minPlausibleScore: Double = 0.40

    /**
     * The winner must beat the runner-up by at least this much (both 0..1 scores) or the call is
     * too close and reports OTHER instead of an arbitrary tie-break.
     */
    const val minMargin: Double = 0.05

    // ─────────────────────────────────────────────────────────────────────────
    // Public API
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Score [features] against every candidate class and return the winner (or OTHER when nothing
     * clears [minPlausibleScore]/[minMargin]) plus a confidence that reflects both the margin and how
     * complete the inputs were.
     */
    fun classify(features: WorkoutClassFeatures): WorkoutClassPrediction {
        val scores = allScores(features)
        val ranked = scores.entries.sortedByDescending { it.value }
        val top = ranked.firstOrNull()
            ?: return WorkoutClassPrediction(CoarseWorkoutClass.OTHER, 0.0, scores)
        val second = if (ranked.size > 1) ranked[1].value else 0.0
        val margin = max(0.0, top.value - second)
        val marginFactor = 0.5 + 0.5 * min(1.0, margin)
        var confidence = top.value * marginFactor

        // Data-completeness dampener: never let a prediction read more confident than the inputs
        // backing it. Neither known → floor at 0.70×; both known → no penalty.
        val hrrKnown = features.meanHRRPct != null
        val ticksKnown = features.tickCoverage >= minTickCoverage
        var completeness = 0.70
        if (hrrKnown) completeness += 0.15
        if (ticksKnown) completeness += 0.15
        confidence = min(1.0, max(0.0, confidence * completeness))

        if (top.value < minPlausibleScore || margin < minMargin) {
            return WorkoutClassPrediction(CoarseWorkoutClass.OTHER, confidence, scores)
        }
        return WorkoutClassPrediction(top.key, confidence, scores)
    }

    /**
     * Every concrete class's raw [0,1] match score. Exposed (not just the winner) so validation
     * against real labels can check top-k, not only top-1.
     */
    fun allScores(f: WorkoutClassFeatures): Map<CoarseWorkoutClass, Double> = linkedMapOf(
        CoarseWorkoutClass.WALK to walkScore(f),
        CoarseWorkoutClass.RUN to runScore(f),
        CoarseWorkoutClass.STRENGTH to strengthScore(f),
        CoarseWorkoutClass.CYCLE to cycleScore(f),
        CoarseWorkoutClass.SKI to skiScore(f),
    )

    // ─────────────────────────────────────────────────────────────────────────
    // Ramp helpers (fuzzy-membership style, matches the plain documented-threshold style
    // elsewhere in this package rather than an opaque weighted model)
    // ─────────────────────────────────────────────────────────────────────────

    /** 0 at/below [lo], 1 at/above [hi], linear between. `hi <= lo` degenerates to a step at [hi]. */
    internal fun rampUp(x: Double, lo: Double, hi: Double): Double {
        if (hi <= lo) return if (x >= hi) 1.0 else 0.0
        return min(1.0, max(0.0, (x - lo) / (hi - lo)))
    }

    /** Mirror of [rampUp]: 1 at/below [lo], 0 at/above [hi]. */
    internal fun rampDown(x: Double, lo: Double, hi: Double): Double = 1.0 - rampUp(x, lo, hi)

    /**
     * Trapezoid membership: 0 below [a], ramps to 1 over [a,b], flat 1 over [b,c], ramps to 0 over
     * [c,d], 0 above [d]. Requires `a <= b <= c <= d`.
     */
    internal fun plateau(x: Double, a: Double, b: Double, c: Double, d: Double): Double =
        min(rampUp(x, a, b), rampDown(x, c, d))

    /**
     * How strongly the activity-class ticks should be trusted vs. falling back to HR+motion-only.
     * 0 with no/negligible tick coverage, ramping to 1 once coverage reaches [minTickCoverage].
     */
    internal fun tickReliability(f: WorkoutClassFeatures): Double =
        rampUp(f.tickCoverage, minTickCoverage * 0.3, minTickCoverage)

    /**
     * "No walk/run gait" evidence for the non-foot classes (strength/cycle/ski). When ticks are too
     * sparse to trust, this returns a NEUTRAL 0.5 rather than penalizing — an absent signal must not
     * read as evidence against a class (a WHOOP 4.0 capture has no @63 activity class at all).
     */
    internal fun gaitAbsenceScore(f: WorkoutClassFeatures): Double {
        if (f.tickCoverage < minTickCoverage) return 0.5
        return rampUp(f.stillFraction, 0.40, 0.75)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Per-class scoring
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * RUN: dominant run-classified ticks when available; else a smooth (low-`hrCV`), elevated-%HRR,
     * higher-impact (higher `motionVariance`) fallback signature.
     */
    internal fun runScore(f: WorkoutClassFeatures): Double {
        val tick = rampUp(f.runFraction, 0.15, 0.55)
        val hr = rampUp(f.meanHRRPct ?: 55.0, 45.0, 75.0)
        val motion = plateau(f.motionVariance, 0.05, 0.10, 0.35, 0.60)
        val smooth = rampDown(f.hrCV, 0.05, 0.12)
        val tickWeighted = 0.55 * tick + 0.25 * hr + 0.15 * motion + 0.05 * smooth
        val fallback = 0.45 * hr + 0.35 * motion + 0.20 * smooth
        val rel = tickReliability(f)
        return tickWeighted * rel + fallback * (1 - rel)
    }

    /**
     * WALK: dominant walk-classified ticks when available; else a LOW-moderate %HRR band (walking
     * rarely pushes %HRR high) with modest motion variance (rhythmic but low-impact gait).
     */
    internal fun walkScore(f: WorkoutClassFeatures): Double {
        val tick = rampUp(f.walkFraction, 0.15, 0.55)
        val hr = plateau(f.meanHRRPct ?: 30.0, 5.0, 15.0, 35.0, 55.0)
        val motion = plateau(f.motionVariance, 0.005, 0.02, 0.07, 0.12)
        val tickWeighted = 0.60 * tick + 0.25 * hr + 0.15 * motion
        val fallback = 0.55 * hr + 0.45 * motion
        val rel = tickReliability(f)
        return tickWeighted * rel + fallback * (1 - rel)
    }

    /**
     * STRENGTH: no walk/run gait, BURSTY HR (sets separated by rest reads as high `hrCV`, unlike a
     * steady cardio effort), typically a lower sustained kcal/min than continuous cardio, and LOW
     * motion variance — a rack of lifts swings the wrist/torso through gravity far less than dynamic
     * ski turns or terrain do, which is what separates strength from ski's similarly-bursty-but-more-
     * mobile signature.
     */
    internal fun strengthScore(f: WorkoutClassFeatures): Double {
        val noGait = gaitAbsenceScore(f)
        val bursty = rampUp(f.hrCV, 0.06, 0.16)
        val hr = plateau(f.meanHRRPct ?: 45.0, 15.0, 30.0, 80.0, 100.0)
        val lowBurnRate = rampDown(f.kcalPerMin ?: 6.0, 6.0, 11.0)
        val lowMotion = rampDown(f.motionVariance, 0.05, 0.15)
        // `bursty` carries the most weight deliberately: it's the one genuinely distinctive signal
        // here (HR sawtooth from sets-then-rest). hr/lowBurnRate are generic enough (moderate HR,
        // moderate burn rate) that other steady-effort classes match them too, so a SMOOTH window
        // (bursty ≈ 0) must not still score as strength just by having plausible HR/motion levels.
        return 0.45 * bursty + 0.20 * noGait + 0.20 * lowMotion + 0.10 * hr + 0.05 * lowBurnRate
    }

    /**
     * CYCLE: no walk/run gait, SMOOTH sustained elevated HR (low `hrCV`, unlike strength's sets), and
     * low motion variance — the torso/wrist stays comparatively still relative to on-foot gait.
     */
    internal fun cycleScore(f: WorkoutClassFeatures): Double {
        val noGait = gaitAbsenceScore(f)
        val smooth = rampDown(f.hrCV, 0.04, 0.10)
        val hr = rampUp(f.meanHRRPct ?: 55.0, 35.0, 65.0)
        val stablePosture = rampDown(f.motionVariance, 0.02, 0.08)
        return 0.30 * noGait + 0.30 * smooth + 0.25 * hr + 0.15 * stablePosture
    }

    /**
     * SKI: no walk/run gait, HIGHER and more variable posture signal than cycling (turns/terrain,
     * standing rather than seated), and a wide, intermittent HR pattern (runs interspersed with
     * lift-ride rest — more variable than cycle's steady spin, but not as short-cycle-bursty as
     * strength's sets).
     */
    internal fun skiScore(f: WorkoutClassFeatures): Double {
        val noGait = gaitAbsenceScore(f)
        val variablePosture = plateau(f.motionVariance, 0.06, 0.14, 0.45, 0.70)
        val hr = plateau(f.meanHRRPct ?: 45.0, 20.0, 35.0, 85.0, 100.0)
        val intermittent = plateau(f.hrCV, 0.05, 0.09, 0.20, 0.32)
        return 0.30 * noGait + 0.30 * variablePosture + 0.20 * hr + 0.20 * intermittent
    }
}

/**
 * Builds a [WorkoutClassFeatures] vector for a [start, end] window from the SAME decoded streams
 * [WorkoutDetector]/[AutoWorkoutDetector] already read ([HrSample], [GravitySample], [StepSample]) —
 * no new store, no new decode. Pure/deterministic; slices the caller's lists to the window itself so
 * callers can pass a whole day's streams or an already-sliced window interchangeably. Mirrors Swift
 * `WorkoutTypeFeatureExtractor`.
 */
object WorkoutTypeFeatureExtractor {

    /**
     * @param hr HR samples covering (at least) the window; required — null result if none fall inside.
     * @param gravity gravity samples covering the window (and a little before, ideally, so the first
     *   in-window delta isn't a false 0 — matches [WorkoutDetector.activitySeries] behavior either way).
     * @param steps step/activity-class samples covering the window; may be empty (pre-#316 firmware or
     *   a WHOOP 4.0) — `tickCoverage` reports 0 and the classifier falls back to HR+motion.
     * @param start / @param end window bounds, unix SECONDS (Long, inclusive), e.g. a detected session's.
     * @param restingHR day resting-HR baseline; null → derived from the window's own HR (10th
     *   percentile), same fallback [WorkoutDetector] uses.
     * @param maxHR HRmax; null → [StrainScorer.estimateHRmax] over the window's HR.
     * @param caloriesKcal the window's estimated calories, if already computed; null → `kcalPerMin`
     *   is null.
     */
    fun extract(
        hr: List<HrSample>,
        gravity: List<GravitySample>,
        steps: List<StepSample>,
        start: Long,
        end: Long,
        restingHR: Double? = null,
        maxHR: Double? = null,
        caloriesKcal: Double? = null,
    ): WorkoutClassFeatures? {
        if (end <= start) return null
        val hrWindow = hr.filter { it.ts in start..end }.sortedBy { it.ts }
        if (hrWindow.isEmpty()) return null

        val durationSec = (end - start).toDouble()
        val bpms = hrWindow.map { it.bpm.toDouble() }
        val meanHR = mean(bpms)
        val peakHR = hrWindow.maxOf { it.bpm }
        val hrCV = if (meanHR > 0) stddev(bpms) / meanHR else 0.0

        // %HRR: same fallback ladder as WorkoutDetector.detect — caller-supplied resting/max HR, else
        // derive from the window's own HR.
        val restHR = restingHR ?: WorkoutDetector.deriveRestingHR(hrWindow)
        val effMaxHR = maxHR ?: StrainScorer.estimateHRmax(bpms, null).first.takeIf { it > 0 }
        var meanHRRPct: Double? = null
        if (effMaxHR != null && effMaxHR > restHR) {
            val hrReserve = effMaxHR - restHR
            meanHRRPct = mean(bpms.map { StrainScorer.pctHRR(it, restHR, hrReserve) })
        }

        // Gravity-derived motion shape, via the SAME intensity series WorkoutDetector uses for detection.
        val intensitySeries = WorkoutDetector.activitySeries(gravity)
            .filter { it.ts in start..end }
            .map { it.intensity }
        val motionMean = mean(intensitySeries)
        val motionVariance = variance(intensitySeries)
        val motionCV = if (motionMean > 0) stddev(intensitySeries) / motionMean else 0.0

        // Activity-class tick composition.
        val stepsWindow = steps.filter { it.ts in start..end }
        val validTicks = stepsWindow.mapNotNull { it.activityClass }
        val tickCoverage = min(1.0, validTicks.size.toDouble() / max(1.0, durationSec))
        var stillFraction = 0.0
        var walkFraction = 0.0
        var runFraction = 0.0
        if (validTicks.isNotEmpty()) {
            val n = validTicks.size.toDouble()
            stillFraction = validTicks.count { it == 0 } / n
            walkFraction = validTicks.count { it == 1 } / n
            runFraction = validTicks.count { it == 2 } / n
        }

        val kcalPerMin = caloriesKcal?.let { it / (durationSec / 60.0) }

        return WorkoutClassFeatures(
            durationSec = durationSec, meanHR = meanHR, peakHR = peakHR, meanHRRPct = meanHRRPct,
            hrCV = hrCV, stillFraction = stillFraction, walkFraction = walkFraction,
            runFraction = runFraction, tickCoverage = tickCoverage,
            motionVariance = motionVariance, motionCV = motionCV, kcalPerMin = kcalPerMin,
        )
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Small stats helpers (population variance/stdev; no external dependency)
    // ─────────────────────────────────────────────────────────────────────────

    internal fun mean(xs: List<Double>): Double =
        if (xs.isEmpty()) 0.0 else xs.sum() / xs.size.toDouble()

    internal fun variance(xs: List<Double>): Double {
        if (xs.size <= 1) return 0.0
        val m = mean(xs)
        return xs.sumOf { (it - m) * (it - m) } / xs.size.toDouble()
    }

    internal fun stddev(xs: List<Double>): Double = sqrt(variance(xs))
}
