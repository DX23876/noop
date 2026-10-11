import Foundation
import WhoopProtocol

// HealthspanEngine.swift — a healthspan "effective age" built from the method WHOOP published for WHOOP Age
// ("The WHOOP Healthspan Feature", white paper revised 2025-09-04), implemented independently from that
// paper and the studies it cites. Not a clinical or biological age and not a life expectancy.
//
// Method (effective age, Spiegelhalter 2016, BMC Med Inform Decis Mak 16:104): every component maps its
// value to an all-cause-mortality hazard ratio relative to a HEALTH-OPTIMISED referent (the published
// recommendation, not the population mean). With roughly 10 % more risk per year of age,
//     years_i = 10 · (ln HR_i(value) − ln HR_i(target))
// and the age is chronological age + k · Σ years_i. Meeting every recommendation reads exactly at your age.
//
// Curves are piecewise linear in ln(HR) between published anchor points and hold their end value outside
// the studied range (no extrapolation). A missing component contributes 0, as the paper specifies for lean
// mass; `Result.isComplete` says whether everything but lean mass was present, and only a complete result
// should be shown. `overlapFactor` k stands in for the paper's unpublished structural-equation correction
// of correlated components. It is one global scale, not a per-component correction, so it also absorbs
// any systematic error in the curves; it is the one free parameter, set by least squares on the paper's
// four Table 2 profiles. Those are effectively two profiles (US average, WHOOP median) in two sexes, so the
// anchor test is a regression guard, not an independent validation. Assumptions that are not taken from a
// study are marked ASSUMPTION below.
public enum HealthspanEngine {

    /// Shrinks the summed component years for overlap between correlated inputs (RHR and VO₂max, steps and
    /// zone time). Least-squares fit to whitepaper Table 2: 0.644, all four profiles within ±0.33 y. Varying
    /// the values this fit had to assume for the US profiles (sleep 6.1–6.6 h, consistency 60–70, zone 4–5
    /// 0–5 min) moves it between about 0.60 and 0.73.
    public static let overlapFactor = 0.64
    /// ln(HR) per year of age in the paper's conversion (≈ 10 % per year).
    static let lnHazardPerYear = 0.1
    /// ASSUMPTION: the paper gives "younger" and "older" adult targets for steps and zone time and says they
    /// "decrease slightly as members age", without ages. Paluch 2022 splits its strata at 60, so the targets
    /// move linearly from the younger to the older value between 50 and 70 rather than jumping on a birthday.
    static let targetTaperAges = (start: 50.0, end: 70.0)

    public enum Sex: String, Sendable { case male, female }

    /// Display order follows the paper: sleep, then activity, then fitness. New components (e.g. CosinorAge)
    /// slot in as a new case plus a curve in `rawYears`.
    public enum Component: String, CaseIterable, Sendable {
        case sleepDuration, sleepConsistency, dailySteps, zone13, zone45, strength, vo2max, restingHR, leanMass
    }

    public struct Inputs: Equatable, Sendable {
        public var age: Double
        public var sex: Sex
        public var sleepHours: Double?           // mean hours of sleep per night
        public var sleepConsistencyPct: Double?  // 0–100, WHOOP definition (state match over 4 days)
        public var dailySteps: Double?           // mean steps per day
        public var zone13MinPerWeek: Double?     // minutes in logged activities at 40–80 % HR reserve
        public var zone45MinPerWeek: Double?     // minutes in logged activities at 80–100 % HR reserve
        public var strengthMinPerWeek: Double?   // minutes of strength-type activities
        public var vo2max: Double?               // ml/kg/min
        public var restingHR: Double?            // bpm, on WHOOP's in-sleep resting-HR scale
        public var leanMassPct: Double?          // % of body mass; nil = no effect
        public init(age: Double, sex: Sex, sleepHours: Double? = nil, sleepConsistencyPct: Double? = nil,
                    dailySteps: Double? = nil, zone13MinPerWeek: Double? = nil, zone45MinPerWeek: Double? = nil,
                    strengthMinPerWeek: Double? = nil, vo2max: Double? = nil, restingHR: Double? = nil,
                    leanMassPct: Double? = nil) {
            self.age = age; self.sex = sex; self.sleepHours = sleepHours
            self.sleepConsistencyPct = sleepConsistencyPct; self.dailySteps = dailySteps
            self.zone13MinPerWeek = zone13MinPerWeek; self.zone45MinPerWeek = zone45MinPerWeek
            self.strengthMinPerWeek = strengthMinPerWeek; self.vo2max = vo2max
            self.restingHR = restingHR; self.leanMassPct = leanMassPct
        }

