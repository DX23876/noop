import Foundation
import WhoopProtocol

// StrainScorer.swift — cardiovascular load on a 0–100 logarithmic strain ("Effort") scale.
//
// Ported from server/ingest/app/analysis/strain.py. INDEPENDENT implementation of
// published exercise-physiology methods (WHOOP-*like*, not a reproduction of the
// proprietary algorithm; not medical advice).
//
// Scale: WHOOP's Strain axis is 0–21; NOOP shows Effort on 0–100 (`maxStrain`), the same value
// rescaled. Internal metric key stays `strain`.
//
// Pipeline (#2438, since AI-32):
//   1. Heart-Rate Reserve (Karvonen): HRR = HRmax − RHR, HRmax from `MaxHeartRate`.
//   2. Per-sample intensity x = (HR − RHR) / HRR × 100 % HRR, clamped 0..100.
//   3. Load: each sample adds `effortWeight(x)` × its minutes, e^(beta (x − 55) / 10) faded out below
//      20 % HRR. Outside workouts a sample below 50 % HRR adds nothing (`LowIntensity`).
//   4. Score: a × ln(1 + load / k) on 0–21, softly capped below 21 (`effortScore21`), shown on 0–100.
//   The constants are fitted on WHOOP's Strain of the workouts contributed to #2438 (see "Effort curve").
//
// The Training Load cardio lane keeps its own Banister TRIMP (`banisterTrainingLoad`) and the Edwards
// log map (`trimpToStrain`, `strainDenominator`) for its Effort view.
//
// References: Karvonen 1957 (%HRR); Edwards 1993 (5-zone TRIMP, zone buckets); Banister 1991
// (exponential TRIMP, Training Load lane; Morton, Fitz-Clarke and Banister 1990 publish 0.64·e^(1.92x) for
// men and 0.86·e^(1.67x) for women, selected together, see `BanisterCoefficients`); Gellish 2007 (HRmax
// start value).

public enum StrainScorer {

    /// Additive cardiovascular work and its existing user-facing compression, from one HR series.
    public struct CardioLoadResult: Equatable, Sendable {
        public let trimp: Double
        public let effort: Double
        public let sampleCount: Int
        public let spanSeconds: Int

        public init(trimp: Double, effort: Double, sampleCount: Int, spanSeconds: Int) {
            self.trimp = trimp
            self.effort = effort
            self.sampleCount = sampleCount
            self.spanSeconds = spanSeconds
        }
    }

    // MARK: - Constants (strain.py)

    /// Minimum HR readings before computing strain on a DENSE stream (≈10 min at 1 Hz).
    public static let minReadings: Int = 600
    /// Sparse-stream acceptance (#482/#480): a low-cadence strap — the WHOOP 5/MG sends live
    /// standard HR only ~every 30 s — would need ~5 h of continuous wear to reach `minReadings`,
    /// so Effort sat un-scored (nil → the gauge showed a stale prior-day value) for most of the day.
    /// Also accept once the HR series SPANS at least `minSpanSeconds` of wall-clock with a small
    /// sample floor. This never fabricates load: TRIMP still integrates honestly over whatever HR is
    /// there, so a genuine low-HR day scores 0 either way — it just lets the live gauge reflect TODAY
    /// instead of yesterday. A dense 1 Hz stream is unaffected (it clears `minReadings` first).
    public static let minSparseReadings: Int = 20
    /// Wall-clock coverage (seconds) that qualifies a sparse stream. 600 s = 10 min, matching the
    /// dense gate's ≈10 min of 600 × 1 Hz samples, so both cadences trust the number at the same age.
    public static let minSpanSeconds: Int = 600
    /// Top of the strain ("Effort") scale. Rescaled 21.0 → 100.0 for the
    /// Charge/Effort/Rest redesign; only the output scale changes, the curve does not.
    public static let maxStrain: Double = 100.0

    /// Top of WHOOP's Day Strain axis. Kept beside `maxStrain` so every value inherited from the
    /// old/WHOOP 0–21 axis can be mapped onto NOOP's current axis through one proportional rule.
    public static let whoopMaxStrain: Double = 21.0

    /// Map any value on WHOOP's 0–21 Day Strain axis onto NOOP's current 0–`maxStrain` Effort axis.
    /// This is deliberately a value conversion, not a one-off threshold constant: callers carrying
    /// any range boundary from the 0–21 scale must pass it through the same mapping.
    /// Kotlin twin: `StrainScorer.effortValueFromWhoopStrain`. Multiplies by the pre-divided ratio so
    /// the result is bit-identical to the importers' existing rescale of the same fact
    /// (`WhoopExportImporter.dayStrainToEffortScale`, `WhoopCsvImporter.DAY_STRAIN_TO_EFFORT_SCALE`);
    /// `value * maxStrain / whoopMaxStrain` disagrees with them by an ULP on about a quarter of inputs.
    public static func effortValue(fromWhoopStrain value: Double) -> Double {
        value * (maxStrain / whoopMaxStrain)
    }

    /// Logarithmic-map denominator D. Chosen so the Edwards daily ceiling
    /// (top zone weight 5 sustained 24 h = 7200) maps to exactly maxStrain:
    /// D = 7200 + 1 = 7201 makes ln(7201)/ln(7201) = 1.
    public static let strainDenominator: Double = 7201.0
    static var lnStrainDenominator: Double { log(strainDenominator) }

    /// Banister's daily ceiling: 24 h held at ΔHRR = 1.0. Unlike Edwards' 7200 this is SEX-DEPENDENT,
    /// because BOTH coefficients differ — which is the whole reason `strainDenominator` cannot be reused
    /// for it. Feeding Banister TRIMP through the Edwards denominator would score every day against a
    /// ceiling ~13% (men) or ~9% (women) higher than Banister can actually reach, so nobody would ever
    /// see 100 and the two methods would not be on the same axis. (#1545; women's ceiling 6,579 with the
    /// published 0.86 since upstream #2835, men's unchanged at 6,286.)
    static func banisterDailyCeiling(_ c: BanisterCoefficients) -> Double {
        24.0 * 60.0 * 1.0 * c.scale * exp(c.b)
    }

