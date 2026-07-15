import Foundation
import WhoopProtocol

// RecoveryScorer.swift — resting HR during sleep + a transparent 0–100 recovery score.
//
// Ported from server/ingest/app/analysis/recovery.py.
//
// recovery() is a z-score + logistic composite. It is APPROXIMATE — not
// WHOOP-identical (WHOOP's model is proprietary). It is a transparent,
// HRV-dominant, baseline-normalized proxy.
//
// Weighting (documented, grounded, explainable; this is "Charge" in the UI):
//   higher HRV vs baseline       → higher recovery  (W_HRV       = 0.55, dominant)
//   lower resting HR vs baseline → higher recovery  (W_RHR       = 0.20)
//   higher rest quality (sleep)  → higher recovery  (W_SLEEP     = 0.15)
//   lower resp vs baseline       → higher recovery  (W_RESP      = 0.05)
//   skin-temp deviation from 0   → lower recovery   (W_SKIN_TEMP = 0.05)
//
// The Charge/Effort/Rest redesign folds skin temperature in (illness/overreach
// signal): HRV dropped 0.60 → 0.55 to make room for W_SKIN_TEMP = 0.05. The
// skin-temp term is a SYMMETRIC penalty on the ±°C deviation (−|dev|/scale), so any
// drift away from the personal baseline — hot or cold — lowers Charge. It is added
// ONLY when a skin-temp deviation is supplied; when nil the term drops and the
// weights renormalize, leaving the no-skin-temp score IDENTICAL to before.
//
// Two more OPTIONAL, nil-default terms close the gap to Oura Readiness's 8 contributors (an
// Oura-reference validation found Charge already tracks Oura's readiness at r≈0.71; these are
// the two components Charge lacked):
//   overnight resting-HR DECLINE slope ("Recovery Index")      → W_RECOVERY_INDEX    = 0.05
//   previous-day Effort vs personal baseline ("Activity Balance" /
//   "Previous Day Activity", collapsed into one term)          → W_ACTIVITY_BALANCE  = 0.05
// Both are ADDITIVE and NON-BREAKING: each is nil unless the caller supplies it, in which case
// it folds in with its small weight above; when nil the term drops and the weights renormalize
// exactly like the skin-temp term, so the default score for every existing caller is
// BYTE-IDENTICAL to before either term existed. Recovery Index needs no personal baseline (a
// fixed, documented bpm/hour scale, same style as sleepPerf/skin-temp); Activity Balance needs
// BOTH the previous-day Effort value AND its EWMA baseline (`Baselines.strainCfg`) — supplying
// only one drops the term.
//
// Each metric is standardized to a robust z-score against the personal baseline
// (mean + EWMA-abs-dev spread). Missing terms are dropped and the weights
// renormalized. The composite z is squashed through a logistic anchored so that
// Z = 0 → ~58% (WHOOP's published population-average recovery).
//
// Cold-start: if the HRV baseline (dominant driver) is not yet usable
// (< MIN_NIGHTS_SEED valid nights), recovery() returns nil. Callers may use
// RECOVERY_POPULATION_MEAN (58.0) as a fallback but should flag it.

public enum RecoveryScorer {

    // MARK: - Constants (recovery.py)

    public static let wHRV: Double = 0.55
    public static let wRHR: Double = 0.20
    public static let wResp: Double = 0.05
    public static let wSleep: Double = 0.15
    /// Skin-temperature deviation weight (Charge/Effort/Rest redesign). HRV gave up
    /// 0.05 (0.60 → 0.55) to fund it.
    public static let wSkinTemp: Double = 0.05

    /// Skin-temp penalty scale (°C): a 1 °C deviation from baseline costs ≈1 z-unit of
    /// penalty before weighting. Symmetric — sign of the deviation does not matter.
    public static let skinTempScaleC: Double = 1.0

    /// Recovery-Index weight (overnight resting-HR DECLINE slope — Oura's "Recovery Index"
    /// contributor). Small and additive like wSkinTemp: folds in only when a slope is supplied.
    public static let wRecoveryIndex: Double = 0.05

    /// Recovery-Index slope scale (bpm/hour): a slope this many bpm/hour steeper than flat (0)
    /// costs/earns ≈1 z-unit before weighting. Resting HR falling through the night is the
    /// physiologically expected, good pattern; flat or rising (illness, alcohol, a late
    /// stimulant, restlessness) is not. The SIGN carries the meaning (negative = declining =
    /// good), unlike skin-temp's symmetric |deviation| penalty.
    public static let recoveryIndexScaleBpmPerHr: Double = 2.0