        public func value(_ c: Component) -> Double? {
            switch c {
            case .sleepDuration: return sleepHours
            case .sleepConsistency: return sleepConsistencyPct
            case .dailySteps: return dailySteps
            case .zone13: return zone13MinPerWeek
            case .zone45: return zone45MinPerWeek
            case .strength: return strengthMinPerWeek
            case .vo2max: return vo2max
            case .restingHR: return restingHR
            case .leanMass: return leanMassPct
            }
        }
    }

    /// One component's share: its value (nil = missing), the target it is judged against, and the years it
    /// adds (positive) or removes (negative) after the overlap factor.
    public struct Contribution: Equatable, Sendable {
        public let component: Component
        public let value: Double?
        public let target: Double
        public let years: Double
    }

    public struct Result: Equatable, Sendable {
        public let healthspanAge: Double
        public let chronologicalAge: Double
        /// healthspanAge − chronologicalAge: positive = older than your age, negative = younger.
        public let deltaYears: Double
        public let contributions: [Contribution]
        public let componentsUsed: Int
        /// Every component except the optional lean mass was present. The paper computes nothing without
        /// them, and a missing component reads as "on target", which would flatter the age.
        public var isComplete: Bool {
            contributions.allSatisfy { $0.value != nil || $0.component == .leanMass }
        }
    }

    // MARK: - Targets

    /// Whitepaper Figure 4: minimum VO₂max for independent living at older ages, by age and sex (ml/kg/min).
    static let vo2maxTable: [Double] = [20, 25, 30, 35, 40, 45, 50, 55, 60, 65, 70, 75, 80, 85, 90, 95, 100]
    static let vo2maxFemale: [Double] = [40, 40, 38, 36, 34, 32, 30, 29, 27, 26, 25, 23, 22, 21, 20, 19, 18]
    static let vo2maxMale: [Double] = [46, 46, 44, 42, 40, 37, 36, 34, 32, 30, 29, 27, 26, 25, 23, 22, 21]

    public static func vo2maxTarget(age: Double, sex: Sex) -> Double {
        linear(age, xs: vo2maxTable, ys: sex == .male ? vo2maxMale : vo2maxFemale)
    }

    /// The health-optimised referent value of each component (whitepaper Table 1).
    public static func target(_ c: Component, age: Double, sex: Sex) -> Double {
        let older = clamp((age - targetTaperAges.start) / (targetTaperAges.end - targetTaperAges.start), 0, 1)
        func taper(_ younger: Double, _ olderValue: Double) -> Double { younger + older * (olderValue - younger) }
        switch c {
        case .sleepDuration: return 7
        case .sleepConsistency: return 70
        case .dailySteps: return taper(8000, 5600)
        case .zone13: return taper(100, 70)
        case .zone45: return taper(10, 7)
        case .strength: return 40
        case .vo2max: return vo2maxTarget(age: age, sex: sex)
        case .restingHR: return sex == .male ? 60 : 64
        // ASSUMPTION: the paper gives only the 30-year-old values and says the target "changes with age";
        // held constant until an age curve is sourced.
        case .leanMass: return sex == .male ? 80 : 67
        }
    }

    // MARK: - Hazard curves (value → hazard ratio anchors)