    /// Fallback per-sample duration (minutes) — 1 s at 1 Hz.
    static let fallbackSampleMin: Double = 1.0 / 60.0

    public static let defaultAge: Int = 30
    public static let defaultRestingHR: Double = 60

    /// Minimum HR samples before the observed high-percentile HRmax is trusted.
    public static let hrmaxMinSamples: Int = 600
    /// Upper percentile for the observed-HRmax estimate.
    public static let hrmaxPercentile: Double = 99.5

    /// Banister's two coefficients, which are a PAIR and travel as one (upstream #2835, ported to the fork's
    /// Training Load lane).
    ///
    /// Morton, Fitz-Clarke and Banister (1990) publish `0.64·e^(1.92x)` for men and `0.86·e^(1.67x)` for
    /// women. The lane held the exponent per sex and the multiplier as a single 0.64 for everyone, so a
    /// woman was priced with the women's exponent and the men's multiplier: neither published pair. One
    /// value for both makes selecting half of a pair impossible to express.
    public struct BanisterCoefficients: Equatable, Sendable {
        /// The multiplier: 0.64 men, 0.86 women, 0.75 neither.
        public let scale: Double
        /// The exponent: 1.92 men, 1.67 women, 1.795 neither.
        public let b: Double
        public init(scale: Double, b: Double) {
            self.scale = scale
            self.b = b
        }
    }

    /// The published numbers, as named constants. `banisterScale` is the men's multiplier (upstream keeps
    /// the name for its parity ledger). Read them through `banisterCoefficients(sex:)`, never one half alone.
    public static let banisterScale: Double = 0.64
    public static let banisterScaleWomen: Double = 0.86
    public static let banisterBMen: Double = 1.92
    public static let banisterBWomen: Double = 1.67

    /// Edwards zone cut-offs as (%HRR threshold, weight), highest-first.
    static let edwardsZones: [(threshold: Double, weight: Int)] = [
        (90.0, 5), (80.0, 4), (70.0, 3), (60.0, 2), (50.0, 1),
    ]

    // MARK: - Effort curve (#2438)
    //
    // Fit of 2026-10-28 on the 15 WHOOP exports contributed to #2438 (DX23876/effort-calibration f8e1304,
    // spec `PROPOSED`, rerun on the same data; published rounded as a 5.48, k 12.4, beta 0.567). Every heart
    // rate reading weighs `effortWeight` of its intensity per minute, the day or workout sums them into a
    // load, and `effortScore21` maps the load onto 0–21 with a soft cap, so 21 stays out of reach while the
    // hardest days reach 19 to 20. The fitted values come from the WHOOP Strain of 3,760 workouts; `a`, `k`
    // and `beta` are fitted, the floor and the cap are set.

    /// Scale of the log curve.
    public static let effortCurveA: Double = 5.4591
    /// Load at which the log curve bends.
    public static let effortCurveK: Double = 12.2245
    /// Growth of a minute's weight per 10 % HRR.
    public static let effortWeightBeta: Double = 0.5646
    /// Intensity (% HRR) at which one minute weighs 1: the middle of zone 1.
    public static let effortWeightReference: Double = 55
    /// Below this intensity (% HRR) a minute weighs almost nothing; the step is `effortFloorWidth` wide.
    public static let effortFloor: Double = 20
    public static let effortFloorWidth: Double = 3
    /// Exponent of the soft cap at 21.
    public static let effortCapExponent: Double = 8
    /// Outside workouts heart rate counts from this intensity (% HRR), where Edwards' zone 1 began. Below
    /// it, a whole day of standing and walking would otherwise add up to a hard day (#2438 step 2 open).
    public static let effortOutsideWorkoutFloor: Double = 50

    /// Where heart rate below `effortOutsideWorkoutFloor` counts.
    public enum LowIntensity: Hashable, Sendable {
        /// Everywhere: the series is one workout.
        case counted
        /// Only inside these workout spans (`[start, end)`, unix seconds): a day with its workouts.
        case countedIn([Range<Int>])
    }

    /// Weight of one minute at intensity `x` (% HRR): e^(beta (x − 55) / 10), faded out below 20 % HRR.
    public static func effortWeight(pctHRR x: Double) -> Double {
        let z = max(-50, min(50, (x - effortFloor) / effortFloorWidth))
        return exp(effortWeightBeta * (x - effortWeightReference) / 10) / (1 + exp(-z))
    }

    /// A load on WHOOP's 0–21 axis: a × ln(1 + load / k), softly capped below 21.
    public static func effortScore21(load: Double) -> Double {
        let b = effortCurveA * log1p(max(0, load) / effortCurveK)
        guard b > 0 else { return 0 }
        let p = effortCapExponent, m = max(b, 21)   // scaled by the larger term so the power cannot overflow
        return min(21 * b / (m * pow(pow(b / m, p) + pow(21 / m, p), 1 / p)), (21.0).nextDown)
    }

    /// A load on NOOP's 0–100 Effort axis, two decimals, never 100.
    public static func effortValue(load: Double) -> Double {
        let value = effortScore21(load: load) / whoopMaxStrain * maxStrain
        return min((value * 100).rounded() / 100, maxStrain - 0.01)
    }

    /// Load one strength minute adds per point of session RPE (#2438, behind the Lab switch for strength).
    /// Heart rate misses what lifting asks of the muscles, so a rated strength session adds Foster's session
    /// RPE × minutes, scaled into this curve's load. Fitted on 419 WHOOP strength sessions of 9 contributors as
    /// the median load WHOOP gave beyond heart rate, ASSUMING RPE 7 for each (the exports carry no rating);
    /// leaving out one person at a time moves it between 0.085 and 0.123.
    public static let effortStrengthLoadPerRPEMinute: Double = 0.11

