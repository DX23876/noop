// MaxHeartRate.swift — the wearer's maximum heart rate, decided in one place (#2438).
//
// Effort, workout scores, heart-rate zones, workout energy, the healthspan age and the coach all need
// the same number. It used to be written out by hand at every caller ("manual setting, else Tanaka from
// age"), in Double and Int forms that rounded differently, and two such copies had already dropped the
// manual setting (#2460). #2438 step 0 changes what the number means (Gellish start value, raised by a
// peak held on two days), so every reader has to change together, which is only safe with one place to
// change. `Tools/test_max_heart_rate_resolver.py` fails when a caller resolves it by itself again.
//
// Modelled on bartmuskala's `StrainScorer.effortHRmax` (bartmuskala/noop, refactor/effort-hrmax-resolver).
// This first version returns exactly what each replaced expression returned: no score changes.

import Foundation

public enum MaxHeartRate {

    /// Where the value came from, in the vocabulary of the `effort calib` diagnostic line.
    public enum Source: String, Sendable, Equatable {
        /// The wearer's own setting, used as the exact bpm entered.
        case override
        /// The age formula (Tanaka 2001: 208 − 0.7 × age).
        case tanaka
        /// Neither a setting nor an age. `StrainScorer.strain` then substitutes `defaultMaxHR()`.
        case `default`
    }

    public struct Resolved: Sendable, Equatable {
        /// The maximum heart rate in bpm, unrounded. nil only for `.default`.
        public let bpm: Double?
        public let source: Source

        /// The whole-bpm form the profile, the zones and workout scoring read. The formula value rounds
        /// to the nearest bpm; an age-less profile reads the formula at age 0 (208), which is what
        /// `ProfileStore.hrMax` has always returned. Step 0 retires the split between this and `bpm`.
        public var wholeBpm: Int {
            switch source {
            case .override, .tanaka: return Int((bpm ?? 0).rounded())
            case .default: return Int(StrainScorer.tanakaHRmax(age: 0).rounded())
            }
        }
    }

    /// Resolve from a manual setting in bpm (nil when unset) and the age in years (0 or less when unknown).
    ///
    /// A setting wins as entered, also without an age and also below the formula. Otherwise Tanaka from
    /// age. Otherwise `.default` with a nil value.
    public static func resolve(override manual: Double?, age: Double) -> Resolved {
        if let manual { return Resolved(bpm: manual, source: .override) }
        if age > 0 { return Resolved(bpm: StrainScorer.tanakaHRmax(age: age), source: .tanaka) }
        return Resolved(bpm: nil, source: .default)
    }

    /// The stored-setting form: the profile keeps "no setting" as 0, never as nil.
    public static func resolve(overrideBpm: Int, age: Double) -> Resolved {
        resolve(override: overrideBpm > 0 ? Double(overrideBpm) : nil, age: age)
    }

    /// The age formula alone, ignoring any manual setting. Only for readers that have always used the
    /// formula regardless of the setting (the VO₂max fallback, the energy model's last resort); each of
    /// them moves to `resolve` with step 0, which changes their values and needs the rebuild.
    public static func ageFormula(age: Double) -> Double? {
        resolve(override: nil, age: age).bpm
    }
}
