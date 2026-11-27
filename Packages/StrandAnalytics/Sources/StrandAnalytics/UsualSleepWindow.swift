import Foundation

/// The hours a wearer usually sleeps, from their own recent nights (owner decision 2026-11-27, Q32).
///
/// The energy model gives awake still time an everyday allowance (`WhoopEnergyModel.awakeStillFactor`).
/// A night without the strap, or one the stager missed, has no detected sleep, and without this window it
/// would count as eight hours of sitting up. Inside the window, time without detected sleep and without
/// movement stays at basal.
///
/// The window is the median bedtime and the median wake time of the main nights (at least
/// `minimumNightSeconds` long, the longest per wake day) among the last `nightsConsidered` nights that
/// ended before the instant asked about, so a day is never priced with nights that came after it. Times of
/// day are averaged on the clock face, so a window that spans midnight and a day sleeper's window both
/// resolve. With fewer than `minimumNights` nights the window is 23:00 to 07:00.
public struct UsualSleepWindow: Equatable, Sendable {
    /// Minutes after local midnight. `startMinute > endMinute` when the window spans midnight.
    public let startMinute: Int
    public let endMinute: Int

    public static let fallback = UsualSleepWindow(startMinute: 23 * 60, endMinute: 7 * 60)
    public static let nightsConsidered = 14
    public static let minimumNights = 3
    public static let minimumNightSeconds = 3 * 3_600

    public init(startMinute: Int, endMinute: Int) {
        self.startMinute = ((startMinute % 1_440) + 1_440) % 1_440
        self.endMinute = ((endMinute % 1_440) + 1_440) % 1_440
    }

    /// The window from the main nights among `nights` (start and end, Unix seconds) that ended at or
    /// before `cutoff`.
    public static func resolve(nights: [(start: Int, end: Int)], endingBy cutoff: Int,
                               calendar: Calendar = .current) -> UsualSleepWindow {
        var longestByWakeDay: [Date: (start: Int, end: Int)] = [:]
        for night in nights where night.end <= cutoff && night.end - night.start >= minimumNightSeconds {
            let wakeDay = calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(night.end)))
            if let kept = longestByWakeDay[wakeDay], kept.end - kept.start >= night.end - night.start { continue }
            longestByWakeDay[wakeDay] = night
        }
        let recent = longestByWakeDay.sorted { $0.key > $1.key }.prefix(nightsConsidered).map(\.value)
        guard recent.count >= minimumNights else { return fallback }
        let starts = recent.map { minuteOfDay($0.start, calendar: calendar) }
        let ends = recent.map { minuteOfDay($0.end, calendar: calendar) }
        return UsualSleepWindow(startMinute: clockMedian(starts), endMinute: clockMedian(ends))
    }

    /// Whether `timestamp` falls inside the window on its own local day.
    public func contains(_ timestamp: Int, calendar: Calendar = .current) -> Bool {
        contains(minute: Self.minuteOfDay(timestamp, calendar: calendar))
    }

    public func contains(minute: Int) -> Bool {
        if startMinute == endMinute { return false }
        if startMinute < endMinute { return minute >= startMinute && minute < endMinute }
        return minute >= startMinute || minute < endMinute
    }

    /// Seconds in `[from, to)` that lie outside the window, counted minute by minute.
    public func awakeSeconds(from: Int, to: Int, calendar: Calendar = .current) -> Int {
        guard to > from else { return 0 }
        var seconds = 0
        var cursor = from
        while cursor < to {
            let next = min(to, (cursor / 60 + 1) * 60)
            if !contains(cursor, calendar: calendar) { seconds += next - cursor }
            cursor = next
        }
        return seconds
    }

    static func minuteOfDay(_ timestamp: Int, calendar: Calendar) -> Int {
        let parts = calendar.dateComponents([.hour, .minute],
                                            from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    /// The median of clock times: the values are turned so that their circular mean sits at noon, where
    /// none of them can wrap, and the median of the turned values is turned back.
    static func clockMedian(_ minutes: [Int]) -> Int {
        guard !minutes.isEmpty else { return 0 }
        let angles = minutes.map { Double($0) / 1_440 * 2 * .pi }
        let meanAngle = atan2(angles.map(sin).reduce(0, +), angles.map(cos).reduce(0, +))
        let meanMinute = Int((meanAngle / (2 * .pi) * 1_440).rounded())
        let shift = 720 - meanMinute
        let turned = minutes.map { (($0 + shift) % 1_440 + 1_440) % 1_440 }.sorted()
        let middle = turned.count / 2
        let median = turned.count % 2 == 1
            ? Double(turned[middle])
            : Double(turned[middle - 1] + turned[middle]) / 2
        return ((Int(median.rounded()) - shift) % 1_440 + 1_440) % 1_440
    }
}