    /// Activity-Balance / previous-day-Effort weight (collapses Oura's "Previous Day Activity"
    /// and "Activity Balance" readiness contributors into one term). Small and additive like
    /// wSkinTemp: folds in only when BOTH a previous-day Effort value and its personal EWMA
    /// baseline (`Baselines.strainCfg`) are supplied.
    public static let wActivityBalance: Double = 0.05

    /// Logistic spread: ±2 z-units ≈ full Red–Green band (15%–95%).
    public static let logisticK: Double = 1.6
    /// Logistic offset so Z=0 → 58%.
    public static let logisticZ0: Double = -0.20
    /// WHOOP-published population-average recovery (%). Cold-start fallback.
    public static let populationMean: Double = 58.0

    /// Recovery band thresholds (WHOOP color scheme).
    public static let bandRedMax: Double = 34.0
    public static let bandYellowMax: Double = 67.0

    /// Sleep-performance center ("good night" at ~85% efficiency).
    public static let sleepPerfCenter: Double = 0.85
    /// Sleep-performance scale (±2 z spans the normal range).
    public static let sleepPerfScale: Double = 0.12

    /// Rolling-mean HR window (seconds) for the resting-HR estimate.
    public static let restingHRWindowS: Int = 5 * 60

    /// Minimum HR samples a 5-min bin must hold before its mean is eligible to WIN the resting
    /// floor (#686). A thinly-populated bin — at the limit a single lone beat — lets one artifact
    /// (a dropout, a decode glitch) become the bin "mean" and win the night's minimum, dragging
    /// resting HR implausibly low. Requiring a handful of samples means the floor is a genuine
    /// sustained dip, not a one-sample fluke. Worn nights stream ~1 Hz HR so a real 5-min bin holds
    /// hundreds of samples and clears this trivially; only sparse/edge bins (a partial trailing bin,
    /// a gap-straddling bin) fall below it. Does NOT change the floor DEFINITION — still the min of
    /// 5-min bin means — it only stops an under-sampled artifact bin from being that min.
    public static let restingHRMinBinSamples: Int = 5

    /// Physiological resting-HR floor (bpm) below which a bin mean is rejected as a dropout artifact
    /// (#686), never the resting floor. An adult's true sleeping resting HR essentially never sits
    /// below this; a 5-min mean that does is a run of dropout/decode-zero beats, not a real cardiac
    /// dip. 25 bpm clears even deeply-bradycardic trained athletes (resting HRs in the low 30s) with
    /// margin while rejecting the implausible artifact range. A bin below this is excluded from floor
    /// candidacy; if it were allowed to win, resting HR would read a fabricated sub-physiological value.
    public static let restingHRMinPlausibleBpm: Double = 25.0

    // MARK: - Resting HR

    /// Lowest sustained HR during the in-bed window (bpm, rounded), or nil.
    ///
    /// "Sustained" = the minimum of 5-minute non-overlapping bin means of the HR
    /// samples whose ts ∈ [start, end]. Rejects single-beat dips while capturing
    /// the night's true floor. Returns nil when there are no HR samples in window.
    ///
    /// Artifact hardening (#686): a bin may only WIN the floor when it is BOTH well-populated
    /// (≥ `restingHRMinBinSamples`, so one lone artifact beat can't be a bin "mean") AND
    /// physiologically plausible (mean ≥ `restingHRMinPlausibleBpm`, rejecting dropout-driven
    /// sub-physiological dips). The floor DEFINITION is unchanged — still the minimum of the
    /// 5-min bin means — only artifact bins are barred from being that minimum. If no bin
    /// qualifies (a wholly sparse/degenerate window), fall back to the lowest of ALL bin means,
    /// else the all-sample mean, preserving the never-nil-on-data behaviour.
    public static func restingHR(_ hr: [HRSample], start: Int, end: Int) -> Int? {
        let seg = hr.filter { $0.ts >= start && $0.ts <= end }
        guard !seg.isEmpty else { return nil }

        var means: [Double] = []          // every bin mean (legacy floor, the fallback)
        var qualified: [Double] = []       // bins eligible to WIN the floor (#686)
        var t = start
        while t < end {
            let win = seg.filter { $0.ts >= t && $0.ts < t + restingHRWindowS }
            if !win.isEmpty {
                let mean = Double(win.reduce(0) { $0 + $1.bpm }) / Double(win.count)
                means.append(mean)
                // A bin wins the floor only if it is well-populated AND physiologically plausible —
                // a thin (single-artifact) or sub-physiological (dropout) bin can't be the minimum.
                if win.count >= restingHRMinBinSamples && mean >= restingHRMinPlausibleBpm {
                    qualified.append(mean)
                }
            }
            t += restingHRWindowS
        }
        let floor: Double
        if let m = qualified.min() {
            floor = m
        } else if let m = means.min() {
            // No bin cleared the artifact bar (sparse window): fall back to the legacy floor.
            floor = m
        } else {
            floor = Double(seg.reduce(0) { $0 + $1.bpm }) / Double(seg.count)
        }
        return Int(floor.rounded())
    }