    /// Saint-Maurice 2024, Sleep 47(3), UK Biobank actigraphy: 5 h HR 1.29 vs 7 h, under 6 h 16–44 % higher.
    /// ASSUMPTION: 8 h 0.97 encodes the paper's "minor reduction" for 7–9 h; above 9 h is handled as no effect.
    static let sleepCurve: [(Double, Double)] = [(4, 1.44), (5, 1.29), (7, 1.0), (8, 0.97), (9, 1.0)]
    /// Windred 2024, Sleep 47(1), fully adjusted model: quintile median SRI → HR vs the least regular quintile.
    /// Below its bottom quintile median the curve continues with Cribb 2023 (eLife, UK Biobank): HR 1.53 at the
    /// 5th SRI percentile, 19 points under the median. That slope (ln 1.53 / 19 per point) matches Windred's
    /// slope between its lowest two quintiles (ln 0.80 / 10.5), so only the step size is borrowed; the two
    /// papers' absolute SRI values differ and are not mixed.
    static let consistencyCurve: [(Double, Double)] = [(46.1, 1.53), (65.1, 1.0), (75.6, 0.80), (81.0, 0.75),
                                                        (85.2, 0.72), (89.8, 0.70)]
    /// Paluch 2022, Lancet Public Health: quartile median steps/day → HR vs the lowest quartile.
    static let stepsCurve: [(Double, Double)] = [(3553, 1.0), (5801, 0.60), (7842, 0.55), (10901, 0.47)]
    /// Lee 2022, Circulation: 150–299 min/wk moderate ≈ 19 % lower; 2–4× the guideline 3–13 % lower again;
    /// no further benefit from 600 min/wk.
    static let zone13Curve: [(Double, Double)] = [(0, 1.0), (150, 0.81), (300, 0.81 * 0.92), (600, 0.81 * 0.90)]
    /// Ahmadi 2022, Eur Heart J: 2.2 min/wk reference, ~15 min/wk HR 0.82, nadir 53.6 min/wk HR 0.64.
    static let zone45Curve: [(Double, Double)] = [(2.2, 1.0), (15, 0.82), (53.6, 0.64)]
    /// Momma 2022, BJSM: maximum 10–20 % lower risk at 30–60 min/wk (J-shaped). The full 15 % is reached at
    /// 60 min so that time above the 40-min target still subtracts years, as the paper states; it stays flat
    /// to the paper's 2 h/wk cap and beyond.
    static let strengthCurve: [(Double, Double)] = [(0, 1.0), (60, 0.85), (120, 0.85)]
    /// Kodama 2009, JAMA: 13 % lower risk per MET (3.5 ml/kg/min), held to ±4 MET around the target.
    static let lnHRPerVO2 = log(0.87) / 3.5
    static let vo2maxSpan = 14.0
    /// Zhang 2016, CMAJ: HR 1.09 per +10 bpm, linear across the studied 45–90 bpm.
    static let lnHRPerBpm = log(1.09) / 10
    static let restingHRRange = 45.0...90.0
    /// Jayedi 2022, Int J Obes: HR 1.11 per +10 % body fat. The paper grants only "small reductions" below
    /// target; ASSUMPTION: capped at 3 points of body fat. ASSUMPTION: above 50 % body fat the linear
    /// meta-analytic slope is not extended further.
    static let lnHRPerBodyFatPct = log(1.11) / 10
    static let leanMassMaxCredit = 3.0
    static let bodyFatCeilingPct = 50.0

    /// Component years before the overlap factor.
    static func rawYears(_ c: Component, value v: Double, target t: Double) -> Double {
        switch c {
        case .sleepDuration:
            return v > 9 ? 0 : years(interpolatedLnHR(v, sleepCurve) - interpolatedLnHR(t, sleepCurve))
        case .sleepConsistency:
            return years(interpolatedLnHR(v, consistencyCurve) - interpolatedLnHR(t, consistencyCurve))
        case .dailySteps:
            return years(interpolatedLnHR(v, stepsCurve) - interpolatedLnHR(t, stepsCurve))
        case .zone13:
            return years(interpolatedLnHR(v, zone13Curve) - interpolatedLnHR(t, zone13Curve))
        case .zone45:
            return years(interpolatedLnHR(v, zone45Curve) - interpolatedLnHR(t, zone45Curve))
        case .strength:
            return years(interpolatedLnHR(v, strengthCurve) - interpolatedLnHR(t, strengthCurve))
        case .vo2max:
            return years(lnHRPerVO2 * clamp(v - t, -vo2maxSpan, vo2maxSpan))
        case .restingHR:
            let bpm = clamp(v, restingHRRange.lowerBound, restingHRRange.upperBound)
            return years(lnHRPerBpm * (bpm - t))
        case .leanMass:
            let excessFat = min(100 - v, bodyFatCeilingPct) - (100 - t)
            return years(lnHRPerBodyFatPct * max(excessFat, -leanMassMaxCredit))
        }
    }

