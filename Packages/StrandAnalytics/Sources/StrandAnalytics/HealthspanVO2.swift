import Foundation
import WhoopProtocol

// HealthspanVO2.swift — fork feature "AgeLess" (backlog plan HEALTHSPAN_AGE_PLAN, decisions of 2026-10-12): which
// VO₂max a week's age and pace use, and the lean mass behind it.
//
// Only measurements count (decisions of 2026-10-14, AI-26). NOOP's weekly non-exercise estimate (Nes 2011 / Uth
// 2004, `vo2max_est`) predicts fitness from risk factors AgeLess already counts. NOOP's estimate from walks and runs
// (`ExerciseVO2max`) failed a lab check: against 981 treadmill tests with measured VO₂max it read about 21 at walking
// pace whatever the measured value was (r 0.23), since the %HRR extrapolation from a walk is capped by its own
// reserve gate; and any pulse raised by medication, a meal or heat reads as effort. It stays a Training Load readout.
// The sources, in this order:
//   1. a value the wearer entered (a lab test), for a year from the day it was measured;
//   2. Apple Watch's Cardio Fitness readings from Apple Health, over the six-month window.
// Without either a week has no VO₂max and the screens say how to get one. The age takes the six-month median; the
// pace takes the median of the last 30 days when there are at least two readings there, else the six-month value.
//
// Long walks still say something without a pulse: hours at a pace are only sustainable at a share of VO₂max
// (`enduranceFloor`). That lower bound is shown beside the measure as a plausibility check, never used as its value.

public enum HealthspanVO2 {

    public enum Source: Int, Equatable, Sendable, CaseIterable {
        case manual = 1, appleHealth = 2, training = 3
    }

    public struct Resolved: Equatable, Sendable {
        /// The VO₂max behind the week's age: the six-month median, or the entered value.
        public let window: Double
        /// The VO₂max behind the week's pace.
        public let recent: Double
        public let source: Source
        /// Readings behind `window` (1 for an entered value).
        public let readings: Int
        /// The day of the newest reading behind `window`, or the day an entered value was measured.
        public let latestDay: String
    }

    /// An entered value counts for a year from the day it was measured.
    public static let manualValidDays = 365
    /// Readings the last 30 days need before they, rather than the six-month value, drive the pace.
    public static let minimumRecentReadings = 2

    public static func resolve(manual: (day: String, value: Double)?,
                               appleHealth: [(day: String, value: Double)],
                               endingOn end: String) -> Resolved? {
        if let entry = validManual(manual, on: end) {
            return Resolved(window: entry.value, recent: entry.value, source: .manual, readings: 1,
                            latestDay: entry.day)
        }
        let windowStart = HealthspanWindow.dayKey(end, plus: -(HealthspanWindow.ageWindowDays - 1))
        let inWindow = appleHealth.filter { $0.value > 0 && $0.day >= windowStart && $0.day <= end }
        guard let windowMedian = median(inWindow.map(\.value)), let latest = inWindow.map(\.day).max() else { return nil }
        let recentStart = HealthspanWindow.dayKey(end, plus: -(HealthspanWindow.paceWindowDays - 1))
        let recent = inWindow.filter { $0.day >= recentStart }.map(\.value)
        let recentMedian = recent.count >= minimumRecentReadings ? median(recent) ?? windowMedian : windowMedian
        return Resolved(window: windowMedian, recent: recentMedian, source: .appleHealth, readings: inWindow.count,
                        latestDay: latest)
    }

    /// The readings a VO₂max goal follows on `today`: the entered value while it counts, else every Apple Health
    /// reading up to today. Oldest first.
    public static func goalReadings(manual: (day: String, value: Double)?,
                                    appleHealth: [(day: String, value: Double)],
                                    today: String) -> [(day: String, value: Double)] {
        if let entry = validManual(manual, on: today) { return [entry] }
        return appleHealth.filter { $0.value > 0 && $0.day <= today }.sorted { $0.day < $1.day }
    }

    /// An entered value that still counts on `end`: measured on or before it, within the past year.
    static func validManual(_ manual: (day: String, value: Double)?, on end: String) -> (day: String, value: Double)? {
        guard let manual, manual.value > 0, manual.day <= end,
              manual.day >= HealthspanWindow.dayKey(end, plus: -(manualValidDays - 1)) else { return nil }
        return manual
    }