    // MARK: - Recovery Index (overnight HR-decline slope)

    /// Minimum 5-minute bins (`restingHR`'s SAME binning) required before a slope is trusted —
    /// below this, too little of the night has elapsed to fit a trend, and a 1-2-point
    /// regression is noise, not a night-long pattern. 6 bins = 30 minutes of binned coverage,
    /// a deliberately low floor so a short/partial night still gets a number rather than a
    /// routine nil.
    public static let recoveryIndexMinBins: Int = 6

    /// Overnight resting-HR DECLINE slope (bpm/hour) across the in-bed window — the "Recovery
    /// Index" component of Oura's Readiness that Charge lacked (it previously only read the
    /// overnight FLOOR via `restingHR` above, never the trend that reaches it).
    ///
    /// Computed as the least-squares slope of the SAME non-overlapping 5-minute HR bin means
    /// `restingHR` uses (`restingHRWindowS`) against each bin's midpoint time (hours from
    /// `start`). NEGATIVE = declining (HR falling through the night — the physiologically
    /// expected, good pattern); POSITIVE = rising (restlessness, illness, alcohol, a late
    /// stimulant). Returns nil when fewer than `recoveryIndexMinBins` bins have data (too
    /// little of the window to fit a trend) or there are no samples at all — it never
    /// fabricates a slope from a sliver of the night.
    public static func recoveryIndexSlope(_ hr: [HRSample], start: Int, end: Int) -> Double? {
        let seg = hr.filter { $0.ts >= start && $0.ts <= end }
        guard !seg.isEmpty else { return nil }

        // Same non-overlapping 5-minute binning as restingHR: both read the identical
        // underlying series, one as a floor, one as a trend across it.
        var points: [(tHours: Double, meanBpm: Double)] = []
        var t = start
        while t < end {
            let win = seg.filter { $0.ts >= t && $0.ts < t + restingHRWindowS }
            if !win.isEmpty {
                let mean = Double(win.reduce(0) { $0 + $1.bpm }) / Double(win.count)
                let midpointS = Double(t - start) + Double(restingHRWindowS) / 2.0
                points.append((tHours: midpointS / 3600.0, meanBpm: mean))
            }
            t += restingHRWindowS
        }
        guard points.count >= recoveryIndexMinBins else { return nil }

        // Least-squares slope: Σ((t-t̄)(y-ȳ)) / Σ((t-t̄)²), bpm per hour.
        let n = Double(points.count)
        let tBar = points.reduce(0.0) { $0 + $1.tHours } / n
        let yBar = points.reduce(0.0) { $0 + $1.meanBpm } / n
        var num = 0.0, den = 0.0
        for p in points {
            let dt = p.tHours - tBar
            num += dt * (p.meanBpm - yBar)
            den += dt * dt
        }
        // Degenerate (all bins at the same instant): no time spread to fit against.
        guard den > 1e-9 else { return 0.0 }
        return num / den
    }

    // MARK: - Recovery band

    /// WHOOP-style color band for a recovery score [0, 100].
    public static func band(_ score: Double) -> String {
        if score < bandRedMax { return "red" }
        if score < bandYellowMax { return "yellow" }
        return "green"
    }

    // MARK: - Cold-start calibration progress

