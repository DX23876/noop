import Foundation

// SleepTimingConsistency.swift — sleep consistency judged by TIMING, after the Sleep Regularity Index
// (Windred 2024): how likely you are to be in the same state (asleep or awake) at the same clock time
// across consecutive days, the last 24 h compared with the previous 4 days.
//
// Reading of that definition, chosen by reproducing one wearer's reference values from an earlier
// wearable's export (668 nights, 2021–2026): the 24 h ending at the night's wake time are compared minute by minute with the same 24 h on
// each of the 4 days before; agreement is averaged and put on the Sleep Regularity Index scale
// (200·a − 100), floored at 0. Naps count. Against the export: r 0.95 per night, mean |error| 4 points on
// monthly averages, bias about +2. The export has no in-sleep wake periods, which plausibly explains most
// of the bias. A plain linear recalibration did not reduce the error on held-out years, so none is applied.
//
// Clock time is taken as absolute 24 h steps, so a DST change shifts the comparison by an hour on two days.
public enum SleepTimingConsistency {

    /// Previous days the last 24 h are compared against.
    public static let priorDays = 4

    /// One asleep period, epoch seconds, `end` exclusive. Main sleeps and naps alike.
    public struct Interval: Equatable, Sendable {
        public let start: Int
        public let end: Int
        public init(start: Int, end: Int) { self.start = start; self.end = end }
    }

    /// Consistency 0–100 for the night that ended at `wakeAt`; nil when no sleep falls in the last 24 h.
    /// The caller passes only days the strap was worn: an unworn day reads as awake all day.
    public static func score(sleeps: [Interval], wakeAt: Int) -> Double? {
        let minutesPerDay = 1440
        func asleep(dayOffset k: Int) -> [Bool] {
            let windowEnd = wakeAt - k * 86_400
            let windowStart = windowEnd - 86_400
            var m = [Bool](repeating: false, count: minutesPerDay)
            for s in sleeps where s.end > windowStart && s.start < windowEnd {
                let a = max(s.start, windowStart) - windowStart
                let b = min(s.end, windowEnd) - windowStart
                for i in (a / 60)..<min(minutesPerDay, b / 60) { m[i] = true }
            }
            return m
        }
        let last = asleep(dayOffset: 0)
        guard last.contains(true) else { return nil }
        var agreementSum = 0.0
        for k in 1...priorDays {
            let prior = asleep(dayOffset: k)
            let same = zip(last, prior).reduce(0) { $0 + ($1.0 == $1.1 ? 1 : 0) }
            agreementSum += Double(same) / Double(minutesPerDay)
        }
        let agreement = agreementSum / Double(priorDays)
        return max(0, 200 * agreement - 100)
    }
}
