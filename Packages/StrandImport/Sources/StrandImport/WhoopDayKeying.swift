import Foundation

/// Which local calendar day a WHOOP physiological cycle belongs to.
///
/// WHOOP exports are onset-to-onset: a cycle's `cycle_start_time` is the EVENING you fell asleep
/// (identical to that cycle's `sleep_onset`), and the recovery/strain it carries are what you read
/// the next morning. So the cycle belongs to the WAKE day, not the day it started. Keying off the
/// start put every night's scores a day early, which for a fresh import with no live strap left no
/// row under "today" and blanked the Today screen (v8.2.1).
///
/// Preference order: wake onset, then cycle end (the next cycle's onset, which lands on the same
/// wake day), then the start as a last resort for a sleepless cycle. This matches the live engine /
/// `mergeSleep` convention, which already keys nights by the local wake day.
public enum WhoopDayKeying {
    /// The `yyyy-MM-dd` wake-day key for a cycle, in the cycle's own UTC offset. `nil` when no usable
    /// timestamp is present.
    public static func wakeDayKey(wake: Date?, end: Date?, start: Date?, tzOffsetMin: Int) -> String? {
        guard let d = wake ?? end ?? start else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: tzOffsetMin * 60) ?? TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