    /// The recovery baseline's real seed count while it still cold-starts — the honest
    /// "Calibrating — N of <seed> nights" progress the dashboard shows in place of a bare empty state;
    /// nil once recovery exists or the baseline has crossed the seed gate. N is the HRV baseline's
    /// `nValid` from folding the SAME day-keyed, epoch-aware history the recovery engine folds
    /// (`Baselines.foldHistory(_:dayKeys:cfg:baselineEpoch:)`), NOT a looser per-night bounds count.
    ///
    /// The old count advanced on every in-range night, including nights the engine's fold DROPS after a
    /// manual "Recalibrate HRV baseline" (each night dated before the epoch is discarded, not
    /// skip-and-held). A genuinely-calibrating user who had ≥ seed old in-range nights therefore read
    /// `count ≥ seed → nil` here, and the Today score side fell through to "Needs the strap" while the
    /// post-recalibration baseline was still seeding (Bug B, #393 follow-up). `nValid` is the exact count
    /// `Baselines.computeStatus` gates CALIBRATING on, so N now tracks the baseline the Charge ring rides
    /// and can never over-state it. Never claims "calibrating" at/above the seed gate (a nil recovery
    /// there is some other gap). `baselineEpoch` nil reads the persisted HRV epoch from UserDefaults,
    /// exactly like the engine's fold. Mirrors Android TodayScreen.recoveryCalibrationNights
    /// (RecoveryCalibrationTest is the oracle).
    public static func calibrationNights(nightlyHrv: [Double?],
                                         dayKeys: [String],
                                         hasRecovery: Bool,
                                         seed: Int = Baselines.minNightsSeed,
                                         cfg: MetricCfg = Baselines.hrvCfg,
                                         baselineEpoch: Double? = nil) -> Int? {
        guard !hasRecovery else { return nil }
        let n = Baselines.foldHistory(nightlyHrv, dayKeys: dayKeys, cfg: cfg,
                                      baselineEpoch: baselineEpoch).nValid
        // Include 0: a brand-new user (no banked nights yet) should read "Calibrating — 0 of N" on the
        // Charge ring, not a bare "No data" that looks broken (#335). Past days are gated to nil by the
        // caller; >= seed (recovery should exist) still returns nil.
        return (0..<seed).contains(n) ? n : nil
    }

    // MARK: - Recovery score

    /// A baseline driver: mean + spread (internal abs-dev units, as in BaselineState).
    public struct DriverBaseline: Equatable, Sendable {
        public let mean: Double
        public let spread: Double
        public init(mean: Double, spread: Double) {
            self.mean = mean; self.spread = spread
        }
        public init(_ state: BaselineState) {
            self.mean = state.baseline; self.spread = state.spread
        }
    }

    /// Robust z-score using EWMA spread: (value − mean) / (1.253 × spread).
    static func zScore(_ value: Double, mean: Double, spread: Double) -> Double {
        let sigma = max(1.253 * spread, 1e-9)
        return (value - mean) / sigma
    }