    /// The load a strength session of `minutes` rated `rpe` (1 to 10) adds before the curve.
    public static func strengthLoad(rpe: Double, minutes: Double) -> Double {
        guard rpe.isFinite, minutes.isFinite, rpe > 0, minutes > 0 else { return 0 }
        return effortStrengthLoadPerRPEMinute * min(rpe, 10) * minutes
    }

    /// The load that scores `value` on the 0–100 axis: the inverse of `effortValue(load:)`, so a stored score
    /// can take a strength load on top.
    public static func effortLoad(forEffortValue value: Double) -> Double {
        let s = max(0, min(value, maxStrain - 0.01)) / maxStrain * whoopMaxStrain
        guard s > 0 else { return 0 }
        let p = effortCapExponent
        let b = s * 21 / pow(pow(21, p) - pow(s, p), 1 / p)
        return effortCurveK * expm1(b / effortCurveA)
    }

    /// `value` (0–100) with a strength load added before the curve.
    public static func effortValue(_ value: Double, addingStrengthLoad load: Double) -> Double {
        guard load > 0 else { return value }
        return effortValue(load: effortLoad(forEffortValue: value) + load)
    }

    /// The load of a heart-rate series: each reading's `effortWeight` × its minutes. Below
    /// `effortOutsideWorkoutFloor` a reading counts only where `lowIntensity` says it is in a workout.
    static func effortLoad(_ hr: [HRSample], restingHR: Double, hrReserve: Double, durations: [Double],
                           lowIntensity: LowIntensity) -> Double {
        var load = 0.0
        for i in hr.indices {
            let x = pctHRR(Double(hr[i].bpm), restingHR: restingHR, hrReserve: hrReserve)
            if x < effortOutsideWorkoutFloor {
                switch lowIntensity {
                case .counted: break
                case .countedIn(let spans): if !spans.contains(where: { $0.contains(hr[i].ts) }) { continue }
                }
            }
            load += effortWeight(pctHRR: x) * durations[i]
        }
        return load
    }

    // MARK: - HRmax helpers

    /// Tanaka (2001): HRmax = 208 − 0.7 × age (gender-independent).
    public static func tanakaHRmax(age: Double) -> Double { 208.0 - 0.7 * age }

    /// Classic 220 − age. Last-resort fallback only.
    public static func defaultMaxHR(age: Int = defaultAge) -> Int { 220 - age }

    /// Linear-interpolated percentile of an already-sorted sequence (numpy-style).
    static func percentile(_ sortedValues: [Double], _ pct: Double) -> Double {
        let n = sortedValues.count
        if n == 0 { return 0 }
        if n == 1 { return sortedValues[0] }
        let position = (pct / 100.0) * Double(n - 1)
        let lower = Int(position)
        let upper = min(lower + 1, n - 1)
        let frac = position - Double(lower)
        return sortedValues[lower] + frac * (sortedValues[upper] - sortedValues[lower])
    }

    /// Estimate a personalized HRmax from a trailing HR series.
    /// Returns (hrmax bpm, source) where source ∈ {"observed", "tanaka", "unknown"}.
    public static func estimateHRmax(_ hrHistory: [Double], age: Double?) -> (Double, String) {
        let n = hrHistory.count
        let tanaka = age.map { tanakaHRmax(age: $0) }

        if n >= hrmaxMinSamples {
            let observed = percentile(hrHistory.sorted(), hrmaxPercentile)
            guard let t = tanaka else { return (observed, "observed") }
            return observed >= t ? (observed, "observed") : (t, "tanaka")
        }
        if let t = tanaka { return (t, "tanaka") }
        return (0.0, "unknown")
    }

    // MARK: - Karvonen %HRR and Edwards zone weight

    /// Karvonen %HRR, clamped [0, 100].
    ///
    /// Public so `EffortFeasibility` can ask what a PLANNED heart rate would be worth without a second
    /// copy of the formula. Answering "what is 20 minutes in Zone 2 actually worth?" has to use the same
    /// arithmetic that scores the day, or the coach's promise and the wearer's result diverge.
    public static func pctHRR(_ bpm: Double, restingHR: Double, hrReserve: Double) -> Double {
        let pct = (bpm - restingHR) / hrReserve * 100.0
        if pct < 0 { return 0 }
        if pct > 100 { return 100 }
        return pct
    }

    /// Edwards 5-zone weight (0–5) from %HRR (unclamped; extremes agree with
    /// the clamped path at both ends). Public for the same reason as ``pctHRR(_:restingHR:hrReserve:)``.
    public static func zoneWeight(_ bpm: Double, restingHR: Double, hrReserve: Double) -> Int {
        let pct = (bpm - restingHR) / hrReserve * 100.0
        for (threshold, weight) in edwardsZones where pct >= threshold { return weight }
        return 0
    }

    // MARK: - TRIMP accumulation

    /// Longest span (minutes) a single reading may be credited with. A wear or connection dropout leaves a
    /// gap with no data in it; without a ceiling the last reading before the gap would be credited with the
    /// whole of it, so one sample in zone 5 could invent hours of effort. 2 min is 4x the sparsest real
    /// cadence we know of (the 5/MG's ~30 s, see `minSparseReadings`), so no genuine cadence is truncated.
    public static let maxSampleGapMin: Double = 2.0

    /// The one Effort figure every read-out on Today must show (#1001).
    ///
    /// Effort has two sources. `stored` is the daily row, rewritten only when the heavy daily pass runs.
    /// `live` is today's in-progress recompute over the raw HR stream (local midnight → now), which
    /// exists precisely because the stored row lags — early in the day it still holds yesterday's Effort
    /// or a stale 0.0 (#402). Past days have no live value and use the row.
    ///
    /// Taking the MAX rather than preferring `live` is not a tie-break: Effort accrues over a day and
    /// must never visibly DROP. The live recompute can UNDER-read when today's HR is sparse, or when a
    /// logged workout's load is not in the raw stream — a 5/MG user who trained in the morning had a real
    /// 38.3 replaced by a live 0 (#489/#506). Flooring at what is already earned is what stops that.
    ///
    /// Shared so the hero ring, the Key Metrics tile and the chart's edge badge cannot drift apart: they
    /// each resolved Effort themselves, and only the ring knew about `live`, so an active morning showed
    /// 2.3 on the ring and 0.5 in the other two until the daily pass caught up (#1001).
    public static func effectiveEffort(live: Double?, stored: Double?) -> Double? {
        guard let live else { return stored }
        guard let stored else { return live }
        if live == 0.0 && stored == 0.0 { return 0.0 }
        return Swift.max(live, stored)
    }

