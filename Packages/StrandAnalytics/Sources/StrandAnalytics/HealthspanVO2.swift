import Foundation
import WhoopProtocol

// HealthspanVO2.swift — fork feature "AgeLess" (backlog plan HEALTHSPAN_AGE_PLAN, decisions of 2026-10-12): which
// VO₂max a week's age and pace use, and the lean mass behind it.
//
// NOOP's weekly non-exercise estimate (Nes 2011 / Uth 2004, `vo2max_est`) is deliberately not a source: it is the
// least certain input and was the largest single driver of the age. In its place, in this order:
//   1. a value the wearer entered, valid for a year from the day it was measured;
//   2. Apple Watch's Cardio Fitness readings from Apple Health;
//   3. NOOP's training-based estimate from walks and runs (`ExerciseVO2max`, grade assumed flat).
// The first source with any reading in the six-month window decides both the age and the pace, so the two
// never mix sources. The age takes the median of that source's readings over six months; the pace takes the
// median of the last 30 days when there are at least two readings there, else the six-month value, so a
// single reading cannot swing the pace.

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
                               training: [(day: String, value: Double)],
                               endingOn end: String) -> Resolved? {
        if let manual, manual.value > 0, manual.day <= end,
           manual.day >= HealthspanWindow.dayKey(end, plus: -(manualValidDays - 1)) {
            return Resolved(window: manual.value, recent: manual.value, source: .manual, readings: 1,
                            latestDay: manual.day)
        }
        for (source, readings) in [(Source.appleHealth, appleHealth), (Source.training, training)] {
            let inWindow = slice(readings, endingOn: end, windowDays: HealthspanWindow.ageWindowDays)
            guard let windowMedian = median(inWindow.map(\.value)), let latest = inWindow.map(\.day).max() else { continue }
            let recent = values(readings, endingOn: end, windowDays: HealthspanWindow.paceWindowDays)
            let recentMedian = recent.count >= minimumRecentReadings ? median(recent) ?? windowMedian : windowMedian
            return Resolved(window: windowMedian, recent: recentMedian, source: source, readings: inWindow.count,
                            latestDay: latest)
        }
        return nil
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

    static func values(_ readings: [(day: String, value: Double)], endingOn end: String, windowDays: Int) -> [Double] {
        slice(readings, endingOn: end, windowDays: windowDays).map(\.value)
    }

    static func slice(_ readings: [(day: String, value: Double)], endingOn end: String,
                      windowDays: Int) -> [(day: String, value: Double)] {
        let start = HealthspanWindow.dayKey(end, plus: -(windowDays - 1))
        return readings.filter { $0.day >= start && $0.day <= end && $0.value > 0 }
    }

    public static func median(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted(), m = s.count / 2
        return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
    }
}