    /// Z-score + logistic recovery score in [0, 100]. APPROXIMATE.
    ///
    /// Returns nil when the HRV baseline (dominant driver) is not yet usable, or
    /// no valid driver is available at all.
    ///
    /// - Parameters:
    ///   - hrv: tonight's HRV (RMSSD, ms).
    ///   - rhr: tonight's resting HR (bpm).
    ///   - resp: tonight's respiration (raw or calibrated — z is scale-invariant);
    ///           nil drops the term.
    ///   - hrvBaseline: HRV baseline (required for a score).
    ///   - rhrBaseline: resting-HR baseline; nil drops the RHR term.
    ///   - respBaseline: respiration baseline; nil drops the resp term.
    ///   - sleepPerf: Rest quality (Rest composite ÷100, 0..1; was raw efficiency);
    ///     nil drops the term.
    ///   - skinTempDev: skin-temperature deviation from the personal baseline (±°C,
    ///     `DailyMetric.skinTempDevC`). Entered as a SYMMETRIC penalty −|dev|/scale,
    ///     weight wSkinTemp. nil drops the term and the weights renormalize so the
    ///     no-skin-temp score is identical to before.
    ///   - hrvBaselineUsable: whether the HRV baseline has enough nights
    ///     (BaselineState.usable). When false, returns nil (cold-start).
    ///   - recoveryIndexSlope: overnight resting-HR DECLINE slope (bpm/hour, from
    ///     `recoveryIndexSlope(_:start:end:)`). Negative (declining) supports recovery;
    ///     positive (rising) limits it, weight wRecoveryIndex. nil (the default) drops the
    ///     term and the weights renormalize, so the no-slope score is IDENTICAL to before
    ///     this parameter existed.
    ///   - effortBaseline: personal EWMA baseline of daily Effort/strain (`Baselines.strainCfg`).
    ///     Needs `priorDayEffort` too — supplying only one drops the term.
    ///   - priorDayEffort: yesterday's Effort/strain (0-100, `StrainScorer.strain`). Lower vs
    ///     `effortBaseline` supports recovery, same "lower is better" direction as RHR/resp,
    ///     weight wActivityBalance. nil (the default, like effortBaseline) drops the term and
    ///     the weights renormalize, so the no-effort score is IDENTICAL to before either
    ///     parameter existed.
    public static func recovery(hrv: Double,
                                rhr: Double,
                                resp: Double?,
                                hrvBaseline: DriverBaseline?,
                                rhrBaseline: DriverBaseline?,
                                respBaseline: DriverBaseline?,
                                sleepPerf: Double?,
                                skinTempDev: Double? = nil,
                                hrvBaselineUsable: Bool = true,
                                recoveryIndexSlope: Double? = nil,
                                effortBaseline: DriverBaseline? = nil,
                                priorDayEffort: Double? = nil) -> Double? {
        // Cold-start gate: HRV is the dominant driver; if its baseline isn't
        // usable, refuse to score (more honest than a fabricated value).
        if !hrvBaselineUsable { return nil }

        var terms: [(z: Double, w: Double)] = []

        // HRV term: higher is better.
        if let b = hrvBaseline {
            terms.append((zScore(hrv, mean: b.mean, spread: b.spread), wHRV))
        }
        // RHR term: lower is better → (μ − x) / σ.
        if let b = rhrBaseline {
            terms.append((zScore(b.mean, mean: rhr, spread: b.spread), wRHR))
        }
        // Resp term: lower is better, optional.
        if let r = resp, let b = respBaseline {
            terms.append((zScore(b.mean, mean: r, spread: b.spread), wResp))
        }
        // Sleep-performance / Rest-quality term: no baseline needed; centered at SLEEP_PERF_CENTER.
        if let sp = sleepPerf {
            terms.append(((sp - sleepPerfCenter) / sleepPerfScale, wSleep))
        }
        // Skin-temp term: SYMMETRIC penalty on |deviation| (illness/overreach). Any
        // drift from the personal baseline lowers Charge; added only when supplied.
        if let dev = skinTempDev {
            terms.append((-abs(dev) / skinTempScaleC, wSkinTemp))
        }
        // Recovery-Index term: overnight HR-DECLINE slope (bpm/hour). No baseline needed (a
        // fixed, documented scale, same style as sleepPerf/skin-temp). Negative (declining)
        // supports recovery; positive (rising) limits it. Added only when supplied.
        if let slope = recoveryIndexSlope {
            terms.append((-slope / recoveryIndexScaleBpmPerHr, wRecoveryIndex))
        }
        // Activity-Balance / previous-day-Effort term: lower vs personal baseline is better,
        // same "lower is better" direction as RHR/resp → (μ − x) / σ. Needs BOTH the value
        // and a baseline, matching resp's pattern; added only when both are supplied.
        if let e = priorDayEffort, let b = effortBaseline {
            terms.append((zScore(b.mean, mean: e, spread: b.spread), wActivityBalance))
        }

        guard !terms.isEmpty else { return nil }
        let totalWeight = terms.reduce(0) { $0 + $1.w }
        guard totalWeight > 0 else { return nil }

        let z = terms.reduce(0) { $0 + $1.z * $1.w } / totalWeight
        let score = 100.0 / (1.0 + exp(-logisticK * (z - logisticZ0)))
        return max(0.0, min(100.0, score))
    }

    /// Convenience overload taking BaselineState directly. Enforces the cold-start
    /// gate using `hrvBaseline.usable`.
    public static func recovery(hrv: Double,
                                rhr: Double,
                                resp: Double?,
                                hrvBaseline: BaselineState,
                                rhrBaseline: BaselineState?,
                                respBaseline: BaselineState?,
                                sleepPerf: Double?,
                                skinTempDev: Double? = nil,
                                recoveryIndexSlope: Double? = nil,
                                effortBaseline: BaselineState? = nil,
                                priorDayEffort: Double? = nil) -> Double? {
        recovery(hrv: hrv,
                 rhr: rhr,
                 resp: resp,
                 hrvBaseline: DriverBaseline(hrvBaseline),
                 rhrBaseline: rhrBaseline.map(DriverBaseline.init),
                 respBaseline: respBaseline.map(DriverBaseline.init),
                 sleepPerf: sleepPerf,
                 skinTempDev: skinTempDev,
                 hrvBaselineUsable: hrvBaseline.usable,
                 recoveryIndexSlope: recoveryIndexSlope,
                 effortBaseline: effortBaseline.map(DriverBaseline.init),
                 priorDayEffort: priorDayEffort)
    }
}