    /// Infer per-sample duration (minutes) from the first two timestamps. Falls
    /// back to 1 s when fewer than two samples or coincident timestamps.
    ///
    /// No production caller remains — TRIMP uses `sampleDurationsMinutes` (#950). Kept ONLY so the
    /// uniform-identity regression test can compare the new accumulation against the SHIPPED old formula
    /// rather than a reimplementation of it. Delete it if that test ever goes.
    static func sampleDurationMinutes(_ hr: [HRSample]) -> Double {
        guard hr.count >= 2 else { return fallbackSampleMin }
        let deltaS = abs(Double(hr[1].ts - hr[0].ts))
        return deltaS > 0 ? deltaS / 60.0 : fallbackSampleMin
    }

    /// Per-sample durations (minutes): each reading covers the gap to the NEXT one, clamped to
    /// `maxSampleGapMin`; the last reuses the gap before it.
    ///
    /// #950: TRIMP used to take ONE duration inferred from the first two timestamps and multiply the whole
    /// zone-weight sum by it. NOOP's HR stream is not uniformly spaced — live Bluetooth arrives ~1 s apart,
    /// banked 5/MG history ~30 s, and dropouts leave larger holes — so whichever gap happened to be first
    /// set the scale for the entire window. Worse, a workout window and the day that contains it start at
    /// different samples, so they picked different factors and the two Effort numbers stopped being
    /// comparable, which is what the report was about.
    ///
    /// For a UNIFORMLY spaced series every gap is the same, so this returns the old value for every sample
    /// and the resulting TRIMP is unchanged — which is why no existing test moves. Byte-parity twin of
    /// Kotlin `sampleDurationsMinutes`.
    static func sampleDurationsMinutes(_ hr: [HRSample]) -> [Double] {
        if hr.isEmpty { return [] }
        if hr.count == 1 { return [fallbackSampleMin] }
        var out: [Double] = []
        out.reserveCapacity(hr.count)
        for i in 0..<(hr.count - 1) {
            let deltaS = abs(Double(hr[i + 1].ts - hr[i].ts))
            let minutes = deltaS > 0 ? deltaS / 60.0 : fallbackSampleMin
            out.append(min(minutes, maxSampleGapMin))
        }
        out.append(out[out.count - 1])   // the final reading has no successor; reuse the gap before it
        return out
    }

    static func edwardsTRIMP(_ hr: [HRSample], restingHR: Double, hrReserve: Double,
                             durations: [Double]) -> Double {
        var acc = 0.0
        for i in hr.indices {
            acc += Double(zoneWeight(Double(hr[i].bpm), restingHR: restingHR, hrReserve: hrReserve))
                * durations[i]
        }
        return acc
    }

    /// Minutes in each Edwards zone, indexed by the zone's own weight: `[0]` is time BELOW zone 1,
    /// `[1...5]` are zones 1 to 5.
    ///
    /// `[0]` is the bucket no existing line can show. Edwards scores sub-50 %HRR time as exactly zero, so
    /// it never reaches `trimp` and nothing downstream reports it, yet it is the quantity #2438's step 2
    /// proposes to weight. `[1...5]` are the zone shares step 1 fits its weights on, readable until now
    /// only from a WHOOP export rather than from what NOOP itself saw.
    ///
    /// Sums to the same duration TRIMP integrates over, so the six buckets and `trimp` describe exactly
    /// the same time. That is CREDITED time, not wall-clock wear: `sampleDurationsMinutes` clamps each
    /// reading to `maxSampleGapMin`, so a ten-minute dropout contributes two minutes here. Anyone wanting
    /// a wear-coverage floor (#2438 step 2) needs a different quantity, and summing these will not give
    /// it to them.
    ///
    /// The caller must pass `hrReserve > 0`: `zoneWeight` divides by it, and the refusal path reaches this
    /// line with a reserve that can be zero or negative.
    ///
    /// Byte-identical to the Kotlin twin `StrainScorer.zoneMinutes`.
    static func zoneMinutes(_ hr: [HRSample], restingHR: Double, hrReserve: Double,
                            durations: [Double]) -> [Double] {
        var out = [Double](repeating: 0.0, count: 6)
        for i in hr.indices {
            out[zoneWeight(Double(hr[i].bpm), restingHR: restingHR, hrReserve: hrReserve)] += durations[i]
        }
        return out
    }

    /// - Parameter floorRatePerMinute: per-minute rate treated as "no effort" and subtracted from EVERY
    ///   sample, floored at zero (#1624). Zero — the default — is the original, unfloored Banister recipe,
    ///   so every existing caller and test is byte-identical. Pass `banisterBaselineRatePerMinute` to
    ///   score the excess over a sedentary day, which is what the daily scorer does.
    ///
    ///   Per SAMPLE, never as one lump off the total: a day quieter than the floor would otherwise run a
    ///   deficit that eats into real work done on top, and 90 minutes at 35% HRR inside an otherwise still
    ///   day would net negative and clamp to zero — erasing exactly the intermittent effort this recipe
    ///   exists to capture.
    static func banisterTRIMP(_ hr: [HRSample], restingHR: Double, hrReserve: Double,
                              durations: [Double], _ c: BanisterCoefficients,
                              floorRatePerMinute: Double = 0.0) -> Double {
        var acc = 0.0
        for i in hr.indices {
            let x = pctHRR(Double(hr[i].bpm), restingHR: restingHR, hrReserve: hrReserve) / 100.0
            if x > 0 {
                let rate = x * c.scale * exp(c.b * x)
                acc += durations[i] * max(rate - floorRatePerMinute, 0.0)
            }
        }
        return acc
    }

