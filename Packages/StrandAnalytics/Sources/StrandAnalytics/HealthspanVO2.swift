import Foundation
import WhoopProtocol

// HealthspanVO2.swift — fork feature "AgeLess" (backlog plan HEALTHSPAN_AGE_PLAN, decisions of 2026-10-12): which
// VO₂max a week's age and pace use, and the lean mass behind it.
//
// NOOP's weekly non-exercise estimate (Nes 2011 / Uth 2004, `vo2max_est`) is deliberately not a source: it is the
// least certain input and was the largest single driver of the age. In its place (decisions of 2026-10-13, AI-24):
//   1. a value the wearer entered, until two newer measurements arrive, and for a year at most;
//   2. Apple Watch's Cardio Fitness readings from Apple Health, while the watch has measured in the last 30 days;
//   3. NOOP's training-based estimate from walks and runs (`ExerciseVO2max`, grade assumed flat);
//   4. older Apple Health readings, when there are no walks or runs either.
// Newer measurements beat older ones: a single entry must not hide months of walks and runs, nor a watch that
// stopped measuring. Two readings rather than one replace an entry, because a single walk can be off by a few
// ml/kg/min (grade, wind, heat, a high pulse) and the mean of two halves such an outlier. Once readings replace an
// entry, only those newer than the entry count. One source decides both the age and the pace, so the two never mix
// sources. The age takes the median of that source's readings over six months; the pace takes the median of the
// last 30 days when there are at least two readings there, else the six-month value, so a single reading cannot
// swing the pace.

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

    /// An entered value counts for a year from the day it was measured at most.
    public static let manualValidDays = 365
    /// Readings the last 30 days need before they, rather than the six-month value, drive the pace.
    public static let minimumRecentReadings = 2
    /// Measurements newer than an entered value that replace it.
    public static let readingsReplacingManual = 2
    /// Apple Health leads only while it has measured within this many days.
    public static let appleCurrentDays = 30

    public static func resolve(manual: (day: String, value: Double)?,
                               appleHealth: [(day: String, value: Double)],
                               training: [(day: String, value: Double)],
                               endingOn end: String) -> Resolved? {
        let entry = validManual(manual, on: end)
        let windowStart = HealthspanWindow.dayKey(end, plus: -(HealthspanWindow.ageWindowDays - 1))
        let measured = measuredSource(appleHealth: appleHealth, training: training, endingOn: end,
                                      newerThan: entry?.day)
        let inWindow = measured.map { $0.readings.filter { $0.day >= windowStart } } ?? []
        if let entry, inWindow.count < readingsReplacingManual {
            return Resolved(window: entry.value, recent: entry.value, source: .manual, readings: 1,
                            latestDay: entry.day)
        }
        guard let measured, let windowMedian = median(inWindow.map(\.value)),
              let latest = inWindow.map(\.day).max() else { return nil }
        let recentStart = HealthspanWindow.dayKey(end, plus: -(HealthspanWindow.paceWindowDays - 1))
        let recent = inWindow.filter { $0.day >= recentStart }.map(\.value)
        let recentMedian = recent.count >= minimumRecentReadings ? median(recent) ?? windowMedian : windowMedian
        return Resolved(window: windowMedian, recent: recentMedian, source: measured.source, readings: inWindow.count,
                        latestDay: latest)
    }

    /// The readings a VO₂max goal follows on `today`: the entered value while it stands, else every reading of the
    /// source `resolve` chose, newer than an entry the readings replaced. Oldest first.
    public static func goalReadings(manual: (day: String, value: Double)?,
                                    appleHealth: [(day: String, value: Double)],
                                    training: [(day: String, value: Double)],
                                    today: String) -> [(day: String, value: Double)] {
        guard let resolved = resolve(manual: manual, appleHealth: appleHealth, training: training, endingOn: today)
        else { return [] }
        let entry = validManual(manual, on: today)
        switch resolved.source {
        case .manual: return entry.map { [$0] } ?? []
        case .appleHealth, .training:
            let all = resolved.source == .appleHealth ? appleHealth : training
            return all.filter { r in r.value > 0 && r.day <= today && (entry.map { r.day > $0.day } ?? true) }
                .sorted { $0.day < $1.day }
        }
    }

    /// An entered value that still counts on `end`: measured on or before it, within the past year.
    static func validManual(_ manual: (day: String, value: Double)?, on end: String) -> (day: String, value: Double)? {
        guard let manual, manual.value > 0, manual.day <= end,
              manual.day >= HealthspanWindow.dayKey(end, plus: -(manualValidDays - 1)) else { return nil }
        return manual
    }

    /// The measured source for a window ending on `end` and its readings up to `end` (only those after `newerThan`):
    /// Apple Health while it measured in the last 30 days, else walks and runs in the six months, else older Apple
    /// Health readings in the six months.
    static func measuredSource(appleHealth: [(day: String, value: Double)], training: [(day: String, value: Double)],
                               endingOn end: String,
                               newerThan: String?) -> (source: Source, readings: [(day: String, value: Double)])? {
        func usable(_ xs: [(day: String, value: Double)]) -> [(day: String, value: Double)] {
            xs.filter { r in r.value > 0 && r.day <= end && (newerThan.map { r.day > $0 } ?? true) }
        }
        let apple = usable(appleHealth), walks = usable(training)
        let windowStart = HealthspanWindow.dayKey(end, plus: -(HealthspanWindow.ageWindowDays - 1))
        let currentStart = HealthspanWindow.dayKey(end, plus: -(appleCurrentDays - 1))
        if apple.contains(where: { $0.day >= currentStart }) { return (.appleHealth, apple) }
        if walks.contains(where: { $0.day >= windowStart }) { return (.training, walks) }
        if apple.contains(where: { $0.day >= windowStart }) { return (.appleHealth, apple) }
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

    public static func median(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted(), m = s.count / 2
        return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
    }
}