    // MARK: - Endurance floor

    /// A walk long enough to say something about VO₂max without a pulse.
    public struct LongSession: Equatable, Sendable {
        public let day: String
        /// The session's oxygen cost, ml/kg/min (ACSM, with the measured climb when there is one).
        public let oxygenCost: Double
        public init(day: String, oxygenCost: Double) { self.day = day; self.oxygenCost = oxygenCost }
    }

    /// Sessions at least this long count: over an hour or more the share of VO₂max a person sustains is bounded.
    public static let floorMinimumMinutes = 60.0
    /// ASSUMPTION: the share of VO₂max an untrained adult sustains over one to several hours, the upper end of the
    /// 50–60 % range in endurance physiology. The bound holds only for a session at or below this share; someone who
    /// sustains more would read high. Walks only: at walking pace the cost is low, so a fit walker sits far below
    /// 60 % and the bound is merely weak, while a run of an hour can reach 75–85 % of a trained runner's VO₂max and
    /// would overstate it.
    public static let sustainableShare = 0.6
    /// Long sessions in the window before a bound is stated.
    public static let floorMinimumSessions = 3

    /// The oxygen cost of a walk if it qualifies for the floor: at least `floorMinimumMinutes`, at a walking speed
    /// the ACSM equation covers, with the measured climb when known. Runs never qualify (see `sustainableShare`).
    /// Stops in the session lower the average speed and so the cost, which keeps the bound conservative.
    public static func longSessionCost(distanceM: Double, durationS: Double, ascentM: Double?) -> Double? {
        let minutes = durationS / 60
        guard minutes >= floorMinimumMinutes, distanceM > 0 else { return nil }
        let speed = distanceM / minutes
        guard let gait = ExerciseVO2max.gait(speedMPerMin: speed), gait == .walking else { return nil }
        let climb = ascentM.map { ExerciseVO2max.climbVO2(ascentM: $0, minutes: minutes, gait: gait) } ?? 0
        return ExerciseVO2max.acsmVO2(speedMPerMin: speed, gait: gait) + climb
    }

    /// The least VO₂max the long sessions of the six months ending on `end` allow: the median over those sessions of
    /// cost ÷ `sustainableShare`. Nil with fewer than `floorMinimumSessions`.
    public static func enduranceFloor(_ sessions: [LongSession], endingOn end: String) -> Double? {
        let start = HealthspanWindow.dayKey(end, plus: -(HealthspanWindow.ageWindowDays - 1))
        let floors = sessions.filter { $0.day >= start && $0.day <= end && $0.oxygenCost > 0 }
            .map { $0.oxygenCost / sustainableShare }
        guard floors.count >= floorMinimumSessions else { return nil }
        return median(floors)
    }

    /// Lean mass as a share of body mass from the latest body-fat reading of the past year, on or before `end`.
    public static func leanMassPct(bodyFat: [(day: String, value: Double)], endingOn end: String) -> Double? {
        latestBodyFat(bodyFat, endingOn: end).map { 100 - $0.value }
    }

    /// The body-fat reading lean mass is taken from: the latest plausible one of the past year, on or before `end`.
    public static func latestBodyFat(_ bodyFat: [(day: String, value: Double)],
                                     endingOn end: String) -> (day: String, value: Double)? {
        let start = HealthspanWindow.dayKey(end, plus: -(manualValidDays - 1))
        return bodyFat.filter { $0.day >= start && $0.day <= end && $0.value > 0 && $0.value < 100 }
            .max { $0.day < $1.day }
    }

    /// A session's measured average heart rate from the band's trace, weighted by each sample's (gap-capped)
    /// duration; nil when the trace covers less than `minimumCoverage` of the session, so a session the band
    /// mostly missed is not priced on a fragment.
    public static func bandAverageHR(_ hr: [HRSample], sessionSeconds: Double,
                                     minimumCoverage: Double = 0.8) -> Double? {
        guard sessionSeconds > 0, !hr.isEmpty else { return nil }
        let minutes = StrainScorer.sampleDurationsMinutes(hr)
        let covered = minutes.reduce(0, +)
        guard covered * 60 >= minimumCoverage * sessionSeconds, covered > 0 else { return nil }
        return zip(hr, minutes).reduce(0) { $0 + Double($1.0.bpm) * $1.1 } / covered
    }

    public static func median(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted(), m = s.count / 2
        return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
    }
}