    // MARK: - Logarithmic map

    /// Map accumulated TRIMP onto [0, 100] via 100 × ln(TRIMP+1) / ln(D), 2 dp.
    /// TRIMP ≤ 0 → 0, and D ≤ 1 (or NaN) → 0, being outside the map's domain. The output is
    /// unbounded as D → 1⁺ — an upper clamp is tracked separately.
    ///
    /// The default D is **Edwards'**. A Banister TRIMP passed here without an explicit denominator is
    /// scored against the wrong ceiling and reads low — prefer `strain(…)`, which resolves the
    /// method's own denominator, or pass `logMapDenominator(method:sex:)` yourself. (#1545)
    public static func trimpToStrain(_ trimp: Double, denominator: Double = strainDenominator) -> Double {
        if trimp <= 0 { return 0 }
        // D ≤ 1 (and NaN) is outside the map's domain: ln(1) = 0 divides to ±∞, ln(D) < 0 below 1
        // flips the sign, and ln(D) is NaN at or below 0. Out-of-domain D is no score, like
        // TRIMP ≤ 0 — before this guard D = 1 returned +Inf here and a saturated 9.2e16 on Android
        // for the same input (the denominator-domain fix). The default 7201 is unaffected.
        guard denominator > 1 else { return 0 }
        let value = maxStrain * log(trimp + 1.0) / log(denominator)
        return (value * 100).rounded() / 100
    }

    // MARK: - Denominator calibration

    /// Calibrate D from (TRIMP, reference_strain) pairs via the through-origin
    /// least-squares line: ln(D) = maxStrain × Σ(x²) / Σ(xy), x = ln(TRIMP+1).
    /// (reference_strain pairs must be on the same 0–maxStrain axis as the output.)
    /// Throws when fewer than 2 usable pairs (TRIMP>0, strain>0) or degenerate.
    public static func fitStrainDenominator(_ pairs: [(trimp: Double, strain: Double)]) throws -> Double {
        let usable = pairs.filter { $0.trimp > 0 && $0.strain > 0 }
        guard usable.count >= 2 else { throw StrainError.tooFewPairs }
        var sumXX = 0.0, sumXY = 0.0
        for (trimp, strain) in usable {
            let x = log(trimp + 1.0)
            sumXX += x * x
            sumXY += x * strain
        }
        guard sumXY > 0 && sumXX > 0 else { throw StrainError.degenerate }
        return exp(maxStrain * sumXX / sumXY)
    }

    public enum StrainError: Error, Equatable, Sendable {
        case tooFewPairs
        case degenerate
    }

    // MARK: - Public API

    /// Cardiovascular strain / "Effort" (0–100) from an HR series. APPROXIMATE.
    ///
    /// Returns nil when there isn't yet enough data to trust the number — fewer than
    /// `minReadings` samples AND less than `minSpanSeconds` of HR coverage (the sparse-strap
    /// path, #482) — or when maxHR ≤ restingHR (invalid HRR).
    ///
    /// - Parameters:
    ///   - hr: time-ordered `[HRSample]`.
    ///   - maxHR: HRmax (bpm). Defaults to 220 − defaultAge when nil.
    ///   - restingHR: resting HR (bpm) for the HRR denominator (default 60).
    ///   - method: `.edwards` (default) or `.banister`.
    ///   - sex: "male"/"female" — selects the Banister coefficient (ignored by Edwards).
    ///   - denominator: log-map D. `nil` (the default) resolves to the denominator that BELONGS to
    ///     `method` — Edwards' 7201, or Banister's sex-dependent ceiling. Pass a value only to override.
    public static func strain(_ hr: [HRSample],
                              maxHR: Double? = nil,
                              restingHR: Double = defaultRestingHR,
                              lowIntensity: LowIntensity = .countedIn([]),
                              // Load added before the curve by rated strength sessions (`strengthLoad`).
                              strengthLoad: Double = 0,
                              // Optional diagnostic sink. Nil by default and the line is built ONLY when
                              // one is supplied, so a pass nobody is watching pays nothing.
                              //
                              // Supplying one BYPASSES the memo — see the guard below. Without that the
                              // line would usually never appear, because the Today view has already cached
                              // the day at live-HR tick rate before the scoring pass asks.
                              diag: ((String) -> Void)? = nil,
                              day: String = "") -> Double? {
        // v7.0.2 perf (#707): TRIMP integrates over the day's HR stream; called once per day in the post-sync
        // scoring loop AND from the Today view (which re-reads on each live-HR tick). Memoize on the HR
        // fingerprint + every scalar that steers the score, so an identical re-request is a lookup. The
        // result is a single `Double?`; the HR array is not retained.
        let key = StrainKey(
            hr: StreamFingerprint.of(hr, ts: { $0.ts }, quant: { Int($0.bpm) }),
            maxHR: maxHR, restingHR: restingHR, lowIntensity: lowIntensity, strengthLoad: strengthLoad)
        // A diagnostic request BYPASSES the memo, and must. The Today view re-reads this on every
        // live-HR tick with no sink, so by the time the scoring pass asks with one the answer is already
        // cached — and a cache hit never reaches the code that emits, so the line would simply never
        // appear. Recomputing one day per pass to be able to report it is the trade, and it is a cheap
        // one. Kotlin has no memo here and always emits; this keeps the two behaving the same.
        guard diag == nil else {
            return strainUncached(hr, maxHR: maxHR, restingHR: restingHR, lowIntensity: lowIntensity,
                                  strengthLoad: strengthLoad, diag: diag, day: day)
        }
        return strainCache.value(key) {
            strainUncached(hr, maxHR: maxHR, restingHR: restingHR, lowIntensity: lowIntensity,
                           strengthLoad: strengthLoad, diag: nil, day: day)
        }
    }

