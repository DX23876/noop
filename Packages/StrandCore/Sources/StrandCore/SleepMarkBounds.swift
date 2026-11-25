import Foundation
import WhoopStore

/// The wearer's own "going to sleep" and "I'm awake" taps as the bounds of a detected night (owner,
/// 2026-11-25). The strap cannot tell lying awake in bed from sleeping, so a tester's night began at 2 am
/// while they watched videos until 4; the detector also ends a night where the synced data ends. A tap is the
/// wearer saying when it was, which is input, not an estimate, so it is applied as a correction of the night's
/// times would be.
///
/// Only a mark INSIDE a night moves it, and only inward: a bedtime tap in its first half moves the start
/// later, a wake tap in its second half moves the end earlier. A tap outside every night, or one that would
/// leave less than an hour, changes nothing. The stored marks: `sleep_bedtime_ts` and `sleep_wake_ts`,
/// one per local day each, the value the tap's Unix time in seconds.
public enum SleepMarkBounds {
    public static let bedtimeKey = "sleep_bedtime_ts"
    public static let wakeKey = "sleep_wake_ts"
    /// A night the marks would cut below this is left as detected.
    public static let minimumNightSeconds = 3_600

    /// The night's new bounds, or nil when the marks leave it as it is.
    public static func bounds(start: Int, end: Int, bedtimes: [Int], wakes: [Int]) -> (start: Int, end: Int)? {
        guard end > start else { return nil }
        let middle = start + (end - start) / 2
        let newStart = bedtimes.filter { $0 > start && $0 < middle }.max() ?? start
        let newEnd = wakes.filter { $0 > middle && $0 < end }.min() ?? end
        guard newStart != start || newEnd != end, newEnd - newStart >= minimumNightSeconds else { return nil }
        return (newStart, newEnd)
    }

    /// The marks stored for the days around [from, to], as Unix seconds.
    public static func marks(store: WhoopStore, fromDay: String, toDay: String) async -> (bedtimes: [Int], wakes: [Int]) {
        func read(_ key: String) async -> [Int] {
            ((try? await store.metricSeriesAnyDevice(key: key, from: fromDay, to: toDay)) ?? [])
                .compactMap { $0.value.isFinite && $0.value > 0 ? Int($0.value) : nil }
        }
        return (await read(bedtimeKey), await read(wakeKey))
    }
}
