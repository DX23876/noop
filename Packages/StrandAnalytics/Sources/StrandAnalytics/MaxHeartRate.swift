// MaxHeartRate.swift — the wearer's maximum heart rate, decided in one place (#2438 step 0).
//
// Effort, workout scores, heart-rate zones, workout energy, the healthspan age and the coach all need
// the same number. It used to be written out by hand at every caller ("manual setting, else Tanaka from
// age"), in Double and Int forms that rounded differently, and two such copies had already dropped the
// manual setting (#2460). `Tools/test_max_heart_rate_resolver.py` fails when a caller resolves it by
// itself again.
//
// The rule, in order:
//   1. A manual setting wins, as entered.
//   2. Otherwise the measured level, when it lies above the age formula: the highest heart rate held for
//      five consecutive samples (`StrainScorer.sustainedPeak`) in a workout on at least two different days
//      of the 90 before the day. A day's peak more than 25 bpm above the formula is treated as an artefact.
//      After a quiet stretch the last confirmed level stays and falls only with the formula's age slope.
//   3. Otherwise Gellish et al. (2007), 192 − 0.007 × age², the formula WHOOP starts from.
// Every value is a whole bpm, so a day and the workouts inside it read the same number.
//
// A measured peak is a lower bound of the true maximum (the heart cannot beat above it, artefacts aside),
// so the level only ever raises the value above the formula. Nothing observable in everyday data can
// prove a maximum below the formula; a wearer whose maximum is lower enters it.
//
// Modelled on bartmuskala's `StrainScorer.effortHRmax` (bartmuskala/noop, refactor/effort-hrmax-resolver).

import Foundation

public enum MaxHeartRate {

    /// Where the value came from, in the vocabulary of the `effort calib` diagnostic line.
    public enum Source: String, Sendable, Equatable {
        /// The wearer's own setting, used as the exact bpm entered.
        case override
        /// The level held in workouts on two days, above the formula.
        case measured
        /// The age formula (Gellish 2007).
        case gellish
        /// Neither a setting, a measured level nor an age. Scored against `StrainScorer.defaultMaxHR()`.
        case `default`
    }

    public struct Resolved: Sendable, Equatable {
        /// The maximum heart rate in whole bpm. nil only for `.default`.
        public let bpm: Double?
        public let source: Source

        /// The value as an integer, with `.default` read as `StrainScorer.defaultMaxHR()`, the number
        /// `StrainScorer.strain` substitutes for nil, so every reader of an age-less profile agrees.
        public var wholeBpm: Int { bpm.map { Int($0.rounded()) } ?? StrainScorer.defaultMaxHR() }
    }

    /// A measured level and the last day a window of peaks confirmed it.
    public struct Level: Sendable, Equatable {
        public let bpm: Double
        public let confirmedOn: String
        public init(bpm: Double, confirmedOn: String) { self.bpm = bpm; self.confirmedOn = confirmedOn }

        /// "191|2026-10-20": the form the daily pass hands to the profile readers.
        public var stored: String { "\(Int(bpm.rounded()))|\(confirmedOn)" }

        public init?(stored: String?) {
            guard let parts = stored?.split(separator: "|"), parts.count == 2,
                  let bpm = Double(parts[0]), bpm > 0 else { return nil }
            self.init(bpm: bpm, confirmedOn: String(parts[1]))
        }
    }

    /// Where the daily pass stores today's measured level (`Level.stored`) for the readers outside the
    /// pass: the profile, the zones, the coach, the settings row. Removed when no level is confirmed.
    public static let measuredLevelKey = "noopai:maxHeartRateMeasured"

    /// Days before a day whose peaks can confirm a level.
    public static let windowDays = 90
    /// Different days a level must be reached on.
    public static let confirmingDays = 2
    /// A day's peak further above the formula than this counts as an artefact, not a level.
    public static let plausibleAboveFormulaBpm = 25.0

    /// Gellish et al. (2007): 192 − 0.007 × age², rounded to a whole bpm. nil without an age.
    public static func gellish(age: Double) -> Double? {
        guard age > 0 else { return nil }
        return (192.0 - 0.007 * age * age).rounded()
    }

    /// Resolve from a manual setting in bpm (nil when unset), the age in years (0 or less when unknown)
    /// and the measured level in force (nil when none is confirmed).
    public static func resolve(override manual: Double?, age: Double, measured: Double? = nil) -> Resolved {
        if let manual { return Resolved(bpm: manual.rounded(), source: .override) }
        let formula = gellish(age: age)
        if let measured, measured >= (formula ?? 0) { return Resolved(bpm: measured.rounded(), source: .measured) }
        if let formula { return Resolved(bpm: formula, source: .gellish) }
        return Resolved(bpm: nil, source: .default)
    }

    /// The stored-setting form: the profile keeps "no setting" as 0, never as nil.
    public static func resolve(overrideBpm: Int, age: Double, measured: Double? = nil) -> Resolved {
        resolve(override: overrideBpm > 0 ? Double(overrideBpm) : nil, age: age, measured: measured)
    }

    /// The measured level in force on each of `days` ("yyyy-MM-dd"), from each day's workout peak.
    ///
    /// A day reads only the peaks of the days BEFORE it, so its own workouts, which are detected against
    /// its value, cannot move that value. Days without a confirmed level are absent from the result.
    /// `age` sets the plausibility bound and the slope the level falls by after a quiet stretch.
    public static func measuredLevels(days: [String], peaks: [String: Double], age: Double) -> [String: Level] {
        guard let lastDay = days.max() else { return [:] }
        let formula = gellish(age: age)
        let plausible = peaks.filter { entry in
            entry.value > 0 && (formula.map { entry.value <= $0 + plausibleAboveFormulaBpm } ?? true)
        }
        guard let firstPeakDay = plausible.keys.min(), firstPeakDay < lastDay else { return [:] }
        let wanted = Set(days)
        // Gellish falls by 0.014 × age bpm per year at this age; a carried level falls by it from the day it
        // was last reached.
        let slopePerDay = 0.014 * max(age, 0) / 365.25
        var index: [String: Int] = [:]
        var carried: (level: Double, on: String)?
        func decayed(_ c: (level: Double, on: String), at i: Int) -> Double {
            c.level - slopePerDay * Double(i - (index[c.on] ?? i))
        }
        var out: [String: Level] = [:]
        var day = firstPeakDay
        var i = 0
        while day <= lastDay {
            index[day] = i
            let from = HealthspanWindow.dayKey(day, plus: -windowDays)
            let inWindow = plausible.filter { $0.key >= from && $0.key < day }
            let values = inWindow.values.sorted(by: >)
            if values.count >= confirmingDays {
                let level = values[confirmingDays - 1]
                // The later of the days that reached the level is when it was last confirmed.
                let on = inWindow.filter { $0.value >= level }.keys.max() ?? day
                if level >= (carried.map { decayed($0, at: i) } ?? 0) { carried = (level, on) }
            }
            if let c = carried, wanted.contains(day) {
                out[day] = Level(bpm: decayed(c, at: i), confirmedOn: c.on)
            }
            day = HealthspanWindow.dayKey(day, plus: 1)
            i += 1
        }
        return out
    }
}