    // MARK: - Training Load cardio lane (Banister)

    /// Banister's exponent when the profile names neither male nor female: the mean of the two published
    /// values (1.92 and 1.67), NOOP's own choice rather than a published one.
    public static let banisterBNeutral: Double = 1.795
    /// The multiplier paired with `banisterBNeutral`: the mean of the published 0.64 and 0.86. A fork
    /// decision like the exponent (2026-10-30), so a profile without a sex sits between the two published
    /// pairs in both halves instead of taking the men's multiplier.
    public static let banisterScaleNeutral: Double = 0.75

    /// The pair for the cardio lane: the men's for "male", the women's for "female", the neutral pair
    /// for anything else (an unset or nonbinary profile).
    public static func banisterCoefficients(sex: String) -> BanisterCoefficients {
        switch sex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "male": return BanisterCoefficients(scale: banisterScale, b: banisterBMen)
        case "female": return BanisterCoefficients(scale: banisterScaleWomen, b: banisterBWomen)
        default: return BanisterCoefficients(scale: banisterScaleNeutral, b: banisterBNeutral)
        }
    }

    /// Banister TRIMP (1991) for the Training Load cardio lane: every reading contributes its minutes ×
    /// ΔHRR × scale × e^(b·ΔHRR) (`banisterCoefficients(sex:)`), ΔHRR = (HR − resting) / (HRmax − resting) clamped to [0, 1].
    ///
    /// Continuous where Edwards is a step function: one beat across a zone edge moved a whole weight
    /// step. No sedentary floor — a training session is priced whole, unlike the daily Effort scorer,
    /// which subtracts the cost of a waking day. The same reading guards as daily Effort, but a gap longer
    /// than two minutes contributes nothing rather than two minutes. `effort` is the result
    /// mapped onto Effort's Banister axis for this pair.
    public static func banisterTrainingLoad(_ hr: [HRSample], maxHR: Double, restingHR: Double,
                                            sex: String) -> CardioLoadResult? {
        let reserve = maxHR - restingHR
        guard maxHR > 0, restingHR > 0, reserve > 0 else { return nil }
        let ordered = hr.sorted { $0.ts < $1.ts }
        let span = max(0, (ordered.last?.ts ?? 0) - (ordered.first?.ts ?? 0))
        guard hasEnoughReadings(ordered, span: span) else { return nil }
        let trimp = banisterTRIMP(ordered, restingHR: restingHR, hrReserve: reserve,
                                  durations: laneDurations(ordered), banisterCoefficients(sex: sex))
        return CardioLoadResult(trimp: trimp, effort: banisterLaneEffort(trimp, sex: sex),
                                sampleCount: ordered.count, spanSeconds: span)
    }

    /// A lane TRIMP on Effort's 0–100 axis, against Banister's daily ceiling for the same pair.
    public static func banisterLaneEffort(_ trimp: Double, sex: String) -> Double {
        trimpToStrain(trimp, denominator: banisterDailyCeiling(banisterCoefficients(sex: sex)) + 1.0)
    }

    /// Banister's original form from a session's average heart rate: minutes × ΔHRR × scale × e^(b·ΔHRR).
    ///
    /// Only an estimate — an average hides the intervals the exponential weights most, so it reads low
    /// for uneven sessions. The Training Load history uses it for old workouts that kept no trace, marked
    /// as estimated; no band or comparison ever reads it. Nil when the inputs cannot price a session.
    public static func banisterAverageTRIMP(minutes: Double, averageHR: Double, maxHR: Double,
                                            restingHR: Double, sex: String) -> Double? {
        let reserve = maxHR - restingHR
        guard minutes > 0, averageHR > 0, restingHR > 0, reserve > 0 else { return nil }
        let x = pctHRR(averageHR, restingHR: restingHR, hrReserve: reserve) / 100.0
        let c = banisterCoefficients(sex: sex)
        return minutes * x * c.scale * exp(c.b * x)
    }

    /// The reading guard both lane recipes share: a dense stream, or a sparse one spanning ten minutes.
    static func hasEnoughReadings(_ ordered: [HRSample], span: Int) -> Bool {
        ordered.count >= minReadings || (ordered.count >= minSparseReadings && span >= minSpanSeconds)
    }

    /// Per-reading minutes for the lane recipes: each reading covers the gap to the next, a gap longer
    /// than `maxSampleGapMin` covers nothing, and the last reading reuses the last covered gap.
    static func laneDurations(_ ordered: [HRSample]) -> [Double] {
        var durations = [Double](repeating: fallbackSampleMin, count: ordered.count)
        if ordered.count > 1 {
            for index in 0..<(ordered.count - 1) {
                let gap = ordered[index + 1].ts - ordered[index].ts
                durations[index] = gap > 0 && Double(gap) <= maxSampleGapMin * 60
                    ? Double(gap) / 60 : 0
            }
            durations[ordered.count - 1] = durations.dropLast().last(where: { $0 > 0 }) ?? fallbackSampleMin
        }
        return durations
    }

    /// One line naming WHERE the day's HRmax came from, and what the day's own heart rate actually
    /// reached — the pair of numbers #2438's step 0 turns on.
    ///
    /// The `effort score` line beside this one already reports the HRmax it used, but it can only say
    /// `provided` or `default`, and `provided` is two different answers at once: a manual override, and
    /// the Tanaka age formula. Those are the two the step-0 proposal treats differently ("a manual
    /// override always wins"), so a contributed log cannot currently be read for it. This line splits
    /// them, and carries the day's observed peak next to the formula value so the gap between the
    /// yardstick a day was scored against and the one the day's own heart rate suggests is a
    /// subtraction rather than an inference.
    ///
    /// `peak` is the day's RAW maximum, not a percentile. That is deliberate: the rule under discussion
    /// counts days whose peak passed a threshold ("reached on at least two different days in the last
    /// 90"), so the per-day maximum is the quantity that rule is written in, and a reader can evaluate
    /// the rule from a run of these lines before anything is built. A single artefact spike is visible
    /// as the one day that disagrees with its neighbours, which is the same thing the two-day
    /// requirement exists to absorb.
    ///
    /// Changes no score. `hrmaxSource` is the branch the CALLER took, because the branch is only visible
    /// there — `strain` receives an HRmax with its provenance already discarded.
    ///
    /// `formula` is the age formula the fork starts from (Gellish, `MaxHeartRate.gellish`); `src` is
    /// `override`, `measured`, `gellish` or `default` (#2438 step 0). The fork's line therefore differs
    /// from the Kotlin twin, which still prints `tanaka=`.
    ///
    /// No PII: a day key and four bpm values.
    public static func dayCalibrationLine(day: String, hrmax: Double?, hrmaxSource: String,
                                          formula: Double?, observedPeak: Double?,
                                          restingHR: Double) -> String {
        // The formatters live on WorkoutDetector, where `effort bout` needed them first. Sharing them
        // rather than copying is what keeps a day line and a bout line in the same log rounding the same
        // way; a second copy would be free to drift, and these two lines are read side by side.
        var out = "effort calib day=\(day) hrmax=\(WorkoutDetector.round0(hrmax))"
        out += " src=\(hrmaxSource) formula=\(WorkoutDetector.round0(formula))"
        out += " peak=\(WorkoutDetector.round0(observedPeak)) rhr=\(WorkoutDetector.round0(restingHR))"
        return out
    }

    /// The ` sustained=` field appended to `dayCalibrationLine`: the same day's peak held across
    /// consecutive samples (`sustainedPeak`), so a run of lines shows how much of each day's `peak` was a
    /// single sample. Its own function, appended by the caller, so the calibration line's existing
    /// contract stays as it is. Same formatter as the fields before it; nil renders as `nil`, not 0.
    ///
    /// Byte-identical to the Kotlin twin `sustainedPeakField`.
    public static func sustainedPeakField(_ sustainedPeak: Double?) -> String {
        " sustained=\(WorkoutDetector.round0(sustainedPeak))"
    }

    /// Consecutive samples a `sustained` peak must hold for, and the span they must fit in.
    public static let sustainedPeakSamples = 5
    public static let sustainedPeakWindowS = 60

    /// The highest bpm that `sustainedPeakSamples` consecutive samples all reached within
    /// `sustainedPeakWindowS` seconds, or nil when no run of samples is that dense.
    ///
    /// The `sustained` field beside the raw `peak` on the `effort calib` line (#2438). On ring days the raw
    /// daily maximum is nearly always one isolated sample: over 60 days of Oura heart rate it sat above the
    /// age formula on 58 days, and this value on none, while 98 % of the samples at or above 165 bpm lay in
    /// a ±30 s window whose median was under 120. A step-0 rule read off the raw peak would raise a ring
    /// wearer's HRmax from artefacts, so contributed logs carry both, and the rule can be written against
    /// whichever one holds up on straps.
    ///
    /// The minimum over each run, not its mean: one spike inside five ordinary samples must not lift the
    /// value, which is the whole point of the field. nil rather than a fallback to the raw peak, so a sparse
    /// day reads as "not measured" and not as "held".
    ///
    /// Byte-identical to the Kotlin twin `sustainedPeak`.
    public static func sustainedPeak(_ hr: [HRSample],
                                     samples: Int = sustainedPeakSamples,
                                     windowS: Int = sustainedPeakWindowS) -> Double? {
        guard samples > 0, hr.count >= samples else { return nil }
        // Ordered by (ts, bpm), not ts alone: Swift's sort is not stable and Kotlin's is, so two samples
        // sharing a second could otherwise form different runs on the two platforms.
        let sorted = hr.sorted { ($0.ts, $0.bpm) < ($1.ts, $1.bpm) }
        var best: Int?
        for i in 0 ... (sorted.count - samples) {
            let last = i + samples - 1
            guard sorted[last].ts - sorted[i].ts <= windowS else { continue }
            let held = sorted[i ... last].lazy.map { $0.bpm }.min() ?? sorted[i].bpm
            best = max(best ?? held, held)
        }
        return best.map(Double.init)
    }

    /// The ` span=` field appended after `sustained=`: how many seconds the run behind that value covered
    /// (`sustainedPeakSpan`). Its own function, appended by the caller, like `sustainedPeakField`. nil
    /// renders as `nil`, not 0.
    ///
    /// Byte-identical to the Kotlin twin `sustainedPeakSpanField`.
    public static func sustainedPeakSpanField(_ spanS: Int?) -> String {
        " span=\(spanS.map(String.init) ?? "nil")"
    }

    /// The seconds covered by the run that sets `sustainedPeak`, or nil when that is nil.
    ///
    /// `sustainedPeak` bounds a run's span from above only, so the same value can stand for five samples
    /// inside four seconds of dense heart rate or across a whole minute of sparse heart rate. On one ring
    /// with all-day heart rate the winning run covered 4 s on some days and 57 s on others. This field
    /// carries the span beside the value, so a contributed log says which kind of hold it was.
    ///
    /// When several runs reach the same value, the longest span among them: the strongest evidence that
    /// the value was held. Same rule and same ordering as `sustainedPeak`, so the two fields always
    /// describe the same run.
    ///
    /// Byte-identical to the Kotlin twin `sustainedPeakSpan`.
    public static func sustainedPeakSpan(_ hr: [HRSample],
                                         samples: Int = sustainedPeakSamples,
                                         windowS: Int = sustainedPeakWindowS) -> Int? {
        guard samples > 0, hr.count >= samples else { return nil }
        let sorted = hr.sorted { ($0.ts, $0.bpm) < ($1.ts, $1.bpm) }
        var best: (held: Int, span: Int)?
        for i in 0 ... (sorted.count - samples) {
            let last = i + samples - 1
            let span = sorted[last].ts - sorted[i].ts
            guard span <= windowS else { continue }
            let held = sorted[i ... last].lazy.map { $0.bpm }.min() ?? sorted[i].bpm
            if let b = best, (b.held, b.span) >= (held, span) { continue }
            best = (held, span)
        }
        return best?.span
    }

    /// One line naming what an Effort score was computed FROM, or why it could not be computed.
    ///
    /// The gap this closes: `strain` is the only score in the app with no trace at all. WorkoutDetector,
    /// SleepStager and both engines each emit a funnel; the number on the Today hero ring emitted nothing,
    /// so a log could not distinguish "measured, and the day was genuinely calm" from "could not measure".
    /// A reader looking for the latter finds `workout detect`, which is WORKOUT-BOUT detection and answers
    /// a different question — a confusion that has already produced one wrong diagnosis.
    ///
    /// `enough` is the `strain` gate spelled out: dense (>= minReadings) OR sparse-but-sustained. `trimp`
    /// and `strain` are absent when the gate refused, which is exactly the case a bare 0 hides.
    /// Kotlin twin: `StrainScorer.scoreFunnelLine`. Phrased with the word "twin" deliberately:
    /// the scanner's claim patterns require it, so the previous "Byte-identical to the Kotlin ..."
    /// read as a twin claim to a human and was invisible to the ledger, which is why adding an
    /// argument here orphaned both identities instead of re-forming the pair at the new arity.
    public static func scoreFunnelLine(day: String, hrSamples: Int, enough: Bool,
                                       maxHR: Double, maxHRProvided: Bool, restingHR: Double,
                                       trimp: Double?, strain: Double?,
                                       zoneMinutes: [Double]? = nil) -> String {
        func r1(_ v: Double) -> String { String(format: "%.1f", v) }
        // Built by appending rather than as one `+` chain. A chain of interpolated segments is a single
        // expression, and this one blew the type-checker's budget on the first attempt — the same failure
        // that took the iOS build down in #1767. Statements give the solver one small problem at a time.
        let src: String = maxHRProvided ? "provided" : "default"
        let trimpText: String = trimp.map(r1) ?? "n/a"
        let strainText: String = strain.map(r1) ?? "n/a"
        var out = "effort score day=\(day) hr=\(hrSamples) enough=\(enough)"
        out += " hrMax=\(r1(maxHR))(\(src))"
        out += " rhr=\(r1(restingHR)) reserve=\(r1(maxHR - restingHR))"
        // One method since #2438 step 1; the field keeps its position for the parsers. `trimp=` carries
        // the curve's load.
        out += " method=curve2438"
        out += " trimp=\(trimpText) strain=\(strainText)"
        // Per-zone minutes, appended last so every field before this one keeps its position and the
        // existing parsers are unaffected. Absent rather than zeroed when the reserve is invalid: a
        // refused day has no zones, and six zeros would read as a day spent entirely below zone 1.
        // Built with a statement loop for the same type-checker reason as the fields above.
        if let zones = zoneMinutes, zones.count == 6 {
            for i in 0..<6 { out += " z\(i)=\(r1(zones[i]))" }
        } else {
            out += " zones=n/a"
        }
        return out
    }

    /// Key folds `sex` to the single bit the recipe reads (`hasPrefix("f")`) so "female"/"f"/"F" all hit.
    private struct StrainKey: Hashable {
        let hr: StreamFingerprint
        let maxHR: Double?; let restingHR: Double; let lowIntensity: LowIntensity; let strengthLoad: Double
    }
    private static let strainCache = AnalyticsMemoCache<StrainKey, Double?>(capacity: 48)

    private static func strainUncached(_ hr: [HRSample], maxHR: Double?, restingHR: Double,
                                       lowIntensity: LowIntensity, strengthLoad: Double = 0,
                                       diag: ((String) -> Void)? = nil, day: String = "") -> Double? {
        let effMax = maxHR ?? Double(defaultMaxHR())
        // Enough data to trust the score: a dense stream (≥ minReadings) OR a sparse-but-sustained
        // one spanning ≥ minSpanSeconds with a sample floor (#482 — the 5/MG's ~30 s HR cadence).
        let enoughData: Bool
        if hr.count >= minReadings {
            enoughData = true
        } else if hr.count >= minSparseReadings {
            let tss = hr.map { $0.ts }
            enoughData = ((tss.max() ?? 0) - (tss.min() ?? 0)) >= minSpanSeconds
        } else {
            enoughData = false
        }
        if !enoughData || effMax <= restingHR {
            // The refusal is the half a bare number cannot show: nil here and 0.0 on a calm day look
            // identical on the ring, and only one of them is a measurement.
            diag?(scoreFunnelLine(day: day, hrSamples: hr.count, enough: enoughData, maxHR: effMax,
                                  maxHRProvided: maxHR != nil, restingHR: restingHR,
                                  trimp: nil, strain: nil))
            return nil
        }

        let durations = sampleDurationsMinutes(hr)
        let hrReserve = effMax - restingHR

        let load = effortLoad(hr, restingHR: restingHR, hrReserve: hrReserve, durations: durations,
                              lowIntensity: lowIntensity)
        let scored = effortValue(load: load + max(0, strengthLoad))
        // Walked only when a sink is attached. It is a second O(n) pass over the day's samples, and
        // `analyzeRecent`'s prep is already the expensive half of a scoring run, so a normal pass must
        // not pay for a diagnostic nobody is reading. `hrReserve` is safe here: the refusal path above
        // already returned for `effMax <= restingHR`.
        // The zones describe what the day WAS, not how it was scored: #2438 fits on zone minutes.
        let zones: [Double]? = diag == nil ? nil
            : zoneMinutes(hr, restingHR: restingHR, hrReserve: hrReserve, durations: durations)
        diag?(scoreFunnelLine(day: day, hrSamples: hr.count, enough: enoughData, maxHR: effMax,
                              maxHRProvided: maxHR != nil, restingHR: restingHR,
                              trimp: load, strain: scored, zoneMinutes: zones))
        return scored
    }
}
