import Foundation

// StreakCalculator.swift - consecutive-day "streak" over the days that carry a qualifying record (#569).
//
// A streak is the WHOOP-style "days in a row" count. It is derived PURELY from the set of local calendar
// days that already have a score - no new storage, no migration, no BLE, no network. The caller passes
// parallel arrays (`dayKeys` + `qualified`, one entry per day it knows about, the same shape the Charge /
// HRV surfaces already assemble) plus `today`, and gets back the current and longest runs.
//
// Civil-day arithmetic is TZ-free (`Baselines.isoEpochDay`, Howard Hinnant's algorithm), so Swift and
// Kotlin agree bit-for-bit - the twin is `com.noop.analytics.StreakCalculator`, held aligned by mirrored
// fixtures. Pure and side-effect-free: no clock, no I/O, no PII. No em-dashes.

public enum StreakCalculator {

    /// The current and longest consecutive-day runs.
    public struct Streaks: Equatable, Sendable {
        /// The unbroken run of qualifying days ending at `today`, or at `today - 1` when today has not
        /// been scored yet (a day's score only lands after that night's sleep, so the streak must not
        /// read 0 all day). A gap of one or more missed civil days ends the current run.
        public let current: Int
        /// The longest unbroken run anywhere in the supplied history.
        public let longest: Int
        public init(current: Int, longest: Int) {
            self.current = current
            self.longest = longest
        }
    }

    /// Compute `(current, longest)` from parallel `dayKeys` / `qualified` (`yyyy-MM-dd` keys and their
    /// qualify flags) and an ISO `today`. Duplicate or unparseable day keys are ignored; if the arrays
    /// differ in length the excess is ignored (mirrors `Baselines.nightsSinceNewestValidNight`). Returns
    /// `(0, 0)` when nothing qualifies. Pure: no clock, no I/O.
    public static func streaks(dayKeys: [String], qualified: [Bool], today: String) -> Streaks {
        // Distinct civil-epoch days that carry a qualifying record.
        var days = Set<Int>()
        for i in 0..<Swift.min(dayKeys.count, qualified.count) where qualified[i] {
            if let e = Baselines.isoEpochDay(dayKeys[i]) { days.insert(e) }
        }
        guard !days.isEmpty else { return Streaks(current: 0, longest: 0) }

        // Longest run: start at each day whose predecessor is absent, then count forward.
        var longest = 0
        for d in days where !days.contains(d - 1) {
            var len = 1
            while days.contains(d + len) { len += 1 }
            if len > longest { longest = len }
        }

        // Current run: anchored at today, or yesterday when today is not yet scored (the grace above).
        var current = 0
        if let t = Baselines.isoEpochDay(today) {
            let anchor: Int? = days.contains(t) ? t : (days.contains(t - 1) ? t - 1 : nil)
            if let a = anchor {
                current = 1
                while days.contains(a - current) { current += 1 }
            }
        }
        return Streaks(current: current, longest: longest)
    }
}