    // MARK: - Age and pace

    /// The healthspan age for one window of inputs; nil without an age or without any component.
    public static func compute(_ inputs: Inputs) -> Result? {
        guard inputs.age > 0 else { return nil }
        var contributions: [Contribution] = []
        var used = 0
        for c in Component.allCases {
            let t = target(c, age: inputs.age, sex: inputs.sex)
            guard let v = inputs.value(c) else {
                contributions.append(Contribution(component: c, value: nil, target: t, years: 0)); continue
            }
            used += 1
            contributions.append(Contribution(component: c, value: v, target: t,
                                              years: overlapFactor * rawYears(c, value: v, target: t)))
        }
        guard used > 0 else { return nil }
        let delta = contributions.reduce(0) { $0 + $1.years }
        return Result(healthspanAge: inputs.age + delta, chronologicalAge: inputs.age, deltaYears: delta,
                      contributions: contributions, componentsUsed: used)
    }

    /// Pace of Aging: the healthspan age half a year from now if the last 30 days' averages held for the
    /// whole window, compared with today's. 1.0 = ageing with the calendar, below 0 = getting younger.
    /// Both are judged at today's age so the pace reflects behaviour, not targets moving with a birthday.
    public static func paceOfAging(window: Inputs, last30Days: Inputs) -> Double? {
        guard let now = compute(window) else { return nil }
        var recent = last30Days
        recent.age = window.age; recent.sex = window.sex
        guard let projected = compute(recent) else { return nil }
        let change = (projected.healthspanAge + 0.5) - now.healthspanAge
        return clamp(change / 0.5, -1, 3)
    }

    // MARK: - Zone time

    /// Lower edges of the paper's zone 1 and zone 4 as fractions of heart-rate reserve (zones 1–5 start at
    /// 40/60/70/80/90 %). Time below zone 1 does not count, as in WHOOP's own per-activity zone shares.
    static let zone1LowerPctHRR = 40.0
    static let zone4LowerPctHRR = 80.0

    /// Minutes at 40–80 % and at ≥ 80 % of heart-rate reserve in one activity's HR samples. Each reading is
    /// credited with the time to the next, capped exactly as strain caps it, so both describe the same time.
    /// Pass the same resting HR the healthspan age uses (the in-sleep mean). nil when the reserve is invalid.
    public static func zoneMinutes(hr: [HRSample], restingHR: Double,
                                   maxHR: Double) -> (zone13: Double, zone45: Double)? {
        let reserve = maxHR - restingHR
        guard reserve > 0 else { return nil }
        let durations = StrainScorer.sampleDurationsMinutes(hr)
        var zone13 = 0.0, zone45 = 0.0
        for (sample, minutes) in zip(hr, durations) {
            let pct = StrainScorer.pctHRR(Double(sample.bpm), restingHR: restingHR, hrReserve: reserve)
            if pct >= zone4LowerPctHRR { zone45 += minutes } else if pct >= zone1LowerPctHRR { zone13 += minutes }
        }
        return (zone13, zone45)
    }

    /// Weekly rate from a window's total minutes.
    public static func perWeek(totalMinutes: Double, days: Double) -> Double? {
        days > 0 ? totalMinutes / days * 7 : nil
    }

    // MARK: - Helpers

    static func years(_ lnHR: Double) -> Double { lnHR / lnHazardPerYear }

    /// ln(HR) interpolated linearly between anchors, held at the end values outside them.
    static func interpolatedLnHR(_ x: Double, _ anchors: [(Double, Double)]) -> Double {
        linear(x, xs: anchors.map(\.0), ys: anchors.map { log($0.1) })
    }

    static func linear(_ x: Double, xs: [Double], ys: [Double]) -> Double {
        guard let first = xs.first, let last = xs.last else { return 0 }
        if x <= first { return ys[0] }
        if x >= last { return ys[ys.count - 1] }
        for i in 1..<xs.count where x <= xs[i] {
            let f = (x - xs[i - 1]) / (xs[i] - xs[i - 1])
            return ys[i - 1] + f * (ys[i] - ys[i - 1])
        }
        return ys[ys.count - 1]
    }

    static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, v)) }
}
